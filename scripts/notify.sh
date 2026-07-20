#!/bin/bash
set -euo pipefail

# Send completion notifications for agent tasks.
#
# Usage:
#   ./scripts/notify.sh <agent> <worker> <branch> <status> [detail]
#
# Status: "success" | "failure" | "ratecap"
# Detail: optional 5th arg — for "ratecap", the vendor name being failed over
#
# Notification channels:
#   - macOS: native notification via osascript (always, if on macOS)
#   - GitHub: comment on issue if GITHUB_ISSUE env var is set (format: owner/repo#123)
#   - Fallback: prints to stdout
#
# Environment variables:
#   GITHUB_ISSUE  — if set, posts a comment on the issue (e.g., "Arlencho/olympus-platform#42")

AGENT="${1:?Usage: notify.sh <agent> <worker> <branch> <status> [detail]}"
WORKER="${2:?Missing worker name}"
BRANCH="${3:?Missing branch name}"
STATUS="${4:?Missing status (success/failure/ratecap)}"
DETAIL="${5:-}"

if [ "$STATUS" = "success" ]; then
    TITLE="Agent Succeeded"
    MSG="$AGENT on $WORKER completed ($BRANCH)"
    GH_EMOJI=":white_check_mark:"
elif [ "$STATUS" = "ratecap" ]; then
    TITLE="Provider Rate-Capped"
    MSG="$AGENT on $WORKER: ${DETAIL:-provider} cap hit — failing over ($BRANCH)"
    GH_EMOJI=":hourglass_flowing_sand:"
else
    TITLE="Agent Failed"
    MSG="$AGENT on $WORKER failed ($BRANCH)"
    GH_EMOJI=":x:"
fi

# --------------------------------------------------
# macOS notification
# --------------------------------------------------
if [ "$(uname)" = "Darwin" ]; then
    osascript -e "display notification \"$MSG\" with title \"$TITLE\"" 2>/dev/null || true
fi

# --------------------------------------------------
# GitHub issue comment
# --------------------------------------------------
if [ -n "${GITHUB_ISSUE:-}" ]; then
    # Parse owner/repo#number
    if [[ "$GITHUB_ISSUE" =~ ^(.+)#([0-9]+)$ ]]; then
        GH_REPO="${BASH_REMATCH[1]}"
        GH_NUMBER="${BASH_REMATCH[2]}"
        COMMENT="$GH_EMOJI **$AGENT** on \`$WORKER\`: $STATUS${DETAIL:+ ($DETAIL)} (\`$BRANCH\`)"
        gh issue comment "$GH_NUMBER" -R "$GH_REPO" --body "$COMMENT" 2>/dev/null || \
            echo "WARNING: Failed to comment on $GITHUB_ISSUE"
    else
        echo "WARNING: GITHUB_ISSUE format should be owner/repo#123, got: $GITHUB_ISSUE"
    fi
fi

# --------------------------------------------------
# Stdout fallback (always)
# --------------------------------------------------
echo "[notify] $TITLE: $MSG"
