# FinAgentMenuBar

macOS menu-bar app. Day files live under `~/Library/Application Support/FinAgentMenuBar/Data`.

## Rebuild and relaunch

From any directory:

```bash
FinAgentMenuBar/scripts/rebuild.sh
```

The script fast-forwards the current branch, quits FinAgentMenuBar if it is open, builds the Debug app, and opens it. Derived data goes in `build/` at the repo root, which is gitignored.

```bash
FinAgentMenuBar/scripts/rebuild.sh --no-pull    # build this checkout without pulling
FinAgentMenuBar/scripts/rebuild.sh --release    # Release configuration
```

`DEVELOPMENT_TEAM` defaults to `YM26CY2452`. Set that environment variable to use another Apple team. The script exits with an error if `xcodebuild` is not installed.
