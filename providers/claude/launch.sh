#!/bin/bash
set -euo pipefail
# Claude Code launcher — wraps the historical run-remote invocation.
# Contract: see providers/lib.sh header.

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

command -v claude >/dev/null 2>&1 || {
    echo "claude CLI not found — npm install -g @anthropic-ai/claude-code, then 'claude login'" >&2
    exit "$EXIT_UNAVAILABLE"
}

# Claude owns tier aliases (opus/sonnet/haiku) and full model IDs alike.
MODEL_FLAG=()
[ -n "${AGENT_MODEL:-}" ] && MODEL_FLAG=(--model "$AGENT_MODEL")

# Print mode takes the prompt from argv, so detach stdin: the worker shell is
# still reading the dispatch script from the same descriptor.
exec 0</dev/null

# Streamed output: one JSON object per line, printed as the run happens, so the
# agent log grows during the run instead of arriving in one block at the end.
# --verbose is required by the CLI for streamed print output.
STREAM_ARGS=(-p --output-format stream-json --verbose)

# NOTE: if claude ever HANGS at the Max usage cap instead of exiting, wrap
# this in `timeout` — see plan risk log.
# ${arr[@]+…} guard: empty-array expansion errors under `set -u` on bash 3.2 (macOS).
# A shell variable, not an export: the classifier drops output lines that
# appear verbatim in the prompt, and the CLI must not carry a second copy.
AGENT_PROMPT_TEXT="$TASK"
run_and_classify claude \
    claude "${STREAM_ARGS[@]}" --agent "$ROLE" ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"} --dangerously-skip-permissions "$TASK"
