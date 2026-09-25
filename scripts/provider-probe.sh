#!/bin/bash
set -euo pipefail
# Provider probe: one minimal call through a vendor CLI, classified exactly
# like a seat (providers/lib.sh run_and_classify). dispatch.sh runs this
# before starting a seat on a provider+model that is held for a spend or
# session limit (issue #84): exit 0 releases the hold, anything else keeps it.
# Limits are per account, so the probe is valid from the dispatcher host.
#
# Usage: provider-probe.sh <provider> [model]
# Exit:  0 the provider answered · 78 provider limit · 75 rate cap
#        69 CLI missing / not logged in · 1 any other failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../providers/lib.sh
source "$SCRIPT_DIR/../providers/lib.sh"

PROVIDER="${1:?usage: provider-probe.sh <provider> [model]}"
export AGENT_MODEL="${2:-}"

# A probe that hangs must not stall a dispatch: the watchdog stops it after
# two quiet minutes instead of the seat default of thirty.
export SEAT_QUIET_AFTER_S="${SEAT_PROBE_QUIET_S:-120}"

PROBE_PROMPT="Reply with the single word: ok"
# A shell variable, not an export: the classifier drops output lines that
# appear verbatim in the prompt.
# shellcheck disable=SC2034  # read by run_and_classify in the sourced lib.sh
AGENT_PROMPT_TEXT="$PROBE_PROMPT"

# Print mode takes the prompt from argv, so detach stdin: a caller may still
# be reading a script from the same descriptor.
exec 0</dev/null

case "$PROVIDER" in
    claude)
        run_and_classify claude \
            claude -p --output-format stream-json --verbose --dangerously-skip-permissions "$PROBE_PROMPT"
        ;;
    kimi)
        run_and_classify kimi \
            kimi -p "$PROBE_PROMPT" --output-format text
        ;;
    grok)
        run_and_classify grok \
            grok -p "$PROBE_PROMPT"
        ;;
    codex)
        # Read-only, no session file, git check skipped: the probe runs from
        # the dispatcher host, not a seat worktree, and only has to answer.
        run_and_classify codex \
            codex exec --skip-git-repo-check --sandbox read-only --ephemeral --color never "$PROBE_PROMPT"
        ;;
    *)
        echo "provider-probe: unknown provider '$PROVIDER'" >&2
        exit "$EXIT_UNAVAILABLE"
        ;;
esac
