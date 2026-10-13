from __future__ import annotations

import json
from pathlib import Path

from langchain.tools import tool

from bookkeeping_agent.category_store import (
    apply_categories,
    load_category_map as _load_category_map,
    save_category_map as _save_category_map,
)
from bookkeeping_agent.plaid_loader import (
    filter_transactions,
    load_plaid_folder,
    period_stats,
)
from bookkeeping_agent.recurring import detect_recurring as _detect_recurring

MAX_ROWS = 400


def _dump(payload: dict) -> str:
    return json.dumps(payload, indent=2, default=str)


@tool
def list_plaid_pulls(parent: str) -> str:
    """List daily pull folders and JSON files under a Plaid parent directory.

    Args:
        parent: Absolute or home-relative path to the parent folder that contains
            daily subfolders (YYYY-MM-DD) of account JSON files.
    """
    path = Path(parent).expanduser().resolve()
    if not path.is_dir():
        return _dump({"error": f"Folder not found: {path}"})
    days = sorted(p for p in path.iterdir() if p.is_dir() and not p.name.startswith("."))
    listing = []
    if days:
        for day in days:
            files = sorted(fp.name for fp in day.glob("*.json"))
            listing.append({"pull_date": day.name, "files": files, "file_count": len(files)})
    else:
        files = sorted(fp.name for fp in path.glob("*.json"))
        listing.append({"pull_date": path.name, "files": files, "file_count": len(files), "note": "json files at parent root"})
    return _dump({"parent": str(path), "pulls": listing, "pull_count": len(listing)})


@tool
def extract_plaid_folder(
    parent: str,
    start_date: str | None = None,
    end_date: str | None = None,
    account_name: str | None = None,
    include_pending: bool = False,
    max_rows: int = 250,
) -> str:
    """Flatten Plaid JSON under PARENT/<day>/*.json, dedupe by transaction_id,
    and return posted transactions for a date range.

    Plaid amount convention: positive = money out, negative = money in.
    Latest daily pull wins. Removed ids from sync payloads are dropped.

    Args:
        parent: Parent folder containing daily Plaid dumps.
        start_date: Inclusive posted date YYYY-MM-DD. Omit for no lower bound.
        end_date: Inclusive posted date YYYY-MM-DD. Omit for no upper bound.
        account_name: Optional substring match on account name, type, or filename.
        include_pending: If true, keep pending transactions. Default false.
        max_rows: Cap on returned rows (default 250, hard max 400) to protect context.
    """
    try:
        bundle = load_plaid_folder(parent)
    except FileNotFoundError as exc:
        return _dump({"error": str(exc)})

    cap = min(max(1, max_rows), MAX_ROWS)
    rows = filter_transactions(
        bundle["transactions"],
        start_date=start_date,
        end_date=end_date,
        account_name=account_name,
        include_pending=include_pending,
    )
    truncated = len(rows) > cap
    shown = rows[:cap]
    stats = period_stats(shown if truncated else rows)
    return _dump(
        {
            "parent": bundle["parent"],
            "pulls": bundle["pulls"],
            "accounts": bundle["accounts"],
            "filters": {
                "start_date": start_date,
                "end_date": end_date,
                "account_name": account_name,
                "include_pending": include_pending,
            },
            "matched_count": len(rows),
            "returned_count": len(shown),
            "truncated": truncated,
            "removed_count": bundle["removed_count"],
            "errors": bundle["errors"],
            "stats": stats,
            "transactions": shown,
        }
    )


@tool
def load_category_map(parent: str) -> str:
    """Load the persisted merchant -> house-category map for a Plaid parent folder.

    Use this BEFORE categorizing so coding stays consistent with prior closes.
    Returns the house chart (allowed categories) and every remembered merchant
    mapping (keyed by normalized merchant name). Empty scaffold if none saved yet.

    Args:
        parent: Parent folder containing daily Plaid dumps. The map lives at
            ``<parent>/_bookkeeping/categories.json``.
    """
    return _dump(_load_category_map(parent))


