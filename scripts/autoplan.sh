#!/bin/bash
set -euo pipefail

# Autoplan chaining — runs 3 sequential review passes on a wave plan.
# Uses the plan-reviewer agent for strategy, design, and engineering review.
#
# Usage:
#   ./scripts/autoplan.sh <plan-file>
#
# Passes:
#   1. Strategy  — "Does this plan address the right problem?"
#   2. Design    — "Are wave dependencies and agent assignments correct?"
#   3. Engineering — "Are tasks scoped correctly? Any missing infrastructure?"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: autoplan.sh <plan-file>"
    exit 1
fi

PLAN_FILE="$1"

if [ ! -f "$PLAN_FILE" ]; then
    echo -e "${RED}ERROR: Plan file not found: $PLAN_FILE${NC}"
    exit 1
fi

PLAN_CONTENT=$(cat "$PLAN_FILE")

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Autoplan Review${NC}"
echo -e "${BOLD}==========================================${NC}"
echo ""
echo -e "Plan: ${CYAN}$PLAN_FILE${NC}"
echo ""

# Track verdicts and feedback
declare -a VERDICTS
declare -a FEEDBACKS
PRIOR_FEEDBACK=""

# ---- Pass definitions ----
PASS_NAMES=("Strategy" "Design" "Engineering")
PASS_PROMPTS=(
    "STRATEGY REVIEW: Does this plan address the right problem? Is the scope appropriate? Are there blind spots?"
    "DESIGN REVIEW: Are wave dependencies and agent assignments correct? Do parallel tasks conflict? Are branch names consistent?"
    "ENGINEERING REVIEW: Are tasks scoped for single agents? Any missing infrastructure? Could tasks be parallelized further?"
)

for i in 0 1 2; do
    pass_num=$((i + 1))
    pass_name="${PASS_NAMES[$i]}"
    pass_prompt="${PASS_PROMPTS[$i]}"

    echo -e "${BOLD}------------------------------------------${NC}"
    echo -e "${BOLD}  Pass $pass_num: $pass_name${NC}"
    echo -e "${BOLD}------------------------------------------${NC}"
    echo ""

    # Build the prompt with plan content and prior feedback
    FULL_PROMPT="You are reviewing this wave plan.

${pass_prompt}

## Plan Content
\`\`\`
${PLAN_CONTENT}
\`\`\`"

    if [ -n "$PRIOR_FEEDBACK" ]; then
        FULL_PROMPT="${FULL_PROMPT}

## Feedback From Previous Passes
${PRIOR_FEEDBACK}"
    fi

    FULL_PROMPT="${FULL_PROMPT}

Review the plan and end your response with exactly one of:
VERDICT: APPROVE
VERDICT: REVISE (followed by SUGGESTIONS:)
VERDICT: REJECT (followed by REASONS:)"

    # Run the plan-reviewer agent
    REVIEW_OUTPUT=$(claude --agent "$REPO_DIR/providers/claude/agents/plan-reviewer.md" --print "$FULL_PROMPT" 2>/dev/null || echo "VERDICT: APPROVE")

    echo "$REVIEW_OUTPUT"
    echo ""

    # Extract verdict
    VERDICT=$(echo "$REVIEW_OUTPUT" | grep -oE "VERDICT: (APPROVE|REVISE|REJECT)" | tail -1 | sed 's/VERDICT: //')
    VERDICT="${VERDICT:-APPROVE}"

    VERDICTS+=("$VERDICT")
    FEEDBACKS+=("$REVIEW_OUTPUT")

    # Accumulate feedback for subsequent passes
    PRIOR_FEEDBACK="${PRIOR_FEEDBACK}
### Pass $pass_num ($pass_name) — $VERDICT
$(echo "$REVIEW_OUTPUT" | tail -20)"

    if [ "$VERDICT" = "APPROVE" ]; then
        echo -e "  ${GREEN}Pass $pass_num ($pass_name): APPROVE${NC}"
    elif [ "$VERDICT" = "REVISE" ]; then
        echo -e "  ${YELLOW}Pass $pass_num ($pass_name): REVISE${NC}"
    else
        echo -e "  ${RED}Pass $pass_num ($pass_name): REJECT${NC}"
    fi
    echo ""
done

# ---- Summary ----
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Review Summary${NC}"
echo -e "${BOLD}==========================================${NC}"
echo ""

HAS_REJECT=false
HAS_REVISE=false

for i in 0 1 2; do
    v="${VERDICTS[$i]}"
    name="${PASS_NAMES[$i]}"
    if [ "$v" = "REJECT" ]; then
        echo -e "  ${RED}$name: REJECT${NC}"
        HAS_REJECT=true
    elif [ "$v" = "REVISE" ]; then
        echo -e "  ${YELLOW}$name: REVISE${NC}"
        HAS_REVISE=true
    else
        echo -e "  ${GREEN}$name: APPROVE${NC}"
    fi
done

echo ""

if [ "$HAS_REJECT" = true ]; then
    echo -e "${RED}Plan REJECTED by one or more reviewers.${NC}"
    echo ""
    for i in 0 1 2; do
        if [ "${VERDICTS[$i]}" = "REJECT" ]; then
            echo -e "${RED}--- ${PASS_NAMES[$i]} rejection reasons ---${NC}"
            echo "${FEEDBACKS[$i]}" | grep -A 100 "REASONS:" | head -20
            echo ""
        fi
    done
    exit 1
elif [ "$HAS_REVISE" = true ]; then
    echo -e "${YELLOW}Plan has revision suggestions:${NC}"
    echo ""
    for i in 0 1 2; do
        if [ "${VERDICTS[$i]}" = "REVISE" ]; then
            echo -e "${YELLOW}--- ${PASS_NAMES[$i]} suggestions ---${NC}"
            echo "${FEEDBACKS[$i]}" | grep -A 100 "SUGGESTIONS:" | head -20
            echo ""
        fi
    done
    echo -n "Continue anyway? [y/N] "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        echo -e "${RED}Aborted.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Continuing despite revision suggestions.${NC}"
else
    echo -e "${GREEN}Plan approved by all 3 reviewers. Ready to dispatch.${NC}"
fi
