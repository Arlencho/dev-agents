#!/bin/bash
# Ground Truth: autoplan fail-closed usage / flags (no live Claude/Grok calls).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTOPLAN="$REPO_DIR/scripts/autoplan.sh"

pass=0; fail=0
check() {
    if [ "$2" -eq "$3" ]; then
        printf '  ok   %-52s (exit %s)\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-52s (want %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

echo "== autoplan fail-closed shell checks =="
# Missing plan file
got=$("$AUTOPLAN" /tmp/does-not-exist-plan-xyz.plan >/dev/null 2>&1; echo $?)
check "missing plan → exit 1" 1 "$got"

# Unknown flag
got=$("$AUTOPLAN" "$REPO_DIR/README.md" --not-a-flag >/dev/null 2>&1; echo $?)
check "unknown flag → exit 1" 1 "$got"

# Usage with no args
got=$("$AUTOPLAN" >/dev/null 2>&1; echo $?)
check "no args → exit 1" 1 "$got"

# Script contains fail-closed markers (regression guards)
if grep -q 'fail-closed' "$AUTOPLAN" && grep -q 'not treated as APPROVE' "$AUTOPLAN"; then
    echo "  ok   fail-closed markers present in autoplan.sh"; pass=$((pass+1))
else
    echo "  FAIL fail-closed markers missing from autoplan.sh"; fail=$((fail+1))
fi

if grep -q 'VERDICT: APPROVE")' "$AUTOPLAN" && grep -q 'echo "VERDICT: APPROVE"' "$AUTOPLAN"; then
    # old fail-open pattern: || echo "VERDICT: APPROVE"
    if grep -qE '\|\|\s*echo "VERDICT: APPROVE"' "$AUTOPLAN"; then
        echo "  FAIL autoplan still has || echo VERDICT APPROVE fail-open"; fail=$((fail+1))
    else
        echo "  ok   no || echo VERDICT APPROVE fail-open"; pass=$((pass+1))
    fi
else
    if grep -qE '\|\|\s*echo "VERDICT: APPROVE"' "$AUTOPLAN"; then
        echo "  FAIL autoplan still has || echo VERDICT APPROVE fail-open"; fail=$((fail+1))
    else
        echo "  ok   no || echo VERDICT APPROVE fail-open"; pass=$((pass+1))
    fi
fi

if grep -q 'ALLOW_REVISE' "$AUTOPLAN" && grep -q -- '--allow-revise' "$AUTOPLAN"; then
    echo "  ok   --allow-revise opt-in present"; pass=$((pass+1))
else
    echo "  FAIL --allow-revise missing"; fail=$((fail+1))
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