@tool
def save_category_map(
    parent: str,
    mappings: str,
    house_chart: str | None = None,
    merge: bool = True,
) -> str:
    """Persist merchant -> house-category decisions so future closes stay consistent.

    Args:
        parent: Parent folder containing daily Plaid dumps.
        mappings: JSON object mapping merchant name (raw or normalized) to either
            a category string or an object with keys category/confidence/note,
            e.g. '{"Netflix": "entertainment",
                   "SQ *Blue Bottle": {"category": "coffee", "confidence": "high"}}'.
        house_chart: Optional JSON array of allowed category names to store as the
            canonical chart. Omit to leave the existing chart unchanged.
        merge: If true (default) keep existing mappings and upsert; if false,
            replace the merchant map entirely.
    """
    try:
        parsed = json.loads(mappings)
    except json.JSONDecodeError as exc:
        return _dump({"error": f"mappings is not valid JSON: {exc}"})
    if not isinstance(parsed, dict):
        return _dump({"error": "mappings must be a JSON object of merchant -> category"})
    chart = None
    if house_chart:
        try:
            chart_parsed = json.loads(house_chart)
        except json.JSONDecodeError as exc:
            return _dump({"error": f"house_chart is not valid JSON: {exc}"})
        if not isinstance(chart_parsed, list):
            return _dump({"error": "house_chart must be a JSON array of category names"})
        chart = [str(c) for c in chart_parsed]
    return _dump(_save_category_map(parent, parsed, house_chart=chart, merge=merge))


@tool
def detect_recurring(
    parent: str,
    start_date: str | None = None,
    end_date: str | None = None,
    account_name: str | None = None,
    min_occurrences: int = 2,
) -> str:
    """Detect recurring charges / subscriptions and flag likely waste.

    Groups posted outflows by normalized merchant, infers cadence (weekly ..
    annual), computes monthly/annual run-rate, and raises flags: price_increase,
    price_decrease, duplicate_service_class (e.g. multiple streaming services),
    and single_occurrence. Deterministic — prefer this over eyeballing rows for
    the zombie-subscription, cadence-drift, and duplicate-service waste tests.
    Also applies the saved category map so each candidate shows its remembered
    house category when known.

    Args:
        parent: Parent folder containing daily Plaid dumps.
        start_date: Inclusive posted date YYYY-MM-DD. Omit for no lower bound.
        end_date: Inclusive posted date YYYY-MM-DD. Omit for no upper bound.
        account_name: Optional substring match on account name, type, or filename.
        min_occurrences: Minimum charges to qualify as recurring (default 2). Set
            to 1 to also surface lone likely-subscriptions (e.g. annual bills).
    """
    try:
        bundle = load_plaid_folder(parent)
    except FileNotFoundError as exc:
        return _dump({"error": str(exc)})

    rows = filter_transactions(
        bundle["transactions"],
        start_date=start_date,
        end_date=end_date,
        account_name=account_name,
        include_pending=False,
    )
    cat_map = _load_category_map(parent)
    tagged = apply_categories(rows, cat_map)["rows"]
    result = _detect_recurring(tagged, min_occurrences=min_occurrences)
    for cand in result["candidates"]:
        entry = next(
            (r.get("house_category") for r in tagged
             if r.get("merchant") == cand["merchant"] and r.get("house_category")),
            None,
        )
        cand["house_category"] = entry
    result.update(
        {
            "parent": bundle["parent"],
            "pulls": bundle["pulls"],
            "filters": {
                "start_date": start_date,
                "end_date": end_date,
                "account_name": account_name,
                "min_occurrences": min_occurrences,
            },
        }
    )
    return _dump(result)


PLAID_TOOLS = [
    list_plaid_pulls,
    extract_plaid_folder,
    load_category_map,
    save_category_map,
    detect_recurring,
]
