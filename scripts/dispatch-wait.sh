#!/usr/bin/env bash
# Block until a dispatch ends or a timeout passes, then print its summary.
#
# This is what a chat session runs instead of holding the dispatch as its own
# background task: the dispatch was started with --detach and lives in its own
# session, so this waiter can be killed, time out, or be re-run at will without
# touching the run.
#
# Usage:
#   scripts/dispatch-wait.sh <dispatch id> [timeout seconds]
#
# Polls scripts/dispatch-status.sh every 30 seconds (DISPATCH_WAIT_POLL_S to
# change it). With no timeout, or 0, it waits until the run ends.
#
# Exit codes (the same as dispatch-status.sh, so a caller reads one contract):
#   0  the run ended; the summary printed is final
#   3  the timeout passed and the run is still going; the summary is a snapshot
#   2  no such dispatch, or bad usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$SCRIPT_DIR/dispatch-status.sh"

ID="${1:-}"
TIMEOUT="${2:-0}"
POLL_S="${DISPATCH_WAIT_POLL_S:-30}"

if [ -z "$ID" ] || [ "$ID" = "-h" ] || [ "$ID" = "--help" ]; then
    echo "Usage: dispatch-wait.sh <dispatch id> [timeout seconds]   (exit 0 ended, 3 timed out, 2 unknown)" >&2
    exit 2
fi
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "dispatch-wait.sh: timeout must be a whole number of seconds, got '$TIMEOUT'" >&2; exit 2 ;;
esac
case "$POLL_S" in
    ''|*[!0-9]*|0) POLL_S=30 ;;
esac

start=$(date +%s)
while :; do
    "$STATUS" "$ID" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        3) ;;                         # still running
        *) "$STATUS" "$ID"; exit $? ;;  # ended (0) or unknown (2): print and pass it on
    esac
    if [ "$TIMEOUT" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ]; then
        echo "dispatch-wait: ${TIMEOUT}s passed, $ID still running (snapshot below)"
        "$STATUS" "$ID"
        exit 3
    fi
    sleep "$POLL_S"
done
