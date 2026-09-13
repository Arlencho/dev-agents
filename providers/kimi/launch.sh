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
# Decision: the catch-all seat gets a real charter (roles/claude.md) rather than
# a special case here, so every dispatched role name resolves to a file.
# Resolve the charter explicitly anyway: a role with no file under roles/ must
# leave CHARTER_FILE empty and quoted, never a half-built word the shell runs.
CHARTER_FILE=""
if [ -n "${ROLE:-}" ] && [ -n "${ROLES_DIR:-}" ] && [ -f "$ROLES_DIR/$ROLE.md" ]; then
    CHARTER_FILE="$ROLES_DIR/$ROLE.md"
fi

PROMPT="$TASK"
if [ -n "$CHARTER_FILE" ]; then
    PROMPT="## Your Role Charter
$(strip_frontmatter "$CHARTER_FILE")

## Task
$TASK"
else
    echo "WARNING: no charter for role '$ROLE' under $ROLES_DIR, running without a role charter" >&2
fi

# AGENT_MODEL: Claude tier / product aliases are meaningless on Kimi — ignore
# them and use the CLI default (K3). Only pass through true vendor-native IDs.
# (Failover used to forward docs-writer's claude-fable-5 and break kimi.)
MODEL_FLAG=()
case "${AGENT_MODEL:-}" in
    ""|opus|sonnet|haiku|claude-fable-5|claude-*|fable-*) ;;
    *) MODEL_FLAG=(--model "$AGENT_MODEL") ;;
esac

# If the kimi CLI ever truncates long argv prompts, switch to stdin piping here.
# ${arr[@]+…} guard: empty-array expansion errors under `set -u` on bash 3.2 (macOS).
# A shell variable, not an export: the classifier drops output lines that
# appear verbatim in the prompt, and the CLI must not carry a second copy.
# shellcheck disable=SC2034  # read by run_and_classify in the sourced lib.sh
AGENT_PROMPT_TEXT="$PROMPT"
run_and_classify kimi \
    kimi -p "$PROMPT" --output-format text ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}
