# Bookkeeping agent (LangChain + Plaid folders)

Expert bookkeeper agent: categorizes spend, flags waste, and proposes cuts.
A tool reads Plaid JSON dumps laid out as daily folders.

## Folder structure

```text
PARENT/
  2026-08-01/            # daily folder (YYYY-MM-DD)
    checking.json
    visa.json
  2026-08-15/
    visa.json
  _bookkeeping/          # reserved: category memory (written by the agent)
    categories.json
```

Each account JSON file may be any of:

- **`/transactions/sync`** — `added` / `modified` / `removed`.
- **`/transactions/get`** — `transactions` array plus top-level `accounts`.
- **A raw transaction array** — `[ {...}, {...} ]`.
- **A FinAgentMenuBar daily record** — top-level `transactions` (array),
  `investmentTransactions`, `label`, and a `snapshot` object. For these, account
  metadata (name / type / subtype / mask / balances) lives under
  **`snapshot.accounts`**, and only in the run-day file — the loader collects
  accounts across *all* files before joining, so transactions in earlier folders
  still resolve their account. Transactions are bucketed into the folder matching
  their own posted date, and each `transaction_id` is deduped (latest pull wins).

Folders are discovered by name: hidden (`.`) and reserved (`_`) directories are
skipped, so the agent's own `_bookkeeping/` category store is never read as a
pull. Accounts join to transactions by `account_id`; when an account is unknown
the row is still kept, with `account_*` fields left null.

## Setup

```bash
cd bookkeeping-agent
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export XAI_API_KEY=...          # preferred
# or: export OPENAI_API_KEY=...
export BOOKKEEPING_MODEL=grok-4 # optional
```

## Inspect without an LLM

```bash
python -m bookkeeping_agent /path/to/PARENT --inspect-only --start 2026-07-01 --end 2026-07-31
```

Sample dumps ship under `samples/plaid_parent`.

## Run the agent

```bash
python -m bookkeeping_agent /path/to/PARENT \
  --start 2026-07-01 --end 2026-07-31 \
  --goals "cut $400/mo discretionary, keep housing" \
  --constraints "keep one streaming service"
```

From Python:

```python
from bookkeeping_agent import build_agent, run_review

print(run_review(
    parent="/path/to/PARENT",
    period_start="2026-07-01",
    period_end="2026-07-31",
    goals="identify zombie subscriptions",
))

agent = build_agent()
result = agent.invoke({
    "messages": [{
        "role": "user",
        "content": "Review July 2026 in /path/to/PARENT. Pending off.",
    }]
})
print(result["messages"][-1].content)
```

## Tools the model can call

| Tool | Purpose |
|---|---|
| `list_plaid_pulls` | Daily folders + JSON filenames |
| `extract_plaid_folder` | Flatten, dedupe by `transaction_id`, filter period/account, drop pending |
| `load_category_map` | Read the persisted merchant → house-category memory |
| `save_category_map` | Upsert merchant → category decisions so future closes stay consistent |
| `detect_recurring` | Find subscriptions/recurring charges; flag price hikes and duplicate services |

Dedupe: latest pull wins. Sync `removed` ids are dropped. Plaid sign is preserved
(positive = outflow). Row cap defaults to 250 (hard max 400).

### Category memory

`load_category_map` / `save_category_map` persist a merchant → house-category map
at `PARENT/_bookkeeping/categories.json`, keyed by normalized merchant name (so
`SQ *STARBUCKS #12` and `STARBUCKS` share one memory). Call `load_category_map`
before coding, then `save_category_map` after, so categorization stays consistent
month over month.

### Recurring detection

`detect_recurring` groups posted outflows by normalized merchant, infers cadence
(weekly … annual), computes a monthly/annual run-rate, and flags `price_increase`,
`price_decrease`, `duplicate_service_class` (e.g. two streaming services), and
`single_occurrence`. Deterministic — use it for the zombie-subscription,
cadence-drift, and duplicate-service waste tests instead of eyeballing rows.

## Tests

```bash
PYTHONPATH=. python -m pytest tests/test_plaid_loader.py -q
```
