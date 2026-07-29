#!/bin/bash
set -euo pipefail

# Autoplan chaining — runs sequential review passes on a wave plan.
# Uses the plan-reviewer agent for strategy, design, and engineering review,
# plus a cross-vendor Grok CLI pass when the grok CLI is installed.
#
# Usage:
#   ./scripts/autoplan.sh <plan-file>
#
# Passes:
#   1. Strategy  — "Does this plan address the right problem?"
#   2. Design    — "Are wave dependencies and agent assignments correct?"
#   3. Engineering — "Are tasks scoped correctly? Any missing infrastructure?"
#   4. Cross-vendor — Grok plan critic (roles/plan-critic.md); skipped if grok CLI absent

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
    echo "Usage: autoplan.sh <plan-file> [--allow-revise]"
    echo ""
    echo "Fail-closed (Ground Truth):"
    echo "  CLI failure, unparseable verdict, REJECT, or REVISE → exit 1"
    echo "  Re-run after fixing the plan:  ./scripts/autoplan.sh <plan-file>"
    echo "  Optional: --allow-revise  (interactive continue on REVISE only; never on REJECT)"
    exit 1
fi

PLAN_FILE="$1"
shift
ALLOW_REVISE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-revise) ALLOW_REVISE=true; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

if [ ! -f "$PLAN_FILE" ]; then
    echo -e "${RED}ERROR: Plan file not found: $PLAN_FILE${NC}"
    exit 1
fi

RERUN_HINT="./scripts/autoplan.sh \"$PLAN_FILE\""

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

    # Run the CTO agent for plan review (plan-reviewer folded into CTO, lean-roster 2026-06)
    # Ground Truth: fail-closed — CLI failure is NOT treated as APPROVE.
    set +e
    REVIEW_OUTPUT=$(claude --agent "$REPO_DIR/providers/claude/agents/cto.md" --print "$FULL_PROMPT" 2>&1)
    REVIEW_EXIT=$?
    set -e

    echo "$REVIEW_OUTPUT"
    echo ""

    if [ "$REVIEW_EXIT" -ne 0 ]; then
        echo -e "  ${RED}Pass $pass_num ($pass_name): CLI failed (exit $REVIEW_EXIT) — fail-closed${NC}"
        echo -e "  ${CYAN}Re-run after fixing env/auth: $RERUN_HINT${NC}"
        VERDICT="REJECT"
        REVIEW_OUTPUT="VERDICT: REJECT
REASONS:
- CTO CLI exit $REVIEW_EXIT (not treated as APPROVE)
- Re-run: $RERUN_HINT
---
$REVIEW_OUTPUT"
    else
        VERDICT=$(echo "$REVIEW_OUTPUT" | grep -oE "VERDICT: (APPROVE|REVISE|REJECT)" | tail -1 | sed 's/VERDICT: //' || true)
        if [ -z "$VERDICT" ]; then
            echo -e "  ${RED}Pass $pass_num ($pass_name): no VERDICT line — fail-closed as REJECT${NC}"
            echo -e "  ${CYAN}Re-run after fixing the plan/reviewer: $RERUN_HINT${NC}"
            VERDICT="REJECT"
            REVIEW_OUTPUT="${REVIEW_OUTPUT}

VERDICT: REJECT
REASONS:
- Unparseable review output (missing VERDICT line)
- Re-run: $RERUN_HINT"
        fi
    fi

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

# ---- Pass 4: Cross-vendor plan critic (Grok) ----
# Different vendor by design: the three passes above share one vendor's blind
# spots. Runs via the Grok Build CLI (subscription login, no API key); skips
# cleanly when grok isn't installed/logged in, and warns-and-continues on error
# rather than blocking dispatch on a third-party outage.
GROK_CRITIC="$REPO_DIR/providers/grok/plan-critic.sh"
if [ -x "$GROK_CRITIC" ] && command -v grok >/dev/null 2>&1; then
    echo -e "${BOLD}------------------------------------------${NC}"
    echo -e "${BOLD}  Pass 4: Cross-vendor (Grok)${NC}"
    echo -e "${BOLD}------------------------------------------${NC}"
    echo ""

    set +e
    GROK_OUTPUT=$(PRIOR_FEEDBACK="$PRIOR_FEEDBACK" "$GROK_CRITIC" "$PLAN_FILE")
    GROK_EXIT=$?
    set -e

    if [ "$GROK_EXIT" -eq 0 ]; then
        echo "$GROK_OUTPUT"
        echo ""
        VERDICT=$(echo "$GROK_OUTPUT" | grep -oE "VERDICT: (APPROVE|REVISE|REJECT)" | tail -1 | sed 's/VERDICT: //' || true)
        if [ -z "$VERDICT" ]; then
            echo -e "  ${RED}Pass 4 (Cross-vendor): no VERDICT — fail-closed as REJECT${NC}"
            VERDICT="REJECT"
            GROK_OUTPUT="${GROK_OUTPUT}

