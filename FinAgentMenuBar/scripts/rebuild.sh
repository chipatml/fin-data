#!/usr/bin/env bash
# Rebuild FinAgentMenuBar from a clean quit and open the built app.
# Run from any directory: FinAgentMenuBar/scripts/rebuild.sh [--no-pull] [--release]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)

PULL=1
CONFIGURATION=Debug

usage() {
  cat <<EOF
Usage: FinAgentMenuBar/scripts/rebuild.sh [--no-pull] [--release]

  Quit FinAgentMenuBar if it is running, build it with xcodebuild, and open
  the .app. By default this also git pull --ff-only in the repo.

  --no-pull   Skip git pull and build the current checkout.
  --release   Build Release instead of Debug.
  -h, --help  Show this help.

  DEVELOPMENT_TEAM defaults to YM26CY2452. Override it in the environment
  to sign with another Apple team.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      PULL=0
      ;;
    --release)
      CONFIGURATION=Release
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

cd "$REPO_ROOT"
echo "Repo: $REPO_ROOT"

if [[ "$PULL" -eq 1 ]]; then
  echo "Pulling latest changes (fast-forward only)..."
  if ! git pull --ff-only; then
    echo "error: git pull failed. Re-run with --no-pull to build this checkout as it is." >&2
    exit 1
  fi
else
  echo "Skipping git pull (--no-pull)."
fi

echo "Quitting FinAgentMenuBar if it is running..."
if pgrep -x FinAgentMenuBar >/dev/null 2>&1; then
  # pkill exits non-zero when the process is already gone. That is success here.
  pkill -x FinAgentMenuBar || true
  for _ in $(seq 1 50); do
    if ! pgrep -x FinAgentMenuBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x FinAgentMenuBar >/dev/null 2>&1; then
    echo "error: FinAgentMenuBar is still running. Quit it and retry." >&2
    exit 1
  fi
  echo "FinAgentMenuBar quit."
else
  echo "FinAgentMenuBar is not running."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is not installed. Install Xcode and its command-line tools, then retry." >&2
  exit 1
fi

TEAM="${DEVELOPMENT_TEAM:-YM26CY2452}"
echo "Building FinAgentMenuBar ($CONFIGURATION), team $TEAM..."
xcodebuild \
  -project FinAgentMenuBar/FinAgentMenuBar.xcodeproj \
  -scheme FinAgentMenuBar \
  -configuration "$CONFIGURATION" \
  -derivedDataPath build \
  "DEVELOPMENT_TEAM=${TEAM}" \
  -allowProvisioningUpdates \
  build

APP="$REPO_ROOT/build/Build/Products/$CONFIGURATION/FinAgentMenuBar.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build finished but $APP was not found." >&2
  exit 1
fi

echo "Opening $APP"
open "$APP"
echo "Done."
