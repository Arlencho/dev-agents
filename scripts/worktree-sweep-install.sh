#!/usr/bin/env bash
#
# worktree-sweep-install.sh
# Helper to install the Worktree Sweep backstop as a macOS background service (launchd)
#
set -euo pipefail

PLIST_NAME="com.arlen.worktree-sweep.plist"
SOURCE_PLIST="docs/worktree-sweep-launchd.plist"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST_PLIST="$DEST_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

echo "=== Worktree Sweep backstop - macOS launchd Installer ==="

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
echo "Worktree Sweep backstop installed and loaded."
echo ""
echo "Useful commands:"
echo "  launchctl list | grep worktree-sweep        # check if running"
echo "  tail -f ~/Library/Logs/worktree-sweep.log"
echo "  make worktree-sweep-uninstall"
echo ""
echo "The sweep will now run once a day automatically."
echo "It sweeps \$OLYMPUS_ROOT, defaulting to the olympus-platform checkout"
echo "under dev-projects/AI-Orchestration. Override with:"
echo "  launchctl setenv OLYMPUS_ROOT /path/to/olympus-platform"
