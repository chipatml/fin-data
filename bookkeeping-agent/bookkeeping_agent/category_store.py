"""Persistent category memory: a merchant -> house-category map stored next to
the Plaid data, so categorizations stay consistent across monthly closes.

The store lives at ``PARENT/_bookkeeping/categories.json``:

    {
      "version": 1,
      "updated_at": "2026-08-26T00:00:00Z",
      "house_chart": ["dining", "groceries", ...],   # optional allow-list
      "merchants": {
        "netflix": {"category": "entertainment", "confidence": "high",
                     "note": "...", "updated_at": "..."}
      }
    }

Keys are normalized merchant names (see :func:`merchants.normalize_merchant`),
so "SQ *STARBUCKS #12" and "STARBUCKS" resolve to the same memory.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bookkeeping_agent.merchants import normalize_merchant

STORE_DIRNAME = "_bookkeeping"
STORE_FILENAME = "categories.json"
SCHEMA_VERSION = 1


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def store_path(parent: str | Path) -> Path:
    """Absolute path to the category-map file for a parent data folder."""
    return Path(parent).expanduser().resolve() / STORE_DIRNAME / STORE_FILENAME


def _empty_store() -> dict[str, Any]:
    return {"version": SCHEMA_VERSION, "updated_at": None, "house_chart": [], "merchants": {}}


def load_category_map(parent: str | Path) -> dict[str, Any]:
    """Load the stored category map, or an empty scaffold if none exists.

    Never raises for a missing store; a malformed file is reported via an
    ``error`` key alongside an otherwise-empty scaffold so callers degrade
    gracefully instead of crashing a close.
    """
    path = store_path(parent)
    store = _empty_store()
    if not path.is_file():
        return store
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        store["error"] = f"{path}: {exc}"
        return store
    if isinstance(data, dict):
        store["version"] = data.get("version", SCHEMA_VERSION)
        store["updated_at"] = data.get("updated_at")
        chart = data.get("house_chart")
        store["house_chart"] = chart if isinstance(chart, list) else []
        merchants = data.get("merchants")
        store["merchants"] = merchants if isinstance(merchants, dict) else {}
    return store


def _coerce_entry(value: Any) -> dict[str, Any] | None:
    """Accept either ``"category"`` or ``{"category": ..., ...}`` per merchant."""
    if isinstance(value, str):
        entry: dict[str, Any] = {"category": value}
    elif isinstance(value, dict) and value.get("category"):
        entry = {k: v for k, v in value.items() if k in ("category", "confidence", "note")}
    else:
        return None
    entry["updated_at"] = _now()
    return entry


def save_category_map(
    parent: str | Path,
    merchants: dict[str, Any],
    *,
    house_chart: list[str] | None = None,
    merge: bool = True,
) -> dict[str, Any]:
    """Upsert merchant -> category entries; returns a summary of what changed.

    ``merchants`` maps a merchant name (raw or already-normalized) to either a
    category string or a ``{"category", "confidence", "note"}`` dict. Keys are
    normalized before storing. With ``merge=True`` (default) existing entries
    are kept and updated; with ``merge=False`` the merchant map is replaced.
    """
    path = store_path(parent)
    store = load_category_map(parent)
    existing: dict[str, Any] = store.get("merchants", {}) if merge else {}

    added, updated, skipped = [], [], []
    for raw_name, value in (merchants or {}).items():
        key = normalize_merchant(raw_name)
        entry = _coerce_entry(value)
        if not key or entry is None:
            skipped.append(raw_name)
            continue
        (updated if key in existing else added).append(key)
        existing[key] = entry

    if house_chart is not None:
        store["house_chart"] = list(house_chart)
    store["merchants"] = existing
    store["version"] = SCHEMA_VERSION
    store["updated_at"] = _now()
    store.pop("error", None)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(store, indent=2, sort_keys=True), encoding="utf-8")

    return {
        "store_path": str(path),
        "added": sorted(added),
        "updated": sorted(updated),
        "skipped": skipped,
        "merchant_count": len(existing),
        "house_chart_size": len(store["house_chart"]),
    }


def lookup(cat_map: dict[str, Any], merchant: str | None) -> dict[str, Any] | None:
    """Return the stored entry for a raw/normalized merchant name, or None."""
    merchants = cat_map.get("merchants", {}) if isinstance(cat_map, dict) else {}
    return merchants.get(normalize_merchant(merchant))


def apply_categories(rows: list[dict[str, Any]], cat_map: dict[str, Any]) -> dict[str, Any]:
    """Tag each row with its remembered house category.

    Returns ``{"rows": [...], "coded": n, "uncoded_merchants": [...]}``. Each
    row gains ``house_category`` (None when unknown) and
    ``house_category_source`` ("memory" or None). Uncoded merchants are the
    distinct normalized keys with no stored mapping — the worklist the agent
    should categorize and then persist via :func:`save_category_map`.
    """
    out: list[dict[str, Any]] = []
    coded = 0
    uncoded: set[str] = set()
    for row in rows:
        merchant = row.get("merchant")
        entry = lookup(cat_map, merchant)
        tagged = dict(row)
        if entry:
            tagged["house_category"] = entry.get("category")
            tagged["house_category_source"] = "memory"
            coded += 1
        else:
            tagged["house_category"] = None
            tagged["house_category_source"] = None
            key = normalize_merchant(merchant)
            if key:
                uncoded.add(key)
        out.append(tagged)
    return {"rows": out, "coded": coded, "uncoded_merchants": sorted(uncoded)}
