from pathlib import Path

from bookkeeping_agent.plaid_loader import filter_transactions, load_plaid_folder
from bookkeeping_agent.recurring import detect_recurring

RECURRING_SAMPLE = Path(__file__).resolve().parents[1] / "samples" / "recurring_parent"


def _row(tid, merchant, date, amount, pending=False, pfc="ENTERTAINMENT"):
    return {
        "transaction_id": tid,
        "merchant": merchant,
        "date": date,
        "amount": amount,
        "pending": pending,
        "pfc_primary": pfc,
        "currency": "USD",
    }


def test_monthly_cadence_and_runrate():
    rows = [
        _row("a", "Netflix", "2026-05-03", 15.49),
        _row("b", "Netflix", "2026-06-03", 15.49),
        _row("c", "Netflix", "2026-07-03", 15.49),
    ]
    result = detect_recurring(rows)
    nflx = next(c for c in result["candidates"] if c["normalized"] == "netflix")
    assert nflx["cadence"] == "monthly"
    assert nflx["occurrences"] == 3
    assert nflx["monthly_cost"] == 15.49
    assert nflx["annual_cost"] == round(15.49 * 12, 2)
    assert nflx["confidence"] == "high"


def test_price_increase_flag():
    rows = [
        _row("a", "Netflix", "2026-05-03", 15.49),
        _row("b", "Netflix", "2026-06-03", 15.49),
        _row("c", "Netflix", "2026-07-03", 17.99),
    ]
    nflx = detect_recurring(rows)["candidates"][0]
    assert "price_increase" in nflx["flags"]
    assert nflx["first_amount"] == 15.49
    assert nflx["last_amount"] == 17.99


def test_duplicate_service_class_flag():
    rows = [
        _row("a", "Netflix", "2026-05-03", 15.49),
        _row("b", "Netflix", "2026-06-03", 15.49),
        _row("c", "Hulu", "2026-05-05", 17.99),
        _row("d", "Hulu", "2026-06-05", 17.99),
        _row("e", "Spotify", "2026-05-10", 9.99),
        _row("f", "Spotify", "2026-06-10", 9.99),
    ]
    result = detect_recurring(rows)
    assert "streaming_video" in result["duplicate_service_classes"]
    assert set(result["duplicate_service_classes"]["streaming_video"]) == {"netflix", "hulu"}
    nflx = next(c for c in result["candidates"] if c["normalized"] == "netflix")
    assert "duplicate_service_class" in nflx["flags"]
    # Spotify is the only music service -> not flagged as duplicate.
    spot = next(c for c in result["candidates"] if c["normalized"] == "spotify")
    assert "duplicate_service_class" not in spot["flags"]


def test_inflows_and_pending_excluded():
    rows = [
        _row("a", "Acme Payroll", "2026-05-15", -4200.0),  # inflow
        _row("b", "Acme Payroll", "2026-06-15", -4200.0),
        _row("c", "Amazon", "2026-06-14", 48.12, pending=True),  # pending
    ]
    result = detect_recurring(rows)
    assert result["candidate_count"] == 0


def test_min_occurrences_filters_single(monkeypatch=None):
    rows = [_row("a", "Netflix", "2026-05-03", 15.49)]
    assert detect_recurring(rows, min_occurrences=2)["candidate_count"] == 0
    # min_occurrences=1 surfaces the lone charge, marked low-confidence.
    lone = detect_recurring(rows, min_occurrences=1)["candidates"][0]
    assert "single_occurrence" in lone["flags"]
    assert lone["confidence"] == "low"


def test_sorted_by_annual_cost_desc():
    rows = [
        _row("a", "Netflix", "2026-05-03", 15.49),
        _row("b", "Netflix", "2026-06-03", 15.49),
        _row("c", "Spotify", "2026-05-10", 9.99),
        _row("d", "Spotify", "2026-06-10", 9.99),
    ]
    costs = [c["annual_cost"] for c in detect_recurring(rows)["candidates"]]
    assert costs == sorted(costs, reverse=True)


def test_end_to_end_over_fixture():
    """Real load path: dedupe + normalize + detect on the sample folders."""
    bundle = load_plaid_folder(RECURRING_SAMPLE)
    rows = filter_transactions(bundle["transactions"])
    result = detect_recurring(rows)
    by_key = {c["normalized"]: c for c in result["candidates"]}

    # Netflix appears 3 months, monthly, with a mid-window price hike.
    assert by_key["netflix"]["occurrences"] == 3
    assert by_key["netflix"]["cadence"] == "monthly"
    assert "price_increase" in by_key["netflix"]["flags"]

    # SQ *STARBUCKS normalizes to "starbucks" but is a one-off -> excluded at
    # default min_occurrences=2.
    assert "starbucks" not in by_key

    # Netflix + Hulu duplicate the streaming class.
    assert set(result["duplicate_service_classes"]["streaming_video"]) == {"netflix", "hulu"}
