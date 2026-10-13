"""Deterministic recurring-charge / subscription detection.

Turns the prompt's "unnecessary-spend tests" (zombie subs, cadence drift,
silent price hikes, duplicate service classes) into evidence the LLM can trust,
instead of eyeballing raw rows. Pure functions over normalized transaction
dicts (as produced by :func:`plaid_loader.normalize_transaction`).
"""

from __future__ import annotations

from datetime import date
from statistics import median
from typing import Any

from bookkeeping_agent.merchants import normalize_merchant, service_class

# (label, low, high) day-gap windows for cadence inference, widest-useful first.
_CADENCE_BANDS = [
    ("weekly", 6, 8),
    ("biweekly", 12, 16),
    ("monthly", 26, 35),
    ("quarterly", 84, 96),
    ("semiannual", 175, 190),
    ("annual", 350, 380),
]
# Expected charges per year, for normalizing to a monthly/annual run-rate.
_PER_YEAR = {
    "weekly": 52.0,
    "biweekly": 26.0,
    "monthly": 12.0,
    "quarterly": 4.0,
    "semiannual": 2.0,
    "annual": 1.0,
}
_PRICE_CHANGE_THRESHOLD = 0.05  # >5% swing between first and last charge


def _parse(d: Any) -> date | None:
    if not d:
        return None
    try:
        return date.fromisoformat(str(d)[:10])
    except ValueError:
        return None


def _cadence(gaps: list[int]) -> tuple[str, float]:
    """Infer a cadence label + regularity (0..1) from consecutive day-gaps."""
    if not gaps:
        return "unknown", 0.0
    med = median(gaps)
    label = "irregular"
    for name, lo, hi in _CADENCE_BANDS:
        if lo <= med <= hi:
            label = name
            break
    # Regularity: share of gaps within 25% of the median (guards against a
    # merchant that merely happens to average out to ~30 days).
    if med > 0:
        close = sum(1 for g in gaps if abs(g - med) <= max(2.0, 0.25 * med))
        regularity = round(close / len(gaps), 2)
    else:
        regularity = 0.0
    return label, regularity


def _round(x: float) -> float:
    return round(x, 2)


def detect_recurring(
    rows: list[dict[str, Any]],
    *,
    min_occurrences: int = 2,
    include_pending: bool = False,
) -> dict[str, Any]:
    """Find recurring outflows and flag likely waste.

    Groups posted **outflows** (amount > 0) by normalized merchant, infers
    cadence from the spacing of charges, computes a monthly/annual run-rate,
    and raises flags:

    - ``price_increase`` / ``price_decrease`` — last charge differs from the
      first by more than 5% (silent price hike / cadence drift signal).
    - ``duplicate_service_class`` — 2+ recurring merchants share a service
      class (e.g. multiple streaming services).
    - ``single_occurrence`` — only one charge seen in the window (kept when it
      looks like a subscription so annual bills aren't missed, but marked
      low-confidence).

    Returns candidates sorted by annualized cost (largest first).
    """
    groups: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        if not include_pending and row.get("pending"):
            continue
        amount = row.get("amount")
        try:
            amt = float(amount)
        except (TypeError, ValueError):
            continue
        if amt <= 0:  # outflows only; income/refunds/transfers-in excluded
            continue
        key = normalize_merchant(row.get("merchant"))
        if not key:
            continue
        groups.setdefault(key, []).append({**row, "_amt": amt})

    candidates: list[dict[str, Any]] = []
    for key, items in groups.items():
        dated = sorted(
            (it for it in items if _parse(it.get("date"))),
            key=lambda it: _parse(it["date"]),  # type: ignore[arg-type]
        )
        if len(dated) < max(1, min_occurrences) and len(items) < max(1, min_occurrences):
            # Respect min_occurrences, but still surface a lone likely-sub below
            # only when min_occurrences == 1.
            if min_occurrences > 1:
                continue

        amounts = [it["_amt"] for it in dated] or [it["_amt"] for it in items]
        first_amt, last_amt = amounts[0], amounts[-1]
        gaps = []
        for a, b in zip(dated, dated[1:]):
            da, db = _parse(a["date"]), _parse(b["date"])
            if da and db:
                gaps.append((db - da).days)
        cadence, regularity = _cadence(gaps)

        per_year = _PER_YEAR.get(cadence)
        avg_amt = sum(amounts) / len(amounts)
        if per_year:
            annual = avg_amt * per_year
        else:
            annual = avg_amt * (12.0 if len(amounts) == 1 else float(len(amounts)))
        monthly = annual / 12.0

        flags: list[str] = []
        if len(amounts) >= 2 and first_amt > 0:
            change = (last_amt - first_amt) / first_amt
            if change > _PRICE_CHANGE_THRESHOLD:
                flags.append("price_increase")
            elif change < -_PRICE_CHANGE_THRESHOLD:
                flags.append("price_decrease")
        if len(dated) < 2:
            flags.append("single_occurrence")

        sample = dated[-1] if dated else items[-1]
        candidates.append(
            {
                "merchant": sample.get("merchant") or key,
                "normalized": key,
                "service_class": service_class(key),
                "occurrences": len(items),
                "cadence": cadence,
                "regularity": regularity,
                "first_date": dated[0]["date"] if dated else None,
                "last_date": dated[-1]["date"] if dated else None,
                "first_amount": _round(first_amt),
                "last_amount": _round(last_amt),
                "avg_amount": _round(avg_amt),
                "currency": sample.get("currency"),
                "category_hint": sample.get("pfc_primary"),
                "monthly_cost": _round(monthly),
                "annual_cost": _round(annual),
                "flags": flags,
                "confidence": _confidence(cadence, regularity, len(dated)),
            }
        )

    # Cross-merchant: duplicate service classes among recurring candidates.
    by_class: dict[str, list[str]] = {}
    for c in candidates:
        sc = c["service_class"]
        if sc:
            by_class.setdefault(sc, []).append(c["normalized"])
    dup_classes = {sc: names for sc, names in by_class.items() if len(set(names)) >= 2}
    for c in candidates:
        sc = c["service_class"]
        if sc in dup_classes:
            c["flags"].append("duplicate_service_class")

    candidates.sort(key=lambda c: c["annual_cost"], reverse=True)
    total_annual = _round(sum(c["annual_cost"] for c in candidates))
    return {
        "candidate_count": len(candidates),
        "total_annual_cost": total_annual,
        "duplicate_service_classes": {sc: sorted(set(n)) for sc, n in dup_classes.items()},
        "candidates": candidates,
    }


def _confidence(cadence: str, regularity: float, n: int) -> str:
    if cadence in ("unknown", "irregular") or n < 2:
        return "low"
    if regularity >= 0.75 and n >= 3:
        return "high"
    return "medium"
