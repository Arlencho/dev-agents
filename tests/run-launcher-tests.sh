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
# noauth note: kimi's shim says "HTTP 401 unauthorized", and a fast 401 is a
# provider-limit signature since issue #84 (exit 78, hold + probe). claude's
# and grok's noauth text carries no 401, so they stay 69.
for vendor in claude kimi grok; do
    noauth_want=69
    [ "$vendor" = "kimi" ] && noauth_want=78
    for pair in "success 0" "fail 1" "ratecap 75" "noauth $noauth_want"; do
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

echo "== row 13b: a cap or auth phrase in the prompt never classifies the run =="
# The shims echo their prompt. A learning or a task that quotes an earlier
# failure must not turn a seat that did its work into a cap or auth exit.
QUOTED_PROMPT="## Relevant Learnings
- [2026-09-12] [medium] [failure] devops: Not logged in. Please run /login
- HTTP 401 unauthorized: please run 'kimi login'
- Not authenticated. Run 'grok login' first.
- You've reached your usage limit. Limit resets at 5pm.
- HTTP 429 Too Many Requests, quota exceeded
YOUR TASK: do the thing"
for vendor in claude kimi grok; do
    noauth_want=69
    [ "$vendor" = "kimi" ] && noauth_want=78
    got=$(SHIM_MODE=success run_launcher "$vendor" web-frontend "$QUOTED_PROMPT")
    check "$vendor / quoted phrases in prompt, success" 0 "$got"
    got=$(SHIM_MODE=noauth run_launcher "$vendor" web-frontend "$QUOTED_PROMPT")
    check "$vendor / quoted phrases in prompt, real noauth" "$noauth_want" "$got"
    got=$(SHIM_MODE=ratecap run_launcher "$vendor" web-frontend "$QUOTED_PROMPT")
    check "$vendor / quoted phrases in prompt, real ratecap" 75 "$got"
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

echo "== row 15: a role with no charter runs without one instead of crashing =="
# The catch-all seat used to reach the vendor launchers with no roles/<role>.md
# behind it; the half-built charter path was executed as a command
# ("=/…/roles/claude.md: No such file or directory", exit 127 mid-launcher).
EMPTY_ROLES=$(mktemp -d)
for vendor in kimi grok; do
    got=$(SHIM_MODE=success ROLES_DIR="$EMPTY_ROLES" run_launcher "$vendor" claude "do the thing")
    check "$vendor / charterless role" 0 "$got"
done
NOCHARTER_ERR=$(SHIM_MODE=success ROLES_DIR="$EMPTY_ROLES" PATH="$SHIMS:$PATH" \
    "$REPO_DIR/providers/kimi/launch.sh" claude "do the thing" 2>&1 >/dev/null)
if echo "$NOCHARTER_ERR" | grep -q "no charter for role 'claude'" \
   && ! echo "$NOCHARTER_ERR" | grep -q "No such file or directory"; then
    echo "  ok   charterless role warns instead of running a bogus command"; pass=$((pass+1))
else
    echo "  FAIL charterless role did not warn cleanly: $NOCHARTER_ERR"; fail=$((fail+1))
fi
rmdir "$EMPTY_ROLES"

echo "== row 16: the catch-all seat has a charter of its own =="
if [ -f "$REPO_DIR/roles/claude.md" ]; then
    echo "  ok   roles/claude.md exists"; pass=$((pass+1))
else
    echo "  FAIL roles/claude.md missing"; fail=$((fail+1))
fi
ARGV_LOG2="$(mktemp)"
SHIM_MODE=success SHIM_ARGV_LOG="$ARGV_LOG2" PATH="$SHIMS:$PATH" \
    ROLES_DIR="$REPO_DIR/roles" "$REPO_DIR/providers/kimi/launch.sh" claude "sweep the queue" >/dev/null 2>&1
if tr '\0' '\n' < "$ARGV_LOG2" | grep -qF "Your Role Charter"; then
    echo "  ok   catch-all charter reaches the prompt"; pass=$((pass+1))
else
    echo "  FAIL catch-all charter missing from prompt argv"; fail=$((fail+1))
fi
rm -f "$ARGV_LOG2"

echo "== row 17: plan-critic.sh skips (exit 3) when grok CLI absent =="
got=$(PATH="/usr/bin:/bin" "$REPO_DIR/providers/grok/plan-critic.sh" "$REPO_DIR/README.md" >/dev/null 2>&1; echo $?)
check "plan-critic / no-grok" 3 "$got"

echo "== row 18: the live-stream reader changes no exit classification =="
# The reader is a pass-through filter between the CLI and the log tee. The
# vendor CLI must stay PIPESTATUS[0], so every row above must hold with the
# reader in the pipeline too.
for pair in "success 0" "fail 1" "ratecap 75" "noauth 69"; do
    mode="${pair% *}"; want="${pair#* }"
    got=$(SHIM_MODE="$mode" AGENT_STREAM_READER="$REPO_DIR/scripts/seat-progress.py" \
        run_launcher claude web-frontend "do the thing")
    check "claude / $mode + stream reader" "$want" "$got"
done

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
