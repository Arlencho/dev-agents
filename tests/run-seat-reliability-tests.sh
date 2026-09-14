#!/bin/bash
# Ground Truth: seat reliability (issues #92 and #84). No network, no real
# vendor CLIs: tests/shims drive the seats.
#   #92  a seat with no model event for the quiet period is stopped with exit
#        124 by the watchdog, retried once by dispatch.sh, and a stop row
#        names the seat and the quiet period; thinking-token ticks and
#        wait-ticker lines never count as model events
#   #84  the fast spend/session-limit exit (the real 2026-09-13 log) is exit
#        78: dispatch.sh holds the seat instead of failing it, does not burn
#        the retry, writes a stop row with the provider and the reset time,
#        and starts no seat on that provider and model until a probe passes
# Fixtures are copied from the real logs named in the issues:
#   tests/fixtures/claude-spend-limit-20260913.jsonl       (issue #84)
#   tests/fixtures/claude-thinking-heartbeats-20260914.jsonl (issue #92)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIMS="$SCRIPT_DIR/shims"
export RATECAP_PATTERNS="$REPO_DIR/config/ratecap-patterns.conf"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-58s → %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-58s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}
check_true() { # <name> <command...>
    local name="$1"; shift
    if "$@"; then printf '  ok   %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL %s\n' "$name"; fail=$((fail+1)); fi
}

# ---------------------------------------------------------------- launcher --
run_launcher() { # <vendor> <mode> [VAR=val ...] -> prints the launcher exit
    local vendor="$1" mode="$2"; shift 2
    env SHIM_MODE="$mode" "$@" PATH="$SHIMS:$PATH" \
        "$REPO_DIR/providers/$vendor/launch.sh" web-frontend "do the thing" >/dev/null 2>&1
    echo $?
}
# Fast watchdog for this part: quiet after 2s, checked every second.
WDOG=(SEAT_QUIET_AFTER_S=2 SEAT_QUIET_POLL_S=1 SEAT_QUIET_KILL_GRACE_S=1)

