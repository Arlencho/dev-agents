#!/bin/bash
set -euo pipefail

# Grok plan critic — one-shot cross-vendor review of a wave plan.
# Invoked by autoplan.sh as the Cross-vendor pass; can also be run standalone.
#
# Usage:
#   ./providers/grok/plan-critic.sh <plan-file>
#
# Env:
#   XAI_API_KEY     required — xAI API key (https://console.x.ai)
#   GROK_MODEL      model ID (default: grok-4.3)
#   GROK_ENDPOINT   chat completions URL (default: https://api.x.ai/v1/chat/completions)
#   PRIOR_FEEDBACK  optional — feedback from earlier review passes, included in the prompt
#   GROK_DRY_RUN    if set, print the request body and exit without calling the API
#
# Exit codes: 0 = review printed to stdout (ends with VERDICT line)
#             3 = skipped (no XAI_API_KEY)
#             1 = error (bad args, API failure, unparseable response)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHARTER="$REPO_DIR/roles/plan-critic.md"

if [ $# -lt 1 ]; then
    echo "Usage: plan-critic.sh <plan-file>" >&2
    exit 1
fi

PLAN_FILE="$1"
[ -f "$PLAN_FILE" ] || { echo "ERROR: plan file not found: $PLAN_FILE" >&2; exit 1; }
[ -f "$CHARTER" ]  || { echo "ERROR: charter not found: $CHARTER" >&2; exit 1; }

if [ -z "${XAI_API_KEY:-}" ]; then
    echo "SKIPPED: XAI_API_KEY not set"
    exit 3
fi

GROK_MODEL="${GROK_MODEL:-grok-4.3}"
GROK_ENDPOINT="${GROK_ENDPOINT:-https://api.x.ai/v1/chat/completions}"

# Charter body = system prompt (strip the YAML frontmatter block)
SYSTEM_PROMPT=$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm!=1' "$CHARTER")

USER_PROMPT="Review this wave plan. Plan file format: [wave] | agent | task description | [branch-name]

## Wave Plan
\`\`\`
$(cat "$PLAN_FILE")
\`\`\`"

if [ -n "${PRIOR_FEEDBACK:-}" ]; then
    USER_PROMPT="${USER_PROMPT}

## Feedback From Prior Review Passes (same-vendor — do not defer to it)
${PRIOR_FEEDBACK}"
fi

BODY=$(jq -n \
    --arg model "$GROK_MODEL" \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$USER_PROMPT" \
    '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}]}')

if [ -n "${GROK_DRY_RUN:-}" ]; then
    echo "$BODY"
    exit 0
fi

RESPONSE=$(curl -sS --max-time 300 \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    "$GROK_ENDPOINT") || { echo "ERROR: xAI API call failed" >&2; exit 1; }

CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [ -z "$CONTENT" ]; then
    echo "ERROR: no content in xAI response:" >&2
    echo "$RESPONSE" | head -c 2000 >&2
    exit 1
fi

echo "$CONTENT"
