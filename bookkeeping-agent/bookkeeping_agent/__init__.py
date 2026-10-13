__all__ = ["build_agent", "run_review", "PLAID_TOOLS"]


def __getattr__(name: str):
    if name in {"build_agent", "run_review"}:
        from bookkeeping_agent.agent import build_agent, run_review

        return {"build_agent": build_agent, "run_review": run_review}[name]
    if name == "PLAID_TOOLS":
        from bookkeeping_agent.tools import PLAID_TOOLS

        return PLAID_TOOLS
    raise AttributeError(name)
