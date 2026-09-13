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

echo "=== Queue runner - macOS launchd Installer ==="

if [[ ! -f "$SOURCE_PLIST" ]]; then
    echo "ERROR: $SOURCE_PLIST not found. Run from the dev-agents root."
    exit 1
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
echo "The dev-agents checkout defaults to the one under dev-projects/AI-Orchestration. Override with:"
echo "  launchctl setenv DEV_AGENTS_ROOT /path/to/dev-agents"
