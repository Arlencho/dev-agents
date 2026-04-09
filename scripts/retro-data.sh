#!/bin/bash
set -euo pipefail

# Collects and formats data for the retro agent.
# Reads wave plans, execution logs, learnings, git stats, and PR history.
#
# Usage:
#   ./scripts/retro-data.sh [project-name]
#
# Output: structured markdown to stdout (pipe to retro agent or save to file)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WAVE_PLANS_DIR="$REPO_DIR/wave-plans"
LEARNINGS_DIR="$REPO_DIR/learnings"

PROJECT="${1:-all}"

echo "# Retro Data Collection"
echo ""
echo "**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "**Project filter**: $PROJECT"
echo ""

# ---- Wave Plan History ----
echo "## Wave Plan History"
echo ""

plan_count=0
if [ -d "$WAVE_PLANS_DIR" ]; then
    for plan_file in "$WAVE_PLANS_DIR"/*.plan; do
        [ -f "$plan_file" ] || continue
        if [ "$PROJECT" != "all" ] && ! echo "$plan_file" | grep -qi "$PROJECT"; then
            continue
        fi
        plan_count=$((plan_count + 1))
        echo "### $(basename "$plan_file")"
        echo '```'
        cat "$plan_file"
        echo '```'
        echo ""
    done
fi

if [ "$plan_count" -eq 0 ]; then
    echo "_No wave plans found._"
    echo ""
fi

# ---- Execution Logs ----
echo "## Execution Logs"
echo ""

log_count=0
if [ -d "$WAVE_PLANS_DIR" ]; then
    for log_file in "$WAVE_PLANS_DIR"/*.log; do
        [ -f "$log_file" ] || continue
        if [ "$PROJECT" != "all" ] && ! echo "$log_file" | grep -qi "$PROJECT"; then
            continue
        fi
        log_count=$((log_count + 1))
        echo "### $(basename "$log_file")"
        echo '```'
        cat "$log_file"
        echo '```'
        echo ""
    done
fi

if [ "$log_count" -eq 0 ]; then
    echo "_No execution logs found._"
    echo ""
fi

# ---- Learnings ----
echo "## Learnings"
echo ""

learning_count=0
if [ -d "$LEARNINGS_DIR" ]; then
    for learning_file in "$LEARNINGS_DIR"/*.jsonl; do
        [ -f "$learning_file" ] || continue
        if [ "$PROJECT" != "all" ] && ! echo "$learning_file" | grep -qi "$PROJECT"; then
            continue
        fi
        learning_count=$((learning_count + 1))
        line_count=$(wc -l < "$learning_file" | xargs)
        echo "### $(basename "$learning_file") ($line_count entries)"
        echo '```jsonl'
        # Show last 50 entries to keep output manageable
        tail -50 "$learning_file"
        echo '```'
        echo ""
    done
fi

if [ "$learning_count" -eq 0 ]; then
    echo "_No learnings found._"
    echo ""
fi

# ---- Git Stats (last 30 days) ----
echo "## Git Stats (last 30 days)"
echo ""

if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    commit_count=$(git -C "$REPO_DIR" log --since="30 days ago" --oneline 2>/dev/null | wc -l | xargs)
    echo "**Commits**: $commit_count"
    echo ""

    echo "### Commits by author"
    echo '```'
    git -C "$REPO_DIR" log --since="30 days ago" --format='%aN' 2>/dev/null | sort | uniq -c | sort -rn || echo "No commits"
    echo '```'
    echo ""

    echo "### Recent commits"
    echo '```'
    git -C "$REPO_DIR" log --since="30 days ago" --oneline --no-decorate -20 2>/dev/null || echo "No commits"
    echo '```'
    echo ""
else
    echo "_Not a git repository._"
    echo ""
fi

# ---- PR Stats ----
echo "## PR Stats (recent merged)"
echo ""

if command -v gh >/dev/null 2>&1; then
    pr_data=$(gh pr list --state merged --limit 20 --json number,title,mergedAt 2>/dev/null || echo "[]")
    if [ "$pr_data" != "[]" ] && [ -n "$pr_data" ]; then
        echo '```json'
        echo "$pr_data"
        echo '```'
    else
        echo "_No merged PRs found (or gh not authenticated for this repo)._"
    fi
else
    echo "_gh CLI not installed._"
fi

echo ""
echo "---"
echo "_Data collection complete. Feed this to the retro agent for analysis._"
