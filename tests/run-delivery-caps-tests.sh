#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export RATECAP_PATTERNS="$ROOT/config/ratecap-patterns.conf"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() {
    local name="$1" want="$2"; shift 2
    ( "$@" ) > "$TMP/output" 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "ok: $name"; pass=$((pass + 1))
    else
        echo "FAIL: $name (want $want, got $got)"; cat "$TMP/output"; fail=$((fail + 1))
    fi
}
classify() {
    source "$ROOT/providers/lib.sh"
    SEAT_QUIET_AFTER_S="${WATCHDOG:-0}" run_and_classify "$1" bash -c "$2"
}
for v in claude kimi grok codex; do
    for phrase in 'HTTP 402' 'usage balance exhausted' 'Payment Required'; do
        check "$v exhausted credit: $phrase" 76 classify "$v" "echo '$phrase' >&2; exit 1"
    done
    check "$v model discusses rate limits" 0 classify "$v" 'echo "Tests cover HTTP 429 and unauthorized requests"'
    check "$v failed tests mention authentication" 1 classify "$v" 'echo "FAIL: HTTP 429 unauthorized case"; exit 1'
    check "$v model quotes an error line" 0 classify "$v" 'echo "ERROR: HTTP 429 unauthorized"'
    check "$v actual rate error" 75 classify "$v" 'echo "Error: HTTP 429 Too Many Requests" >&2; exit 1'
done
check 'watchdog preserves vendor stderr' 76 env WATCHDOG=10 bash -c 'source "$1/providers/lib.sh"; SEAT_QUIET_AFTER_S=10 run_and_classify kimi bash -c '\''echo "HTTP 402 Payment Required" >&2; exit 1'\''' _ "$ROOT"
check 'multiline CLI payment error' 76 classify grok 'printf '\''Error: Internal error: {\n  "message": "API error (status 402 Payment Required): usage balance exhausted",\n  "http_status": 402\n}\n'\'' >&2; exit 1'
check 'structured assistant text is not a CLI error' 0 classify kimi 'echo '\''{"type":"assistant","message":{"content":[{"text":"HTTP 429 unauthorized"}]}}'\'''
check 'structured API failure is a CLI error' 75 classify kimi 'echo '\''{"type":"result","is_error":true,"result":"HTTP 429 Too Many Requests"}'\'''
check 'structured model message may quote CLI errors' 0 classify codex 'echo '\''{"type":"item.completed","item":{"type":"agent_message","text":"ERROR: HTTP 429 unauthorized"}}'\'''
check 'structured failed turn reports credit exhaustion' 76 classify codex 'echo '\''{"type":"turn.failed","error":{"message":"402 Payment Required"}}'\'''
check 'structured tool execution uses the tool ceiling' 0 env SEAT_QUIET_AFTER_S=0.3 SEAT_QUIET_POLL_S=0.2 SEAT_TOOL_CEILING_S=5 SEAT_QUIET_KILL_GRACE_S=0.1 python3 "$ROOT/scripts/seat-watchdog.py" -- bash -c 'printf "%s\n" '\''{"type":"item.started","item":{"id":"cmd_1","type":"command_execution"}}'\''; sleep 1; printf "%s\n" '\''{"type":"item.completed","item":{"id":"cmd_1","type":"command_execution"}}'\'''
source "$ROOT/providers/lib.sh"
git init -q -b main "$TMP/repo"
cd "$TMP/repo" || exit 1
git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m base
base=$(git rev-parse HEAD)
check 'exit zero without a new commit is no-delivery' 79 verify_delivery "$base" main 'implement the fix'
git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m delivery
check 'new branch commit delivers' 0 verify_delivery "$base" main 'implement the fix'
check 'retry cannot reuse an old commit' 79 verify_delivery "$(git rev-parse HEAD)" main 'implement the fix'
mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
[ "${GH_FAIL:-0}" = 0 ] || { echo "network unavailable" >&2; exit 1; }
printf '%s\n' "${PR_RESULT:-[]}"
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
check 'requested PR must exist' 79 verify_delivery "$base" main 'Open a pull request'
check 'requested PR plus commit delivers' 0 env PR_RESULT='[{"number":12}]' bash -c 'source "$1/providers/lib.sh"; verify_delivery "$2" main "Open a PR"' _ "$ROOT" "$base"
for task in 'do not open a PR' "don't create a pull request" 'never submit a PR' 'conflicts with PR 125' 'review a PR' 'Do not open a new PR'; do
    check "PR reference does not require delivery: $task" 0 verify_delivery "$base" main "$task"