VERDICT: REJECT
REASONS:
- Unparseable Grok review (missing VERDICT line)
- Re-run: $RERUN_HINT"
        fi
        PASS_NAMES+=("Cross-vendor")
        VERDICTS+=("$VERDICT")
        FEEDBACKS+=("$GROK_OUTPUT")
        if [ "$VERDICT" = "APPROVE" ]; then
            echo -e "  ${GREEN}Pass 4 (Cross-vendor): APPROVE${NC}"
        elif [ "$VERDICT" = "REVISE" ]; then
            echo -e "  ${YELLOW}Pass 4 (Cross-vendor): REVISE${NC}"
        else
            echo -e "  ${RED}Pass 4 (Cross-vendor): REJECT${NC}"
        fi
    else
        # Grok CLI error: skip Pass 4 (do not invent APPROVE); continue with passes 1–3
        echo -e "  ${YELLOW}Pass 4 (Cross-vendor): skipped after exit $GROK_EXIT (not treated as APPROVE)${NC}"
        echo -e "  ${CYAN}Optional re-run with grok healthy: $RERUN_HINT${NC}"
    fi
    echo ""
else
    echo -e "  ${CYAN}Pass 4 (Cross-vendor/Grok): skipped — grok CLI not installed (not a fail)${NC}"
    echo ""
fi

# ---- Summary ----
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Review Summary${NC}"
echo -e "${BOLD}==========================================${NC}"
echo ""

HAS_REJECT=false
HAS_REVISE=false

for i in "${!VERDICTS[@]}"; do
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
    echo -e "${RED}Plan REJECTED (fail-closed). Dispatch will not proceed.${NC}"
    echo -e "${CYAN}Fix the plan, then re-run: $RERUN_HINT${NC}"
    echo ""
    for i in "${!VERDICTS[@]}"; do
        if [ "${VERDICTS[$i]}" = "REJECT" ]; then
            echo -e "${RED}--- ${PASS_NAMES[$i]} rejection reasons ---${NC}"
            echo "${FEEDBACKS[$i]}" | grep -A 100 "REASONS:" | head -20
            echo ""
        fi
    done
    exit 1
elif [ "$HAS_REVISE" = true ]; then
    echo -e "${YELLOW}Plan has REVISE suggestions (fail-closed by default).${NC}"
    echo -e "${CYAN}Edit the plan, then re-run: $RERUN_HINT${NC}"
    echo -e "${CYAN}Or re-run with --allow-revise to continue after reading suggestions.${NC}"
    echo ""
    for i in "${!VERDICTS[@]}"; do
        if [ "${VERDICTS[$i]}" = "REVISE" ]; then
            echo -e "${YELLOW}--- ${PASS_NAMES[$i]} suggestions ---${NC}"
            echo "${FEEDBACKS[$i]}" | grep -A 100 "SUGGESTIONS:" | head -20
            echo ""
        fi
    done
    if [ "$ALLOW_REVISE" = true ]; then
        echo -n "Continue despite REVISE? [y/N] "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            echo -e "${RED}Aborted. Re-run when ready: $RERUN_HINT${NC}"
            exit 1
        fi
        echo -e "${GREEN}Continuing despite revision suggestions (--allow-revise).${NC}"
    else
        echo -e "${RED}Aborted (no silent continue). Re-run: $RERUN_HINT${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Plan approved by all ${#VERDICTS[@]} reviewers. Ready to dispatch.${NC}"
fi
