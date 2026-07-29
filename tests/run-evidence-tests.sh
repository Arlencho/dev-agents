#!/bin/bash
# Evidence scorecard smoke (uses real wave-plans data if present).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
pass=0; fail=0
check() {
  if [ "$2" -eq "$3" ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s (want %s got %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
got=$("$REPO_DIR/scripts/wave-report.sh" --no-write >/tmp/evidence-test.out 2>&1; echo $?)
check "wave-report exit 0" 0 "$got"
if grep -q "Fleet Evidence Scorecard" /tmp/evidence-test.out; then
  echo "  ok   header present"; pass=$((pass+1))
else
  echo "  FAIL header missing"; fail=$((fail+1))
fi
if grep -q "Per vendor" /tmp/evidence-test.out; then
  echo "  ok   vendor table present"; pass=$((pass+1))
else
  echo "  FAIL vendor table missing"; fail=$((fail+1))
fi
# write mode
rm -f "$REPO_DIR/logs/evidence.csv"
got=$("$REPO_DIR/scripts/wave-report.sh" >/tmp/evidence-test2.out 2>&1; echo $?)
check "wave-report write exit 0" 0 "$got"
if [ -f "$REPO_DIR/logs/evidence.csv" ]; then
  echo "  ok   evidence.csv written"; pass=$((pass+1))
else
  echo "  FAIL evidence.csv not written"; fail=$((fail+1))
fi
echo ""; echo "== $pass passed, $fail failed =="; [ "$fail" -eq 0 ]
