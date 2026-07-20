#!/bin/bash
set -euo pipefail
# Grok Build launcher (xAI, subscription login via 'grok login' — no API keys).
# Contract: see providers/lib.sh header.
#
# Charter injection mirrors the kimi launcher: Grok Build has no --agent
# equivalent, so roles/<role>.md rides at the top of the prompt.

# Headless one-shot flag, QA-verified against grok 0.2.103 (2026-07-20):
# `-p, --single <PROMPT>` — "Single-turn prompt. Prints the response to stdout
# and exits". Note: headless mode DOES perform file edits, not prose-only.
GROK_HEADLESS_ARGS=(-p)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh" 2>/dev/null || source "$SCRIPT_DIR/lib.sh"

ROLE="${1:?usage: launch.sh <role> <task>}"
TASK="${2:?usage: launch.sh <role> <task>}"

command -v grok >/dev/null 2>&1 || {
    echo "grok CLI not found — install Grok Build (curl -fsSL https://x.ai/cli/install.sh | bash), then 'grok login'" >&2
    exit "$EXIT_UNAVAILABLE"
}

ROLES_DIR="${ROLES_DIR:-$SCRIPT_DIR/../../roles}"
CHARTER_FILE="$ROLES_DIR/$ROLE.md"

PROMPT="$TASK"
if [ -f "$CHARTER_FILE" ]; then
    PROMPT="## Your Role Charter
$(strip_frontmatter "$CHARTER_FILE")

## Task
$TASK"
else
    echo "WARNING: charter $CHARTER_FILE not found — running without role charter" >&2
fi

# Claude tier aliases are meaningless here; pass through vendor-native IDs only.
MODEL_FLAG=()
case "${AGENT_MODEL:-}" in
    ""|opus|sonnet|haiku) ;;
    *) MODEL_FLAG=(--model "$AGENT_MODEL") ;;
esac

# ${arr[@]+…} guard: empty-array expansion errors under `set -u` on bash 3.2 (macOS).
run_and_classify grok \
    grok "${GROK_HEADLESS_ARGS[@]}" "$PROMPT" ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}
