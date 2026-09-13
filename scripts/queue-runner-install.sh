#!/usr/bin/env bash
#
# queue-runner-install.sh
# Helper to install the queue runner as a macOS background service (launchd)
#
set -euo pipefail

PLIST_NAME="com.arlen.queue-runner.plist"
SOURCE_PLIST="docs/queue-runner-launchd.plist"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$DEST_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

DRY_RUN=false
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    "") ;;
    -h|--help) echo "Usage: queue-runner-install.sh [--dry-run]"; exit 0 ;;
    *) echo "queue-runner-install.sh: unknown flag $1" >&2; exit 2 ;;
esac

echo "=== Queue runner - macOS launchd Installer ==="

if [[ ! -f "$SOURCE_PLIST" ]]; then
    echo "ERROR: $SOURCE_PLIST not found. Run from the dev-agents root."
    exit 1
fi

# The plist must parse before it is ever handed to launchctl; the runner and
# its helper must at least be executable and syntactically sound.
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$SOURCE_PLIST"
fi
bash -n scripts/queue-runner.sh
python3 -m py_compile scripts/queue_loop.py
[[ -x scripts/queue-runner.sh ]] || { echo "ERROR: scripts/queue-runner.sh is not executable"; exit 1; }
[[ -f config/queue-runner.yaml ]] || { echo "ERROR: config/queue-runner.yaml not found"; exit 1; }

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "Dry run. Install would:"
    echo "  cp $SOURCE_PLIST $DEST_PLIST"
    echo "  launchctl unload $DEST_PLIST   (if loaded)"
    echo "  launchctl load -w $DEST_PLIST"
    echo "Currently loaded: $(launchctl list 2>/dev/null | grep -c 'com.arlen.queue-runner' | tr -d ' ') service(s) named com.arlen.queue-runner"
    echo "Memory guard thresholds (config/queue-runner.yaml):"
    grep -E '^\s+(min_free_percent|max_swap_used_gb):' config/queue-runner.yaml | sed 's/^/  /'
    echo "Nothing installed."
    exit 0
fi

mkdir -p "$DEST_DIR"
mkdir -p "$LOG_DIR"

echo "Copying plist to $DEST_PLIST ..."
cp "$SOURCE_PLIST" "$DEST_PLIST"

echo "Loading service (launchctl load -w) ..."
launchctl unload "$DEST_PLIST" 2>/dev/null || true
launchctl load -w "$DEST_PLIST"

echo ""
echo "Queue runner installed and loaded."
echo ""
echo "Useful commands:"
echo "  launchctl list | grep queue-runner          # check if loaded"
echo "  tail -f ~/Library/Logs/queue-runner.log     # the ticks"
echo "  tail -f logs/dispatch-runs/queue-runner.log # what it started"
echo "  make queue-runner-dry                       # what the next tick would start"
echo "  launchctl setenv QUEUE_RUNNER_PAUSE 1       # pause (unsetenv to resume)"
echo "  make queue-runner-uninstall"
echo ""
echo "The runner now ticks once a minute: one queued, unblocked plan per tick,"
echo "one running dispatch per repo, each started with dispatch.sh --detach."
echo "Each tick also settles ended runs (one fix round on BLOCK-FIX, a landing"
echo "when every critic said SAFE-TO-MERGE and the PR is green and clean, a stop"
echo "for anything else: make stops-list) and holds starts while memory is low"
echo "(config/queue-runner.yaml)."
echo "The dev-agents checkout defaults to the one under dev-projects/AI-Orchestration. Override with:"
echo "  launchctl setenv DEV_AGENTS_ROOT /path/to/dev-agents"
