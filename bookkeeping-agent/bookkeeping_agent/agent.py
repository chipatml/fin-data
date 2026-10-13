from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from langchain.agents import create_agent

from bookkeeping_agent.prompt import SYSTEM_PROMPT
from bookkeeping_agent.tools import PLAID_TOOLS

# bookkeeping-agent/.env, regardless of the process cwd. Existing env vars win.
load_dotenv(Path(__file__).resolve().parents[1] / ".env")


def _model():
    name = os.environ.get("BOOKKEEPING_MODEL", "grok-4")
    if os.environ.get("XAI_API_KEY"):
        from langchain_xai import ChatXAI

        return ChatXAI(model=name, temperature=0)
    if os.environ.get("OPENAI_API_KEY"):
        from langchain_openai import ChatOpenAI

        model = os.environ.get("BOOKKEEPING_MODEL", "gpt-4o")
        return ChatOpenAI(model=model, temperature=0)
    raise RuntimeError(
        "Set XAI_API_KEY (preferred) or OPENAI_API_KEY. "
        "Optional: BOOKKEEPING_MODEL (default grok-4 / gpt-4o)."
    )


def build_agent():
    return create_agent(
        model=_model(),
        tools=PLAID_TOOLS,
        system_prompt=SYSTEM_PROMPT,
    )


def run_review(
    parent: str,
    period_start: str | None = None,
    period_end: str | None = None,
    goals: str | None = None,
    constraints: str | None = None,
) -> str:
    agent = build_agent()
    user = (
        "Close the books for the Plaid dumps in this parent folder.\n"
        f"Parent folder: {parent}\n"
        f"Period start: {period_start or 'infer from data'}\n"
        f"Period end: {period_end or 'infer from data'}\n"
        f"Goals: {goals or 'identify unnecessary spend and reachable savings'}\n"
        f"Constraints: {constraints or 'none stated'}\n"
        "Include pending: no.\n"
        "Load the category map, extract the period, and run detect_recurring; "
        "save new or changed codings with save_category_map, then write the full report."
    )
    result = agent.invoke({"messages": [{"role": "user", "content": user}]})
    messages = result.get("messages") or []
    last = messages[-1]
    content = getattr(last, "content", last)
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts).strip()
    return str(content)
