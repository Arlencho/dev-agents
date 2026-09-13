#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="com.arlen.queue-runner.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Unloading and removing the queue runner..."

launchctl unload "$DEST_PLIST" 2>/dev/null || true
rm -f "$DEST_PLIST"

echo "Uninstalled. The queue runner will no longer tick."
echo "A dispatch it already started keeps running (it is a session of its own); check with scripts/dispatch-status.sh <id>."
echo "Log file still exists at ~/Library/Logs/queue-runner.log (you can delete it manually if desired)."
