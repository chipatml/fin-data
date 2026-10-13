from __future__ import annotations

import argparse

from bookkeeping_agent.agent import run_review
from bookkeeping_agent.plaid_loader import filter_transactions, load_plaid_folder, period_stats


def main() -> None:
    parser = argparse.ArgumentParser(description="Expert bookkeeping agent over Plaid daily folders")
    parser.add_argument("parent", help="Parent folder of daily Plaid JSON dumps")
    parser.add_argument("--start", dest="start", help="Inclusive posted date YYYY-MM-DD")
    parser.add_argument("--end", dest="end", help="Inclusive posted date YYYY-MM-DD")
    parser.add_argument("--goals", default=None)
    parser.add_argument("--constraints", default=None)
    parser.add_argument(
        "--inspect-only",
        action="store_true",
        help="Flatten and print stats only; do not call the LLM",
    )
    args = parser.parse_args()

    if args.inspect_only:
        bundle = load_plaid_folder(args.parent)
        rows = filter_transactions(
            bundle["transactions"],
            start_date=args.start,
            end_date=args.end,
        )
        stats = period_stats(rows)
        print(f"parent: {bundle['parent']}")
        print(f"pulls: {bundle['pulls']}")
        print(f"accounts: {len(bundle['accounts'])}")
        print(f"matched: {stats}")
        return

    print(run_review(args.parent, args.start, args.end, args.goals, args.constraints))


if __name__ == "__main__":
    main()
