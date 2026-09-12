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

check_true() { # <name> <command...>  the command must succeed
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

# The lock path now defaults to the per-user fleet base under $HOME, so point
# HOME at the sandbox: a test that forgets to set FLEET_HOME must not be able to
# touch the operator's real ~/dev.
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# Harness: the extracted block plus the globals dispatch.sh sets before it.
HARNESS="$SANDBOX/lock-harness.sh"
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'RED= ; GREEN= ; YELLOW= ; NC='
    echo 'REPO_URL="${REPO_URL:-git@github.com:Arlencho/dev-agents.git}"'
    echo 'PLAN_SOURCE="${PLAN_SOURCE:-wave-plans/test.plan}"'
    echo 'NO_WAIT="${NO_WAIT:-false}"'
    echo 'WORKER_ARRAY=(${WORKER_ARRAY_SPEC:-"macbook-pro|localhost"})'
    printf '%s\n' "$LOCK_BLOCK"
    # eval, not exec: the extracted functions must stay in this shell's scope.
    echo 'eval "$@"'
} > "$HARNESS"
chmod +x "$HARNESS"

export DISPATCH_LOCK_POLL_S=1
LOCKS="$SANDBOX/fleet-home/dispatch-locks"

echo "== lock file identifies the holder pid and plan =="
out=$(FLEET_HOME="$SANDBOX/fleet-home" PLAN_SOURCE="wave-plans/alpha.plan" \
      "$HARNESS" 'dispatch_lock_acquire >/dev/null; sed -n "1p;2p" "$LOCK_FILE"' 2>/dev/null)
holder_pid_recorded=$(printf '%s\n' "$out" | sed -n '1p')
holder_plan=$(printf '%s\n' "$out" | sed -n '2p')
check_true "lock records a holder pid" test -n "$holder_pid_recorded"
check "lock records the plan it is running" "wave-plans/alpha.plan" "$holder_plan"
check_true "lock file is keyed by repo name" test -f "$LOCKS/dev-agents.lock"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== the lock path is machine-global, not per clone =="
# With no FLEET_HOME the lock must land under the per-user fleet base, the same
# base as ~/dev/agent-logs and the ~/dev/<repo> checkout it protects. A path
# inside this clone would give every clone on the host a private lock.
default_lock=$(env -u FLEET_HOME "$HARNESS" 'echo "$LOCK_FILE"' 2>/dev/null)
check "default lock path follows the per-user fleet base" \
      "$HOME/dev/dispatch-locks/dev-agents.lock" "$default_lock"
printf '%s' "$default_lock" | grep -q "^$REPO_DIR/"
check "default lock path is outside the fleet checkout" "1" "$?"

echo ""
echo "== a second dispatch with --no-wait exits 9 and names the holder =="
# Hold the lock with a live process (sleep) whose pid is written into the file.
mkdir -p "$LOCKS"
sleep 30 &
holder=$!
printf '%s\nwave-plans/held.plan\n2026-09-12T00:00:00Z\n' "$holder" > "$LOCKS/dev-agents.lock"

busy=$(FLEET_HOME="$SANDBOX/fleet-home" NO_WAIT=true "$HARNESS" dispatch_lock_acquire 2>&1)
busy_exit=$?
check "--no-wait exit code" "9" "$busy_exit"
printf '%s' "$busy" | grep -q "pid $holder" ; check "message names the holder pid" 0 "$?"
printf '%s' "$busy" | grep -q "wave-plans/held.plan" ; check "message names the holder plan" 0 "$?"

echo ""
echo "== without --no-wait it queues, then takes the lock when freed =="
( sleep 2; rm -f "$LOCKS/dev-agents.lock" ) &
freer=$!
start=$(date +%s)
FLEET_HOME="$SANDBOX/fleet-home" "$HARNESS" dispatch_lock_acquire >/dev/null 2>&1
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
stale=$(FLEET_HOME="$SANDBOX/fleet-home" NO_WAIT=true "$HARNESS" dispatch_lock_acquire 2>&1)
check "stale lock is taken over" "0" "$?"
printf '%s' "$stale" | grep -q "stale" ; check "stale takeover is announced" 0 "$?"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== release removes only our own lock =="
FLEET_HOME="$SANDBOX/fleet-home" "$HARNESS" 'dispatch_lock_acquire; dispatch_lock_release; [ -f "$LOCK_FILE" ]' >/dev/null 2>&1
check "release removes the lock file" "1" "$?"
printf '999999\nwave-plans/other.plan\n2026-09-12T00:00:00Z\n' > "$LOCKS/dev-agents.lock"
FLEET_HOME="$SANDBOX/fleet-home" "$HARNESS" 'LOCK_HELD=true; dispatch_lock_release' >/dev/null 2>&1
check_true "another pid's lock is left alone" test -f "$LOCKS/dev-agents.lock"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== signals release the lock while a wave is blocked =="
# Shape under test: a dispatch that holds the lock and is blocked the way a live
# wave blocks (waiting on seats, or sitting in the retry backoff). The holders
# reuse the extracted block verbatim, so the traps, the wait helper and the
# sleep helper are the ones dispatch.sh actually runs.

new_holder() { # <file>  harness preamble + take the lock + arm the real traps
    sed '/^eval "\$@"$/d' "$HARNESS" > "$1"
    cat >> "$1" <<'PROLOGUE'
fleet_close_dispatch() { :; }   # stand-in for the event ledger the traps close
dispatch_lock_acquire
dispatch_lock_arm_traps
PROLOGUE
}

