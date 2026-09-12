#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="com.arlen.worktree-sweep.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Unloading and removing the Worktree Sweep backstop..."

launchctl unload "$DEST_PLIST" 2>/dev/null || true
rm -f "$DEST_PLIST"

echo "Uninstalled. The sweep will no longer run automatically."
echo "Log file still exists at ~/Library/Logs/worktree-sweep.log (you can delete it manually if desired)."
