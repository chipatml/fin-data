"""Regression tests for reading FinAgentMenuBar daily records:

- accounts live under ``snapshot.accounts`` (only in the run-day file), not at
  the top level, and must still join to transactions in *earlier* folders;
- the agent's own ``_bookkeeping`` store must not be read as a pull folder.
"""

from pathlib import Path

from bookkeeping_agent.plaid_loader import accounts_from_payload, load_plaid_folder

SAMPLE = Path(__file__).resolve().parents[1] / "samples" / "finagent_parent"


def test_accounts_read_from_snapshot():
    payload = {
        "snapshot": {"accounts": [{"account_id": "a1", "name": "Checking", "type": "depository"}]},
        "transactions": [],
    }
    accts = accounts_from_payload(payload)
    assert "a1" in accts
    assert accts["a1"]["name"] == "Checking"


def test_accounts_still_read_from_top_level():
    payload = {"accounts": [{"account_id": "a2", "name": "Visa"}], "transactions": []}
    assert "a2" in accounts_from_payload(payload)


def test_snapshot_accounts_join_earlier_transactions():
    """The run-day snapshot (sorts last) must tag transactions in earlier folders."""
    bundle = load_plaid_folder(SAMPLE)
    assert bundle["account_count"] == 1
    by_id = {t["transaction_id"]: t for t in bundle["transactions"]}

    # tx_grocery is in 2026-07-10 (no snapshot there); accounts only appear in
    # the 2026-07-25 file, which is processed last. The two-pass load must still
    # resolve its account name/type/subtype.
    grocery = by_id["tx_grocery"]
    assert grocery["account_name"] == "Adv Plus Banking"
    assert grocery["account_type"] == "depository"
    assert grocery["account_subtype"] == "checking"

    # And the run-day transaction too.
    assert by_id["tx_gas"]["account_name"] == "Adv Plus Banking"


def test_account_summary_includes_balances():
    bundle = load_plaid_folder(SAMPLE)
    acct = bundle["accounts"][0]
    assert acct["mask"] == "3996"
    assert acct["balances"]["current"] == 5210.44


def test_bookkeeping_store_not_treated_as_pull():
    bundle = load_plaid_folder(SAMPLE)
    assert "_bookkeeping" not in bundle["pulls"]
    assert bundle["pulls"] == ["2026-07-10", "2026-07-25"]
    # The store's categories.json must not leak in as a transaction/error.
    assert bundle["transaction_count"] == 2
    assert bundle["errors"] == []


def test_account_name_filter_works_via_join():
    from bookkeeping_agent.plaid_loader import filter_transactions

    bundle = load_plaid_folder(SAMPLE)
    checking = filter_transactions(bundle["transactions"], account_name="Adv Plus")
    assert {t["transaction_id"] for t in checking} == {"tx_grocery", "tx_gas"}
