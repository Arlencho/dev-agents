#!/usr/bin/env bash
#
# local-sentinel-install.sh
# Helper to install the Local PR Sentinel as a macOS background service (launchd)
#
set -euo pipefail

PLIST_NAME="com.arlen.local-pr-sentinel.plist"
SOURCE_PLIST="docs/local-pr-sentinel-launchd.plist"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$DEST_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

echo "=== Local PR Sentinel — macOS launchd Installer ==="

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
echo "✅ Local PR Sentinel installed and loaded."
echo ""
echo "Useful commands:"
echo "  launchctl list | grep local-pr-sentinel     # check if running"
echo "  tail -f ~/Library/Logs/local-pr-sentinel.log"
echo "  make local-sentinel-uninstall"
echo ""
echo "The sentinel will now run every 30 minutes automatically."