echo "== issue 92: the watchdog stops a quiet seat, never a working one =="
got=$(run_launcher claude quiet "${WDOG[@]}" SHIM_QUIET_SLEEP=30)
check "quiet seat (one assistant line, then silence)" "124" "$got"
err=$(env SHIM_MODE=quiet "${WDOG[@]}" SHIM_QUIET_SLEEP=30 PATH="$SHIMS:$PATH" \
    "$REPO_DIR/providers/claude/launch.sh" web-frontend "do the thing" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q "no model event for 2s"
check "the stop is announced with the quiet period" "0" "$?"
got=$(run_launcher claude heartbeat "${WDOG[@]}")
check "a heartbeat-only seat counts as quiet" "124" "$got"
got=$(run_launcher claude chatty "${WDOG[@]}" SHIM_CHATTY_LINES=12 SHIM_CHATTY_SLEEP=0.5)
check "a seat emitting model events is never stopped" "0" "$got"
got=$(run_launcher claude quiet SEAT_QUIET_AFTER_S=0 SHIM_QUIET_SLEEP=1)
check "SEAT_QUIET_AFTER_S=0 disables the watchdog" "0" "$got"

echo ""
echo "== issue 84: the fast spend-limit exit is 78, a slow one is not =="
for vendor in claude kimi grok; do
    got=$(run_launcher "$vendor" limit)
    check "$vendor / spend-limit stream (real 2026-09-13 log)" "78" "$got"
done
got=$(run_launcher claude slow-limit PROVIDER_LIMIT_MAX_SEAT_S=1 SHIM_SLOW_LIMIT_SLEEP=2)
check "the same text after real work time is not the signature" "1" "$got"

echo ""
echo "== the plain classifications still hold with the watchdog in the pipe =="
for pair in "success 0" "fail 1" "ratecap 75" "noauth 69"; do
    mode="${pair% *}"; want="${pair#* }"
    got=$(run_launcher claude "$mode")
    check "claude / $mode" "$want" "$got"
done

# ------------------------------------------------------------------ seats --
echo ""
echo "== a quiet seat and a limit seat end to end through run-remote =="
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
FLEET="$SANDBOX/fleet"; mkdir -p "$FLEET/tests" "$FLEET/logs" "$FLEET/wave-plans" "$FLEET/learnings"
for d in scripts providers config roles skills; do cp -R "$REPO_DIR/$d" "$FLEET/$d"; done
cp -R "$REPO_DIR/tests/shims" "$FLEET/tests/shims"
cp -R "$REPO_DIR/tests/fixtures" "$FLEET/tests/fixtures"
ORIGIN="$SANDBOX/product.git"
git init -q --bare -b main "$ORIGIN"
export GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@example.invalid \
       GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@example.invalid
seed="$SANDBOX/seed"
git clone -q "$ORIGIN" "$seed" 2>/dev/null
( cd "$seed" && git checkout -q -b main 2>/dev/null; echo "# product" > README.md \
  && git add README.md && git commit -q -m "chore: seed" && git push -q origin main 2>/dev/null )
export PATH="$FLEET/tests/shims:$PATH"
export SEAT_WAIT_POLL_S=1 DISPATCH_LOCK_POLL_S=1 FLEET_HEARTBEAT_S=0
export SEAT_QUIET_AFTER_S=2 SEAT_QUIET_POLL_S=1 SEAT_QUIET_KILL_GRACE_S=1
unset AGENT_PROVIDER AGENT_MODEL FLEET_EVENTS_FILE FLEET_EVENTS_DIR
unset DISPATCH_DETACHED DISPATCH_RUN_LOG FLEET_DISPATCH_ID SHIM_MODE_FILE

seat() { # <task-id> <branch> <mode> [VAR=val ...]
    local tid="$1" branch="$2" mode="$3"; shift 3
    env SHIM_MODE="$mode" "$@" AGENT_PROVIDER=claude AGENT_WAVE=1 AGENT_TASK_ID="$tid" \
        FLEET_DISPATCH_ID=d1 \
        bash "$FLEET/scripts/run-remote.sh" localhost "$ORIGIN" devops "do the thing" "$branch"
}
seat_trees() { git -C "$HOME/dev/product" worktree list --porcelain 2>/dev/null | grep -c "^worktree .*/worktrees/"; }

seat 0 feat/hung quiet SHIM_QUIET_SLEEP=30 > "$SANDBOX/hung.log" 2>&1
check "quiet seat: run-remote exit" "124" "$?"
check "quiet seat: ledger marks it failed" "1" \
      "$(grep -c '"status":"failed"' "$FLEET/wave-plans/1/handoffs/1-devops-feat-hung.jsonl" 2>/dev/null)"
check "quiet seat: the learning carries the HUNG code" "1" \
      "$(grep -c '"summary":"HUNG:' "$FLEET/learnings/product.jsonl" 2>/dev/null)"
check "quiet seat: worktree cleaned up" "0" "$(seat_trees)"

seat 1 feat/limited limit > "$SANDBOX/limit.log" 2>&1
check "limit seat: run-remote exit" "78" "$?"
HOLD="$FLEET/logs/provider-state/claude-default.limit-hold"
check_true "limit seat: the hold file is written" test -f "$HOLD"
check "limit seat: the hold carries the reset time from the message" "1" \
      "$(grep -c '7:50pm' "$HOLD" 2>/dev/null)"
check_true "limit seat: no rate-cap cooldown for a limit" test ! -f "$FLEET/logs/provider-state/claude.cooldown"
rm -f "$HOLD"

# ------------------------------------------------------------- dispatches --
BASH4=""
for cand in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$cand" ] && [ "$("$cand" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] 2>/dev/null && { BASH4="$cand"; break; }
done
if [ -z "$BASH4" ]; then
    echo "  skip bash >= 4 not found: the dispatch rows need scripts/dispatch.sh"
else
    echo ""
    echo "== issue 92 end to end: a hung seat is stopped and retried once =="
    export SHIM_STATE_DIR="$SANDBOX/shim-state"; mkdir -p "$SHIM_STATE_DIR"
    export FLEET_BACKOFF_DELAYS=1 SHIM_WORK_SLEEP=1
    STOPS="$FLEET/logs/fleet-stops.jsonl"
    events_now() { ls -t "$FLEET/logs/fleet-events"/*.jsonl 2>/dev/null | head -1; }
    plan_one() { printf '# TIER: C\n1 | devops | do the thing | %s\n' "$2" > "$FLEET/wave-plans/$1.plan"; }
    disp() { # <plan> -> runs a real dispatch, prints its exit code
        ( cd "$FLEET" && "$BASH4" scripts/dispatch.sh "$ORIGIN" "wave-plans/$1.plan" \
              --auto --retries 1 --skip-auth-preflight ) > "$SANDBOX/disp-$1.log" 2>&1
        echo $?
    }

    plan_one hung feat/hung-seat
    check "hung-seat dispatch exit" "0" "$(SHIM_MODE=quiet-once disp hung)"
    EV1="$(events_now)"
    check "the seat was dispatched exactly twice (stop, then one retry)" "2" \
          "$(grep -c '"event":"seat_dispatch"' "$EV1")"
    check "the retry did the work" "1" \
          "$(grep -cE 'success \(retry 1, [A-Za-z]+\)' "$SANDBOX/disp-hung.log")"
    check "a stop row names the seat and the quiet period" "1" \
          "$(grep '"kind":"seat_hung"' "$STOPS" | grep -c 'devops.*no model event for 2s')"
    check "the stop is cleared when the retry succeeds" "1" \
          "$(grep -c '"state":"cleared","reason":"the retry did the work"' "$STOPS")"
    check "worktrees after the hung dispatch" "0" "$(seat_trees)"

    echo ""
    echo "== issue 84 end to end: a limit exit is held, the retry is not burned =="
    MODEFILE="$SANDBOX/shim-mode"; export SHIM_MODE_FILE="$MODEFILE"
    echo limit > "$MODEFILE"
    plan_one limited feat/limit-seat
    check "limit dispatch exit" "0" "$(SHIM_MODE=unused disp limited)"
    EV2="$(events_now)"
    check "the held seat was dispatched exactly once" "1" \
          "$(grep -c '"event":"seat_dispatch"' "$EV2")"
    check "the retry was not consumed" "0" \
          "$(grep -c 'Retrying task' "$SANDBOX/disp-limited.log")"
    check "the seat reads held, not failed" "1" \
          "$(grep -cE 'held\([a-z0-9.-]+/[a-z0-9.-]+\)' "$SANDBOX/disp-limited.log")"
    check "the stop row names the provider and the reset time" "1" \
          "$(grep '"kind":"provider_limit"' "$STOPS" | grep -c 'resets 7:50pm')"
    check "exactly one hold file is in place" "1" \
          "$(ls "$FLEET"/logs/provider-state/*.limit-hold 2>/dev/null | wc -l | tr -d ' ')"

    echo ""
    echo "== no seat starts on the held provider and model =="
    plan_one gated feat/gated-seat
    check "gated dispatch exit" "0" "$(SHIM_MODE=unused disp gated)"
    EV3="$(events_now)"
    check "no seat was dispatched while the probe keeps failing" "0" \
          "$(grep -c '"event":"seat_dispatch"' "$EV3")"
    check "the gate says held" "1" \
          "$(grep -c 'held for a provider limit' "$SANDBOX/disp-gated.log")"

    echo ""
    echo "== a probe success releases the hold =="
    echo success > "$MODEFILE"
    plan_one resumed feat/resumed-seat
    check "resumed dispatch exit" "0" "$(SHIM_MODE=unused disp resumed)"
    EV4="$(events_now)"
    check "no hold file is left" "0" \
          "$(ls "$FLEET"/logs/provider-state/*.limit-hold 2>/dev/null | wc -l | tr -d ' ')"
    check "the seat starts again after the probe" "1" \
          "$(grep -c '"event":"seat_dispatch"' "$EV4")"
    check "the stop row is cleared" "1" \
          "$(grep -c '"state":"cleared","reason":"probe passed on ' "$STOPS")"
    check "the resumed seat did the work" "1" \
          "$(grep -c 'completed in' "$SANDBOX/disp-resumed.log")"
    unset SHIM_MODE_FILE
fi

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
    for f in "$SANDBOX"/*.log; do
        [ -f "$f" ] || continue
        echo "---- $(basename "$f") (last 30 lines) ----"; tail -30 "$f"
    done
fi
[ "$fail" -eq 0 ]