done
check 'positive request after a negation still requires a PR' 79 verify_delivery "$base" main 'Do not open a PR here; create a PR for the fix'
check 'failed GitHub lookup preserves real commits' 0 env GH_FAIL=1 bash -c 'source "$1/providers/lib.sh"; verify_delivery "$2" main "Open a PR"' _ "$ROOT" "$base"
check 'terminal delivery statuses appear blocked' 0 python3 - "$ROOT" <<'PYTEST'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import desk_live, experience_build
for status in ("no-delivery", "out-of-credit"):
    projection = desk_live.project([
        {"event": "seat_dispatch", "task_id": "0", "agent": "devops"},
        {"event": "seat_exit", "task_id": "0", "status": status},
    ])
    assert projection["seats"][0]["pipeline"] == "blocked"
    assert 'st-fail' in experience_build.Renderer._seat_pill({"status": status})
    assert experience_build.Renderer.status_kind(status) == "fail"
PYTEST
# Exercise real routing and read-only health commands with isolated state.
REPO_DIR="$TMP/fleet"
mkdir -p "$REPO_DIR/logs/provider-state" "$TMP/waves"
ROUTING_CONFIG="$ROOT/config/routing.yaml"
CONFIG="$ROOT/config/workers.yaml"
source "$ROOT/scripts/config-lib.sh"
eval "$(sed -n '/^get_cooldown_minutes() {/,/^}/p;/^provider_cooling() {/,/^}/p;/^resolve_provider() {/,/^}/p' "$ROOT/scripts/dispatch.sh")"
export PROVIDER_STATE_DIR="$REPO_DIR/logs/provider-state"
for v in claude kimi grok codex; do
    echo $(( $(date +%s) + 86400 )) > "$PROVIDER_STATE_DIR/$v.credit-until"
done
check 'routing stops when every provider is out of credit' 1 resolve_provider devops
check 'preflight reports exhausted credit' 1 bash "$ROOT/scripts/vendor-auth-check.sh" --vendors kimi --json
grep -q '"status":"out-of-credit"' "$TMP/output" || fail=$((fail + 1))
echo '0 1 devops kimi default feat/test local 1s no-delivery test.log' > "$TMP/waves/seat.log"
check 'scorecard exposes credit and missing delivery' 0 env WAVE_PLANS_DIR="$TMP/waves" bash "$ROOT/scripts/provider-scorecard.sh"
grep -q 'out of credit.*kimi' "$TMP/output" || fail=$((fail + 1))
grep -q 'no-delivery=1' "$TMP/output" || fail=$((fail + 1))
# A credit cooldown remains active after the normal one-hour window.
echo $(( $(date +%s) - 7200 )) > "$PROVIDER_STATE_DIR/kimi.cooldown"
check 'paid credit stays blocked past a rate-cap window' 0 provider_cooling kimi
rm "$PROVIDER_STATE_DIR/grok.credit-until"
funded=$(resolve_provider web-frontend)
check 'routing chooses a funded fallback' 0 test "$funded" = grok
: > "$PROVIDER_STATE_DIR/grok.credit-until"
check 'empty credit file permits funded fallback' 0 test "$(resolve_provider web-frontend)" = grok
check 'empty credit file is not cooling' 1 provider_cooling grok
check 'scorecard accepts empty credit files' 0 env WAVE_PLANS_DIR="$TMP/waves" bash "$ROOT/scripts/provider-scorecard.sh"
cp "$TMP/output" "$TMP/scorecard-output"
check 'empty credit file emits no numeric errors' 1 grep -q 'integer expression expected' "$TMP/scorecard-output"
# Exhaust the untried chain to exercise the primary fallback credit read.
: > "$PROVIDER_STATE_DIR/codex.credit-until"
check 'empty primary credit file permits legacy rate fallback' 0 test "$(resolve_provider web-frontend 'codex kimi grok claude')" = codex
printf '#!/bin/sh\necho "Logged in using subscription"\nexit "${AUTH_EXIT:-0}"\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
for auth_exit in 0 1; do
    check "preflight preserves auth result with empty credit file: $auth_exit" "$auth_exit" env AUTH_EXIT="$auth_exit" bash "$ROOT/scripts/vendor-auth-check.sh" --vendors codex --json
    cp "$TMP/output" "$TMP/preflight-output"
    check "preflight empty credit file emits no numeric errors: $auth_exit" 1 grep -qE 'integer (expression )?expected' "$TMP/preflight-output"
done
# A fresh CLI probe must persist the same long cooldown and expose the reason.
rm "$PROVIDER_STATE_DIR/codex.credit-until"
printf '#!/bin/sh\necho "Error: HTTP 402 Payment Required" >&2\nexit 1\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
check 'fresh preflight credit error is not an auth failure' 1 env OUT_OF_CREDIT_COOLDOWN_MINUTES=180 bash "$ROOT/scripts/vendor-auth-check.sh" --vendors codex --json
grep -q '"status":"out-of-credit"' "$TMP/output" || fail=$((fail + 1))
check 'preflight persists configurable long cooldown' 0 test "$(cat "$PROVIDER_STATE_DIR/codex.credit-until")" -gt "$(( $(date +%s) + 10700 ))"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
