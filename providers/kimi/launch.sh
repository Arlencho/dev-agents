#!/bin/bash
set -euo pipefail
# Kimi Code CLI launcher (Kimi K3 via subscription login — no API keys).
# Contract: see providers/lib.sh header.
#
# Kimi has no --agent equivalent, so the role charter (roles/<role>.md body)
# is injected at the top of the prompt. -p/--prompt runs non-interactively
# with --auto permissions by default; --yolo is NOT combinable with -p.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Existence-checked source: on bash 3.2 (macOS /bin/bash, the ssh worker
# shell), `source missing 2>/dev/null || source …` dies silently under set -e.
# shellcheck source=../lib.sh
if [ -f "$SCRIPT_DIR/../lib.sh" ]; then
    source "$SCRIPT_DIR/../lib.sh"
else
    source "$SCRIPT_DIR/lib.sh"
fi

ROLE="${1:?usage: launch.sh <role> <task>}"
TASK="${2:?usage: launch.sh <role> <task>}"

command -v kimi >/dev/null 2>&1 || {
    echo "kimi CLI not found — install Kimi Code CLI, then 'kimi login' on this machine" >&2
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

# AGENT_MODEL: claude tier aliases are meaningless here — ignore them and use
# the CLI's default model. Pass through anything else (vendor-native ID).
MODEL_FLAG=()
case "${AGENT_MODEL:-}" in
    ""|opus|sonnet|haiku) ;;
    *) MODEL_FLAG=(--model "$AGENT_MODEL") ;;
esac

# If the kimi CLI ever truncates long argv prompts, switch to stdin piping here.
# ${arr[@]+…} guard: empty-array expansion errors under `set -u` on bash 3.2 (macOS).
run_and_classify kimi \
    kimi -p "$PROMPT" --output-format text ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}
