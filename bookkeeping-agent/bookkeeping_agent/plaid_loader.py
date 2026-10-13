"""Flatten Plaid JSON dumps organized as PARENT/<pull-date>/*.json."""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path
from typing import Any, Iterable


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def transactions_from_payload(payload: Any) -> tuple[list[dict[str, Any]], list[str]]:
    """Return (transactions, removed_ids) from common Plaid export shapes."""
    removed: list[str] = []
    if isinstance(payload, list):
        return [t for t in payload if isinstance(t, dict)], removed
    if not isinstance(payload, dict):
        return [], removed

    for key in ("removed", "deleted"):
        for item in _as_list(payload.get(key)):
            if isinstance(item, str):
                removed.append(item)
            elif isinstance(item, dict) and item.get("transaction_id"):
                removed.append(str(item["transaction_id"]))

    rows: list[dict[str, Any]] = []
    if "added" in payload or "modified" in payload:
        rows.extend(t for t in _as_list(payload.get("added")) if isinstance(t, dict))
        rows.extend(t for t in _as_list(payload.get("modified")) if isinstance(t, dict))
        return rows, removed

    for key in ("transactions", "data", "items"):
        block = payload.get(key)
        if isinstance(block, list):
            rows.extend(t for t in block if isinstance(t, dict))
            return rows, removed
        if isinstance(block, dict) and isinstance(block.get("transactions"), list):
            rows.extend(t for t in block["transactions"] if isinstance(t, dict))
            return rows, removed

    if payload.get("transaction_id"):
        return [payload], removed
    return [], removed


def accounts_from_payload(payload: Any) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    if not isinstance(payload, dict):
        return out
    # Accounts may sit at the top level (Plaid /transactions/get) or nested in a
    # point-in-time snapshot (FinAgentMenuBar daily record -> snapshot.accounts).
    sources = [payload.get("accounts")]
    snapshot = payload.get("snapshot")
    if isinstance(snapshot, dict):
        sources.append(snapshot.get("accounts"))
    for source in sources:
        for acct in _as_list(source):
            if not isinstance(acct, dict):
                continue
            aid = acct.get("account_id") or acct.get("id")
            if aid:
                out[str(aid)] = acct
    return out