WAVE_HOLDER="$SANDBOX/holder-wave.sh"
new_holder "$WAVE_HOLDER"
cat >> "$WAVE_HOLDER" <<'HOLDER'
# A seat that ignores INT and TERM, so the wave cannot end by itself: the lock
# can only disappear because a trap ran.
perl -e '$SIG{INT} = "IGNORE"; $SIG{TERM} = "IGNORE"; sleep 120' &
: > "$READY_FILE"
dispatch_wait_interruptible "$!"
HOLDER

BACKOFF_HOLDER="$SANDBOX/holder-backoff.sh"
new_holder "$BACKOFF_HOLDER"
cat >> "$BACKOFF_HOLDER" <<'HOLDER'
# The retry backoff shape: a fixed delay with no seat to watch. One blocking
# sleep here would hold a pending trap for the whole delay.
: > "$READY_FILE"
dispatch_sleep_interruptible 30
HOLDER

# Runs a holder and signals it once it is blocked.
# Echoes "<exit code> <present|removed> <seconds until it exited>".
signal_holder() { # <holder script> <signal> <group|direct>
    local script="$1" sig="$2" scope="$3"
    local ready="$SANDBOX/ready.$sig.$scope"
    local target rc waited=0 start
    rm -f "$ready" "$LOCKS/dev-agents.lock"

    # perl gives the holder a process group of its own (as leader, so pgid = pid)
    # and restores the default INT/TERM disposition before exec: a shell that
    # starts with a signal already ignored cannot trap it at all, and this has to
    # measure dispatch.sh rather than the way the suite spawned it.
    READY_FILE="$ready" FLEET_HOME="$SANDBOX/fleet-home" \
        perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; setpgrp(0, 0); exec @ARGV or die $!' \
             -- "${BASH:-/bin/bash}" "$script" >"$SANDBOX/holder.$sig.$scope.log" 2>&1 &
    local holder=$!

    while [ ! -f "$ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    if [ ! -f "$ready" ]; then
        kill -KILL -"$holder" 2>/dev/null
        wait "$holder" 2>/dev/null
        echo "no-start absent 0"
        return
    fi

    # group: what a TTY Ctrl-C sends. direct: what a wrapper or a supervisor sends.
    [ "$scope" = group ] && target="-$holder" || target="$holder"
    start=$(date +%s)
    kill -"$sig" "$target" 2>/dev/null

    waited=0
    while kill -0 "$holder" 2>/dev/null && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    if kill -0 "$holder" 2>/dev/null; then
        kill -KILL -"$holder" 2>/dev/null
        wait "$holder" 2>/dev/null
        echo "timeout $([ -f "$LOCKS/dev-agents.lock" ] && echo present || echo removed) 10"
        return
    fi

    wait "$holder"; rc=$?
    kill -KILL -"$holder" 2>/dev/null   # sweep any seat the trap left behind
    echo "$rc $([ -f "$LOCKS/dev-agents.lock" ] && echo present || echo removed) $(( $(date +%s) - start ))"
}

if command -v perl >/dev/null 2>&1; then
    read -r int_rc int_lock _ <<< "$(signal_holder "$WAVE_HOLDER" INT group)"
    check "process-group SIGINT during a wave frees the lock" "removed" "$int_lock"
    check "interrupted run exits 130" "130" "$int_rc"

    read -r term_rc term_lock _ <<< "$(signal_holder "$WAVE_HOLDER" TERM group)"
    check "process-group SIGTERM during a wave frees the lock" "removed" "$term_lock"
    check "terminated run exits 143" "143" "$term_rc"

    # A blocking sleep would park the trap for the full 30s delay.
    read -r delay_rc delay_lock delay_s <<< "$(signal_holder "$BACKOFF_HOLDER" INT direct)"
    check "SIGINT during the retry backoff frees the lock" "removed" "$delay_lock"
    check "backoff does not defer the trap" "130" "$delay_rc"
    check_true "lock freed within 5s, not after the 30s delay" test "$delay_s" -le 5
    rm -f "$LOCKS/dev-agents.lock"
else
    echo "  skip perl is not available: cannot isolate a process group for the signal tests"
fi

echo ""
echo "== the close-out trap keeps the exit code it was entered with =="
# The EXIT trap runs last on every path, including after the INT / TERM traps
# call exit 130 / 143 (asserted above). It must not report the status of its own
# close-out work in place of the run's.
FLEET_HOME="$SANDBOX/fleet-home" "$HARNESS" \
    'fleet_close_dispatch() { :; }; dispatch_lock_acquire >/dev/null; dispatch_lock_arm_traps; exit 7' \
    >/dev/null 2>&1
check "a failed run keeps its own exit code" "7" "$?"
check_true "and the lock is still released" test ! -f "$LOCKS/dev-agents.lock"
rm -f "$LOCKS/dev-agents.lock"

echo ""
echo "== remote-only fleets take no lock =="
WORKER_ARRAY_SPEC="mac-mini-1|192.168.1.50" FLEET_HOME="$SANDBOX/fleet-home" \
    "$HARNESS" dispatch_lock_uses_localhost >/dev/null 2>&1
check "no localhost worker → lock skipped" "1" "$?"
WORKER_ARRAY_SPEC="macbook-pro|127.0.0.1" FLEET_HOME="$SANDBOX/fleet-home" \
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
