#!/bin/bash
set -uo pipefail

# Grok plan critic — one-shot cross-vendor review of a wave plan via the Grok
# Build CLI (subscription login, no API key). Invoked by autoplan.sh as the
# Cross-vendor pass; can also be run standalone.
#
# Usage:   ./providers/grok/plan-critic.sh <plan-file>
# Env:     PRIOR_FEEDBACK  optional — feedback from earlier passes
#
# Exit:    0  review printed to stdout (ends with a VERDICT line)
#          3  skipped (grok CLI not installed / not logged in / rate-capped)
#          1  error (bad args)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCHER="$SCRIPT_DIR/launch.sh"

if [ $# -lt 1 ]; then
    echo "Usage: plan-critic.sh <plan-file>" >&2
    exit 1
fi
PLAN_FILE="$1"
[ -f "$PLAN_FILE" ] || { echo "ERROR: plan file not found: $PLAN_FILE" >&2; exit 1; }

command -v grok >/dev/null 2>&1 || { echo "SKIPPED: grok CLI not installed"; exit 3; }

USER_PROMPT="Review this wave plan. Format: [wave] | agent | task | [branch].

## Wave Plan
\`\`\`
$(cat "$PLAN_FILE")
\`\`\`"

if [ -n "${PRIOR_FEEDBACK:-}" ]; then
    USER_PROMPT="${USER_PROMPT}

## Feedback From Prior Passes (same-vendor — do not defer to it)
${PRIOR_FEEDBACK}"
fi

# The launcher injects roles/plan-critic.md as the charter (ROLES_DIR default =
# repo roles/). Map launcher exit codes to the plan-critic contract.
ROLES_DIR="$REPO_DIR/roles" "$LAUNCHER" plan-critic "$USER_PROMPT"
rc=$?

case "$rc" in
    0) exit 0 ;;
    69) echo "SKIPPED: grok CLI not logged in (run 'grok login')"; exit 3 ;;
    75)
        # Rate-capped: record cooldown so dispatch benefits, then skip the pass.
        mkdir -p "$REPO_DIR/logs/provider-state"
        date +%s > "$REPO_DIR/logs/provider-state/grok.cooldown"
        echo "SKIPPED: grok rate-capped"; exit 3 ;;
    *) echo "WARNING: grok plan critic errored (exit $rc)" >&2; exit 1 ;;
esac
