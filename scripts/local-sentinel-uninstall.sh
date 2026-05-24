#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="com.arlen.local-pr-sentinel.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Unloading and removing Local PR Sentinel..."

launchctl unload "$DEST_PLIST" 2>/dev/null || true
rm -f "$DEST_PLIST"

echo "✅ Uninstalled. The service will no longer run automatically."
echo "Log file still exists at ~/Library/Logs/local-pr-sentinel.log (you can delete it manually if desired)."
