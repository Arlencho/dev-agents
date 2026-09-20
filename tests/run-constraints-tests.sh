#!/bin/bash
# Ground Truth: plan-wide rules are declared once in the plan header and reach
# every seat of that plan (#115).
#
# The gate block is EXTRACTED from scripts/dispatch.sh (between the
# constraints-header:begin and constraints-header:end markers) and sourced
# here, so this test cannot drift from the code it checks. No network, no
# vendor CLIs, no dispatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/dispatch.sh"

pass=0; fail=0
checkf() { # <name> <exit code: 0=pass>
    if [ "$2" -eq 0 ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$1"; fail=$((fail+1))
    fi
}
eq() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n       want=%s\n       got =%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

BLOCK=$(sed -n '/# ---- constraints-header:begin/,/# ---- constraints-header:end/p' "$DISPATCH")
if [ -z "$BLOCK" ]; then
    echo "  FAIL could not extract the constraints-header block from scripts/dispatch.sh"
    exit 1
fi
RED=''; NC=''
eval "$BLOCK"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

RULE_ONE="no long dash anywhere, no AI tool or vendor name"
RULE_TWO="no Co-Authored-By trailer"

cat > "$TMP/two-rules.plan" <<EOF
# A plan with two header rules. TIER: C
# CONSTRAINTS: $RULE_ONE
#   CONSTRAINTS:   $RULE_TWO
# TIER: C

1 | web-frontend | Do the first thing. VERIFY: the touched tests. | fix/one
2 | frontend-critic | Review the first thing. | fix/one
EOF

cat > "$TMP/no-rules.plan" <<'EOF'
# A plan with no constraints header. TIER: C
# TIER: C

1 | web-frontend | Do the thing. | fix/two
EOF

cat > "$TMP/repeated.plan" <<EOF
# A plan that declares a rule and also retypes it on the task line. TIER: C
# CONSTRAINTS: $RULE_ONE
# TIER: C

1 | web-frontend | Do the thing. HOUSE STYLE: $RULE_ONE. | fix/three
EOF

echo "== reading the header =="
got=$(plan_constraints "$TMP/two-rules.plan" | wc -l | xargs)
eq "two CONSTRAINTS lines are read, leading spaces and all" "2" "$got"
got=$(plan_constraints "$TMP/two-rules.plan" | sed -n 2p)
eq "a rule is trimmed of surrounding whitespace" "$RULE_TWO" "$got"
got=$(plan_constraints "$TMP/no-rules.plan" | wc -l | xargs)
eq "a plan without the header yields no rules" "0" "$got"
got=$(plan_constraints "$TMP/missing.plan" | wc -l | xargs)
eq "a plan file that does not exist yields no rules" "0" "$got"

echo ""
echo "== the block every seat receives =="
PREFIX=$(constraints_prefix "$TMP/two-rules.plan")
case "$PREFIX" in *"1) $RULE_ONE"*) r=0 ;; *) r=1 ;; esac
checkf "the prefix carries the first rule, numbered" $r
case "$PREFIX" in *"2) $RULE_TWO"*) r=0 ;; *) r=1 ;; esac
checkf "the prefix carries the second rule, numbered" $r
eq "a plan without the header produces no prefix" "" "$(constraints_prefix "$TMP/no-rules.plan")"

echo ""
echo "== both seats of the plan get the rules =="
PRODUCER="Do the first thing. VERIFY: the touched tests."
CRITIC="Review the first thing."
P_FULL="$PREFIX $PRODUCER"
C_FULL="$PREFIX $CRITIC"
constraints_delivered "$TMP/two-rules.plan" "$P_FULL" "$C_FULL" 2>/dev/null
checkf "producer and critic both carry every rule after injection" $?
count=$(printf '%s' "$P_FULL" | grep -o "$RULE_ONE" | wc -l | xargs)
eq "the rule appears exactly once in a seat task" "1" "$count"

echo ""
echo "== it fails closed, not open =="
constraints_delivered "$TMP/two-rules.plan" "$P_FULL" "$CRITIC" 2>/dev/null
checkf "a seat that did not receive the rules stops the dispatch" $([ $? -ne 0 ] && echo 0 || echo 1)
constraints_delivered "$TMP/no-rules.plan" "$PRODUCER" 2>/dev/null
checkf "a plan with no rules never stops a dispatch" $?

echo ""
echo "== say it once: the header, not the task line =="
constraints_dup_gate "$TMP/repeated.plan" "Do the thing. HOUSE STYLE: $RULE_ONE." 2>/dev/null
checkf "a task line repeating a header rule stops the dispatch" $([ $? -ne 0 ] && echo 0 || echo 1)
constraints_dup_gate "$TMP/two-rules.plan" "$PRODUCER" "$CRITIC" 2>/dev/null
checkf "task lines that do not repeat a rule pass the gate" $?
constraints_dup_gate "$TMP/no-rules.plan" "$PRODUCER" 2>/dev/null
checkf "a plan with no rules passes the gate" $?

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
