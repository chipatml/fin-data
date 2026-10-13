from pathlib import Path

from bookkeeping_agent.plaid_loader import filter_transactions, load_plaid_folder, period_stats

SAMPLE = Path(__file__).resolve().parents[1] / "samples" / "plaid_parent"


def test_dedupe_and_latest_pull_wins():
    bundle = load_plaid_folder(SAMPLE)
    by_id = {t["transaction_id"]: t for t in bundle["transactions"]}
    assert "tx_netflix" in by_id
    assert by_id["tx_netflix"]["amount"] == 17.99
    assert by_id["tx_netflix"]["pull_date"] == "2026-08-15"
    assert bundle["transaction_count"] >= 7


def test_pending_filtered_by_default():
    bundle = load_plaid_folder(SAMPLE)
    posted = filter_transactions(bundle["transactions"], include_pending=False)
    pending = filter_transactions(bundle["transactions"], include_pending=True)
    assert all(not r["pending"] for r in posted)
    assert any(r["pending"] for r in pending)


def test_july_stats():
    bundle = load_plaid_folder(SAMPLE)
    july = filter_transactions(bundle["transactions"], start_date="2026-07-01", end_date="2026-07-31")
    stats = period_stats(july)
    assert stats["count"] >= 6
    assert stats["inflow"] == 4200.0
