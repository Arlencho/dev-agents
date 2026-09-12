#!/bin/bash
# Ground Truth: the per-repo localhost dispatch lock in scripts/dispatch.sh.
# No network, no vendor CLIs, no agents dispatched.
#
# The lock block is EXTRACTED from dispatch.sh (between the dispatch-lock:begin
# and dispatch-lock:end markers) rather than restated here, so this test cannot
# drift from the code that actually serializes dispatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/dispatch.sh"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-56s → %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-56s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

check_true() { # <name> <command...>  — the command must succeed
    local name="$1"; shift
    if "$@"; then
        printf '  ok   %s\n' "$name"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$name"; fail=$((fail+1))
    fi
}

LOCK_BLOCK=$(sed -n '/# ---- dispatch-lock:begin/,/# ---- dispatch-lock:end/p' "$DISPATCH")
if [ -z "$LOCK_BLOCK" ]; then
    echo "  FAIL could not extract the dispatch-lock block from scripts/dispatch.sh"
    exit 1
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Harness: the extracted block plus the globals dispatch.sh sets before it.
HARNESS="$SANDBOX/lock-harness.sh"
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'RED= ; GREEN= ; YELLOW= ; NC='
    echo 'REPO_URL="${REPO_URL:-git@github.com:Arlencho/dev-agents.git}"'
    echo 'PLAN_SOURCE="${PLAN_SOURCE:-wave-plans/test.plan}"'
    echo 'LOGS_DIR="${LOGS_DIR:?LOGS_DIR required}"'
    echo 'NO_WAIT="${NO_WAIT:-false}"'
    echo 'WORKER_ARRAY=(${WORKER_ARRAY_SPEC:-"macbook-pro|localhost"})'
    printf '%s\n' "$LOCK_BLOCK"
    # eval, not exec: the extracted functions must stay in this shell's scope.
    echo 'eval "$@"'
} > "$HARNESS"
chmod +x "$HARNESS"

export DISPATCH_LOCK_POLL_S=1
LOCKS="$SANDBOX/logs/dispatch-locks"

echo "== lock file identifies the holder pid and plan =="
out=$(LOGS_DIR="$SANDBOX/logs" PLAN_SOURCE="wave-plans/alpha.plan" \
      "$HARNESS" 'dispatch_lock_acquire >/dev/null; sed -n "1p;2p" "$LOCK_FILE"' 2>/dev/null)
holder_pid_recorded=$(printf '%s\n' "$out" | sed -n '1p')
holder_plan=$(printf '%s\n' "$out" | sed -n '2p')
check_true "lock records a holder pid" test -n "$holder_pid_recorded"
check "lock records the plan it is running" "wave-plans/alpha.plan" "$holder_plan"
check_true "lock file is keyed by repo name" test -f "$LOCKS/dev-agents.lock"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== a second dispatch with --no-wait exits 9 and names the holder =="
# Hold the lock with a live process (sleep) whose pid is written into the file.
mkdir -p "$LOCKS"
sleep 30 &
holder=$!
printf '%s\nwave-plans/held.plan\n2026-09-12T00:00:00Z\n' "$holder" > "$LOCKS/dev-agents.lock"

busy=$(LOGS_DIR="$SANDBOX/logs" NO_WAIT=true "$HARNESS" dispatch_lock_acquire 2>&1)
busy_exit=$?
check "--no-wait exit code" "9" "$busy_exit"
printf '%s' "$busy" | grep -q "pid $holder" ; check "message names the holder pid" 0 "$?"
printf '%s' "$busy" | grep -q "wave-plans/held.plan" ; check "message names the holder plan" 0 "$?"

echo ""
echo "== without --no-wait it queues, then takes the lock when freed =="
( sleep 2; rm -f "$LOCKS/dev-agents.lock" ) &
freer=$!
start=$(date +%s)
LOGS_DIR="$SANDBOX/logs" "$HARNESS" dispatch_lock_acquire >/dev/null 2>&1
waited_exit=$?
waited=$(( $(date +%s) - start ))
wait "$freer" 2>/dev/null
check "acquires after the holder releases" "0" "$waited_exit"
check_true "actually waited for the holder" test "$waited" -ge 2
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== a lock left by a dead pid is cleared, not waited on =="
mkdir -p "$LOCKS"
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null
printf '%s\nwave-plans/crashed.plan\n2026-09-12T00:00:00Z\n' "$dead" > "$LOCKS/dev-agents.lock"
stale=$(LOGS_DIR="$SANDBOX/logs" NO_WAIT=true "$HARNESS" dispatch_lock_acquire 2>&1)
check "stale lock is taken over" "0" "$?"
printf '%s' "$stale" | grep -q "stale" ; check "stale takeover is announced" 0 "$?"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== release removes only our own lock =="
LOGS_DIR="$SANDBOX/logs" "$HARNESS" 'dispatch_lock_acquire; dispatch_lock_release; [ -f "$LOCK_FILE" ]' >/dev/null 2>&1
check "release removes the lock file" "1" "$?"
printf '999999\nwave-plans/other.plan\n2026-09-12T00:00:00Z\n' > "$LOCKS/dev-agents.lock"
LOGS_DIR="$SANDBOX/logs" "$HARNESS" 'LOCK_HELD=true; dispatch_lock_release' >/dev/null 2>&1
check_true "another pid's lock is left alone" test -f "$LOCKS/dev-agents.lock"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== remote-only fleets take no lock =="
WORKER_ARRAY_SPEC="mac-mini-1|192.168.1.50" LOGS_DIR="$SANDBOX/logs" \
    "$HARNESS" dispatch_lock_uses_localhost >/dev/null 2>&1
check "no localhost worker → lock skipped" "1" "$?"
WORKER_ARRAY_SPEC="macbook-pro|127.0.0.1" LOGS_DIR="$SANDBOX/logs" \
    "$HARNESS" dispatch_lock_uses_localhost >/dev/null 2>&1
check "127.0.0.1 counts as localhost" "0" "$?"

echo ""
echo "== --no-wait is documented in the usage text =="
help_text=$("$DISPATCH" --help 2>&1 || true)
printf '%s' "$help_text" | grep -q -- "--no-wait"
check "dispatch.sh --help lists --no-wait" "0" "$?"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