def _pfc(tx: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    pfc = tx.get("personal_finance_category") or {}
    if isinstance(pfc, dict):
        return (
            pfc.get("primary"),
            pfc.get("detailed"),
            pfc.get("confidence_level") or pfc.get("confidence"),
        )
    legacy = tx.get("category")
    if isinstance(legacy, list) and legacy:
        primary = str(legacy[0])
        detailed = ".".join(str(x) for x in legacy)
        return primary, detailed, None
    return None, None, None


def normalize_transaction(
    tx: dict[str, Any],
    *,
    pull_date: str,
    source_file: str,
    accounts: dict[str, dict[str, Any]],
) -> dict[str, Any] | None:
    tid = tx.get("transaction_id") or tx.get("id")
    if not tid:
        return None
    account_id = tx.get("account_id")
    acct = accounts.get(str(account_id), {}) if account_id else {}
    primary, detailed, conf = _pfc(tx)
    return {
        "transaction_id": str(tid),
        "account_id": account_id,
        "account_name": acct.get("name") or acct.get("official_name") or tx.get("account_name"),
        "account_type": acct.get("type") or tx.get("account_type"),
        "account_subtype": acct.get("subtype") or tx.get("account_subtype"),
        "date": tx.get("date"),
        "authorized_date": tx.get("authorized_date"),
        "pending": bool(tx.get("pending")),
        "merchant": tx.get("merchant_name") or tx.get("name") or tx.get("original_description"),
        "raw_name": tx.get("name"),
        "original_description": tx.get("original_description"),
        "amount": tx.get("amount"),
        "currency": tx.get("iso_currency_code") or tx.get("unofficial_currency_code"),
        "pfc_primary": primary,
        "pfc_detailed": detailed,
        "pfc_confidence": conf,
        "channel": tx.get("payment_channel"),
        "merchant_entity_id": tx.get("merchant_entity_id"),
        "pull_date": pull_date,
        "source_file": source_file,
    }


def iter_daily_json(parent: Path) -> Iterable[tuple[str, Path, Any]]:
    if not parent.is_dir():
        raise FileNotFoundError(f"Parent folder not found: {parent}")
    # Skip hidden dirs and reserved stores (e.g. the "_bookkeeping" category map)
    # so they are not mistaken for daily pull folders.
    days = sorted(
        p for p in parent.iterdir()
        if p.is_dir() and not p.name.startswith((".", "_"))
    )
    files: list[tuple[str, Path]] = []
    if days:
        for day in days:
            for fp in sorted(day.glob("*.json")):
                files.append((day.name, fp))
    else:
        for fp in sorted(parent.glob("*.json")):
            files.append((parent.name, fp))
    for pull_date, fp in files:
        try:
            payload = json.loads(fp.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            yield pull_date, fp, {"__load_error__": str(exc)}
            continue
        yield pull_date, fp, payload


def load_plaid_folder(parent: str | Path) -> dict[str, Any]:
    parent_path = Path(parent).expanduser().resolve()
    latest: dict[str, dict[str, Any]] = {}
    removed: set[str] = set()
    accounts: dict[str, dict[str, Any]] = {}
    pulls: list[str] = []
    errors: list[str] = []
    # (pull_date, source_file, tx) collected first so every account — including
    # those in a run-day snapshot that sorts after the transactions it describes
    # — is known before we normalize and join. Order is preserved so the latest
    # pull still wins on duplicate transaction_ids.
    raw_rows: list[tuple[str, str, dict[str, Any]]] = []

    for pull_date, fp, payload in iter_daily_json(parent_path):
        if pull_date not in pulls:
            pulls.append(pull_date)
        if isinstance(payload, dict) and payload.get("__load_error__"):
            errors.append(f"{fp}: {payload['__load_error__']}")
            continue
        accounts.update(accounts_from_payload(payload))
        rows, gone = transactions_from_payload(payload)
        removed.update(gone)
        source_file = str(fp.relative_to(parent_path))
        for tx in rows:
            raw_rows.append((pull_date, source_file, tx))

    for pull_date, source_file, tx in raw_rows:
        norm = normalize_transaction(
            tx,
            pull_date=pull_date,
            source_file=source_file,
            accounts=accounts,
        )
        if norm:
            latest[norm["transaction_id"]] = norm

    kept = [row for tid, row in latest.items() if tid not in removed]
    kept.sort(key=lambda r: (r.get("date") or "", r.get("merchant") or ""))
    return {
        "parent": str(parent_path),
        "pulls": pulls,
        "account_count": len(accounts),
        "accounts": [
            {
                "account_id": aid,
                "name": acct.get("name") or acct.get("official_name"),
                "type": acct.get("type"),
                "subtype": acct.get("subtype"),
                "mask": acct.get("mask"),
                "balances": acct.get("balances"),
            }
            for aid, acct in accounts.items()
        ],
        "transaction_count": len(kept),
        "removed_count": len(removed),
        "errors": errors,
        "transactions": kept,
    }


def filter_transactions(
    rows: list[dict[str, Any]],
    *,
    start_date: str | None = None,
    end_date: str | None = None,
    account_name: str | None = None,
    include_pending: bool = False,
) -> list[dict[str, Any]]:
    out = []
    name_l = account_name.lower() if account_name else None
    for row in rows:
        if not include_pending and row.get("pending"):
            continue
        d = row.get("date")
        if start_date and d and d < start_date:
            continue
        if end_date and d and d > end_date:
            continue
        if name_l:
            label = " ".join(
                str(row.get(k) or "") for k in ("account_name", "account_type", "account_subtype", "source_file")
            ).lower()
            if name_l not in label:
                continue
        out.append(row)
    return out


def period_stats(rows: list[dict[str, Any]]) -> dict[str, Any]:
    outflow = inflow = 0.0
    pending = 0
    by_merchant: dict[str, float] = {}
    by_pfc: dict[str, float] = {}
    for row in rows:
        amt = row.get("amount")
        try:
            n = float(amt)
        except (TypeError, ValueError):
            continue
        if row.get("pending"):
            pending += 1
        if n >= 0:
            outflow += n
        else:
            inflow += -n
        merch = row.get("merchant") or "UNKNOWN"
        by_merchant[merch] = by_merchant.get(merch, 0.0) + n
        pfc = row.get("pfc_primary") or "UNKNOWN"
        by_pfc[pfc] = by_pfc.get(pfc, 0.0) + n
    dates = [r.get("date") for r in rows if r.get("date")]
    return {
        "count": len(rows),
        "pending_included": pending,
        "outflow": round(outflow, 2),
        "inflow": round(inflow, 2),
        "net_outflow": round(outflow - inflow, 2),
        "min_date": min(dates) if dates else None,
        "max_date": max(dates) if dates else None,
        "top_merchants": sorted(by_merchant.items(), key=lambda kv: abs(kv[1]), reverse=True)[:15],
        "plaid_pfc_totals": sorted(by_pfc.items(), key=lambda kv: abs(kv[1]), reverse=True),
    }
