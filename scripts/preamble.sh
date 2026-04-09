#!/usr/bin/env bash
set -euo pipefail

# Session preamble generator -- assembles context for agent startup
# Usage: ./scripts/preamble.sh <repo-path> <agent-name> <branch-name>

REPO_PATH="${1:?Usage: preamble.sh <repo-path> <agent-name> <branch-name>}"
AGENT="${2:?Missing agent name}"
BRANCH="${3:?Missing branch name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/../config/preamble.yaml"

# --- Parse config (grep-based, no yaml lib) ---

cfg_val() {
    grep "^${1}:" "$CONFIG" 2>/dev/null | awk '{print $2}' || echo "$2"
}

CLAUDE_MD_MAX=$(cfg_val claude_md_max_lines 200)
LEARNINGS_MAX=$(cfg_val learnings_max 10)
SHOW_PARALLEL=$(cfg_val show_parallel_sessions true)
SHOW_GIT=$(cfg_val show_git_state true)
SHOW_ISSUE=$(cfg_val show_issue_context true)

SECTIONS=""

# --- a) CLAUDE.md ---

CLAUDE_MD="$REPO_PATH/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    CONTENT=$(head -n "$CLAUDE_MD_MAX" "$CLAUDE_MD")
    TOTAL_LINES=$(wc -l < "$CLAUDE_MD" | tr -d ' ')
    TRUNCATED=""
    if [ "$TOTAL_LINES" -gt "$CLAUDE_MD_MAX" ]; then
        TRUNCATED=" (truncated to $CLAUDE_MD_MAX of $TOTAL_LINES lines)"
    fi
    SECTIONS+="## Project Notes${TRUNCATED}
${CONTENT}

"
fi

# --- b) Learnings ---

if [ -x "$SCRIPT_DIR/learnings.sh" ]; then
    PROJECT=$(basename "$REPO_PATH")
    LEARNINGS=$("$SCRIPT_DIR/learnings.sh" query "$PROJECT" --agent "$AGENT" --limit "$LEARNINGS_MAX" 2>/dev/null || true)
    if [ -n "$LEARNINGS" ]; then
        FORMATTED=""
        while IFS= read -r line; do
            FORMATTED+="- ${line}
"
        done <<< "$LEARNINGS"
        SECTIONS+="## Relevant Learnings
${FORMATTED}
"
    fi
fi

# --- c) Parallel sessions ---

if [ "$SHOW_PARALLEL" = "true" ]; then
    PARALLEL=$(ps aux 2>/dev/null | grep "claude.*--agent" | grep -v grep | grep -v "$$" || true)
    if [ -n "$PARALLEL" ]; then
        FORMATTED=""
        while IFS= read -r line; do
            # Extract agent name and any branch hint from the command
            AGENT_NAME=$(echo "$line" | grep -oP '(?<=--agent )\S+' || echo "unknown")
            BRANCH_HINT=$(echo "$line" | grep -oP '(?<=checkout -b )\S+' || echo "")
            if [ -n "$BRANCH_HINT" ]; then
                FORMATTED+="- ${AGENT_NAME} on ${BRANCH_HINT}
"
            else
                FORMATTED+="- ${AGENT_NAME}
"
            fi
        done <<< "$PARALLEL"
        SECTIONS+="## Parallel Sessions
${FORMATTED}(avoid editing files these agents are working on)

"
    fi
fi

# --- d) Git state ---

if [ "$SHOW_GIT" = "true" ] && [ -d "$REPO_PATH/.git" ]; then
    GIT_SECTION=""

    CURRENT_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    MAIN_SHA=$(git -C "$REPO_PATH" rev-parse --short main 2>/dev/null || git -C "$REPO_PATH" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_SECTION+="Branch: ${BRANCH} (from main @ ${MAIN_SHA})"

    RECENT=$(git -C "$REPO_PATH" log main --oneline -5 2>/dev/null || true)
    if [ -n "$RECENT" ]; then
        GIT_SECTION+="
Recent:
${RECENT}"
    fi

    UNCOMMITTED=$(git -C "$REPO_PATH" status --porcelain 2>/dev/null || true)
    if [ -n "$UNCOMMITTED" ]; then
        COUNT=$(echo "$UNCOMMITTED" | wc -l | tr -d ' ')
        GIT_SECTION+="
Uncommitted: ${COUNT} file(s) modified"
    fi

    SECTIONS+="## Git State
${GIT_SECTION}

"
fi

# --- e) Issue context ---

if [ "$SHOW_ISSUE" = "true" ] && command -v gh >/dev/null 2>&1; then
    # Extract issue number from branch name (e.g., feat/421-confirm-duffel -> 421)
    ISSUE_NUM=$(echo "$BRANCH" | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "$ISSUE_NUM" ]; then
        ISSUE_DATA=$(gh issue view "$ISSUE_NUM" --json title,body --jq '.title + "\n" + .body' -R "$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || echo "")" 2>/dev/null || true)
        if [ -n "$ISSUE_DATA" ]; then
            ISSUE_TITLE=$(echo "$ISSUE_DATA" | head -1)
            ISSUE_BODY=$(echo "$ISSUE_DATA" | tail -n +2 | head -c 500)
            SECTIONS+="## Issue Context (#${ISSUE_NUM})
${ISSUE_TITLE}
${ISSUE_BODY}

"
        fi
    fi
fi

# --- Output ---

if [ -n "$SECTIONS" ]; then
    echo "=== SESSION CONTEXT (auto-generated) ===
"
    echo "$SECTIONS"
    echo "=== END SESSION CONTEXT ==="
fi
