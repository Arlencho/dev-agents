#!/bin/bash
# Launcher contract tests — no real vendor CLIs, no network.
# Puts tests/shims on PATH so `claude`/`kimi`/`grok` resolve to fakes whose
# behavior is driven by SHIM_MODE (success|fail|ratecap|noauth).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIMS="$SCRIPT_DIR/shims"
export RATECAP_PATTERNS="$REPO_DIR/config/ratecap-patterns.conf"

pass=0; fail=0
check() { # <name> <expected-exit> <actual-exit>
    if [ "$2" -eq "$3" ]; then
        printf '  ok   %-52s (exit %s)\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-52s (want %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

run_launcher() { # <vendor> <role> <task>  — shims on PATH
    local vendor="$1" role="$2" task="$3"
    PATH="$SHIMS:$PATH" "$REPO_DIR/providers/$vendor/launch.sh" "$role" "$task" >/dev/null 2>&1
    echo $?
}

echo "== rows 1-12: each launcher × {success, fail, ratecap, noauth} =="
for vendor in claude kimi grok; do
    for pair in "success 0" "fail 1" "ratecap 75" "noauth 69"; do
        mode="${pair% *}"; want="${pair#* }"
        got=$(SHIM_MODE="$mode" run_launcher "$vendor" web-frontend "do the thing")
        check "$vendor / $mode" "$want" "$got"
    done
done

echo "== row 13: binary absent from PATH -> 69 =="
for vendor in claude kimi grok; do
    # Minimal PATH with coreutils but no vendor CLI (shims dir excluded)
    got=$(PATH="/usr/bin:/bin" "$REPO_DIR/providers/$vendor/launch.sh" web-frontend "t" >/dev/null 2>&1; echo $?)
    check "$vendor / binary-absent" 69 "$got"
done

echo "== row 14: kimi injects the role charter into the prompt =="
ARGV_LOG="$(mktemp)"
SHIM_MODE=success SHIM_ARGV_LOG="$ARGV_LOG" PATH="$SHIMS:$PATH" \
    "$REPO_DIR/providers/kimi/launch.sh" web-frontend "build the checkout page" >/dev/null 2>&1
# roles/web-frontend.md has a distinctive charter line; assert it reached argv.
charter_marker=$(sed -n '2p' "$REPO_DIR/roles/web-frontend.md" | head -c 40)
if [ -n "$charter_marker" ] && tr '\0' '\n' < "$ARGV_LOG" | grep -qF "Your Role Charter" \
   && tr '\0' '\n' < "$ARGV_LOG" | grep -qF "build the checkout page"; then
    echo "  ok   kimi charter+task present in prompt argv"; pass=$((pass+1))
else
    echo "  FAIL kimi charter injection missing from argv"; fail=$((fail+1))
fi
rm -f "$ARGV_LOG"

echo "== row 15: plan-critic.sh skips (exit 3) when grok CLI absent =="
got=$(PATH="/usr/bin:/bin" "$REPO_DIR/providers/grok/plan-critic.sh" "$REPO_DIR/README.md" >/dev/null 2>&1; echo $?)
check "plan-critic / no-grok" 3 "$got"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
