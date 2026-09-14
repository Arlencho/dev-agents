#!/bin/bash
# Ground Truth: dispatch.sh --detach, dispatch-status.sh, dispatch-wait.sh and
# the queue runner. No network, no vendor CLIs: scripts/run-remote.sh is
# replaced by a stub seat that sleeps and exits 0, ssh is a stub that fails at
# once, and everything runs in a throwaway copy of the fleet under a throwaway
# HOME, so the operator's ~/dev, queue and event streams are never touched.
#
# The claim under test: a dispatch started with --detach from a shell keeps
# running and finishes with its events, queue marks and lock release intact
# after that shell's whole process group is killed (the harness kill that
# takes an attached dispatch down with the chat session).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-60s -> %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-60s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}
check_true() { # <name> <command...>
    local name="$1"; shift
    if "$@"; then printf '  ok   %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL %s\n' "$name"; fail=$((fail+1)); fi
}

BASH4=""
for cand in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
    [ -n "$cand" ] && [ -x "$cand" ] && [ "$("$cand" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] 2>/dev/null && { BASH4="$cand"; break; }
done
if [ -z "$BASH4" ]; then
    echo "  skip bash >= 4 not found: scripts/dispatch.sh needs it"
    exit 0
fi
command -v perl >/dev/null 2>&1 || { echo "  skip perl not found: --detach needs it"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  skip python3 not found: the queue needs it"; exit 0; }

# ---- sandbox -----------------------------------------------------------------
SANDBOX=$(mktemp -d)
cleanup() {
    # Sweep any detached run this suite started; they are session leaders, so
    # they are named by pid file, not by job.
    local pf p
    for pf in "$FLEET"/logs/dispatch-runs/*.pid; do
        [ -f "$pf" ] || continue
        p=$(head -n 1 "$pf" 2>/dev/null)
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$SANDBOX"
}
trap cleanup EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
FLEET="$SANDBOX/fleet"; mkdir -p "$FLEET/logs" "$FLEET/wave-plans" "$FLEET/bin"
for d in scripts providers config roles skills; do cp -R "$REPO_DIR/$d" "$FLEET/$d"; done
export FLEET_NOTIFY_SILENT=1 DISPATCH_LOCK_POLL_S=1 FLEET_HEARTBEAT_S=1 DISPATCH_WAIT_POLL_S=1
unset FLEET_EVENTS_FILE FLEET_EVENTS_DIR FLEET_QUEUE_FILE DISPATCH_RUNS_DIR QUEUE_RUNNER_PAUSE
# This suite may itself run inside a dispatched seat. A detached child carries
# its id in DISPATCH_DETACHED (dispatch.sh then runs the attached path and never
# forks) and every seat carries FLEET_DISPATCH_ID; neither may leak in here.
unset DISPATCH_DETACHED DISPATCH_RUN_LOG FLEET_DISPATCH_ID
# The runner's memory guard is the loop suite's business (run-queue-loop-tests.sh);
# here the machine's own memory must not decide whether a start happens.
export QUEUE_RUNNER_MIN_FREE_PCT=0 QUEUE_RUNNER_MAX_SWAP_GB=100000 FLEET_STOPS_FILE="$FLEET/logs/fleet-stops.jsonl"

# The stub seat: what run-remote.sh looks like from the dispatcher's side.
cat > "$FLEET/scripts/run-remote.sh" <<'STUB'
#!/bin/bash
echo "stub seat: host=$1 agent=$3 branch=$5 provider=${AGENT_PROVIDER:-?} dispatch=${FLEET_DISPATCH_ID:-?}"
sleep "${STUB_SEAT_SLEEP:-4}"
echo "stub seat done"
exit 0
STUB
chmod +x "$FLEET/scripts/run-remote.sh"
# ssh fails at once: the worker probe prints OFFLINE, the capacity check reads 0.
printf '#!/bin/sh\nexit 255\n' > "$FLEET/bin/ssh"; chmod +x "$FLEET/bin/ssh"
export PATH="$FLEET/bin:$PATH"

ORIGIN="git@example.invalid:fleet/product.git"
RUNS="$FLEET/logs/dispatch-runs"
EVENTS="$FLEET/logs/fleet-events"
QUEUE_FILE="$FLEET/logs/fleet-queue.json"
LOCKS="$HOME/dev/dispatch-locks/product"

plan() { # <name> <purpose> <branch...>
    local name="$1" purpose="$2"; shift 2
    {
        echo "# $purpose"
        echo "# TIER: C"
        echo "# DISPATCH: ./scripts/dispatch.sh $ORIGIN wave-plans/$name.plan --auto --retries 0 --skip-auth-preflight"
        local w=1 b
        for b in "$@"; do echo "$w | devops | do the thing | $b"; w=$((w + 1)); done
    } > "$FLEET/wave-plans/$name.plan"
}
plan alpha "Alpha: two waves, one seat each." feat/alpha-1 feat/alpha-2
plan beta "Beta: one seat." feat/beta
plan gamma "Gamma: one seat." feat/gamma

# Pid files other than the ones this suite already knows about.
new_pid_files() { # <known id...>
    local f n=0 k seen
    for f in "$RUNS"/*.pid; do
        [ -f "$f" ] || continue
        seen=false
        for k in "$@"; do [ "$f" = "$RUNS/$k.pid" ] && seen=true; done
        [ "$seen" = true ] || n=$((n + 1))
    done
    echo "$n"
}

wait_for() { # <seconds> <command...>  poll until the command succeeds
    local n=$(( $1 * 10 )); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
    return 1
}
has_line() { grep -q "$1" "$2" 2>/dev/null; }

STATUS="$FLEET/scripts/dispatch-status.sh"
WAIT="$FLEET/scripts/dispatch-wait.sh"
RUNNER="$FLEET/scripts/queue-runner.sh"
QUEUE="$FLEET/scripts/queue.sh"

echo "== --detach returns at once with the id, pid and log path =="
# The launcher: a shell in a process group of its own (what a chat harness or a
# terminal owns), which starts the dispatch detached and then stays alive.
LAUNCH_OUT="$SANDBOX/launch.out"
perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; setpgrp(0,0); exec @ARGV or die $!' -- \
    "$BASH4" -c "cd '$FLEET' && scripts/dispatch.sh '$ORIGIN' wave-plans/alpha.plan --detach --retries 0 --skip-auth-preflight > '$LAUNCH_OUT' 2>&1; sleep 120" &
LAUNCHER=$!
disown "$LAUNCHER" 2>/dev/null || true   # its death by signal is the point, not a job notice
wait_for 10 has_line '^dispatch id: ' "$LAUNCH_OUT"
check "launcher printed the dispatch id" "0" "$?"
ID=$(sed -n 's/^dispatch id: *//p' "$LAUNCH_OUT")
PID=$(sed -n 's/^pid: *\([0-9]*\).*/\1/p' "$LAUNCH_OUT")
check_true "dispatch id has the <utc>-<repo>-<pid> shape" bash -c "[[ '$ID' =~ ^[0-9]{8}-[0-9]{6}-product-[0-9]+$ ]]"
check "log path printed" "$RUNS/$ID.log" "$(sed -n 's/^log: *//p' "$LAUNCH_OUT")"
check_true "pid file written beside the log" test -f "$RUNS/$ID.pid"
check "pid file line 1 is the child pid" "$PID" "$(sed -n 1p "$RUNS/$ID.pid")"
check "pid file line 2 is the repo slug" "product" "$(sed -n 2p "$RUNS/$ID.pid")"
check "pid file line 3 is the plan" "wave-plans/alpha.plan" "$(sed -n 3p "$RUNS/$ID.pid")"
check_true "launcher shell is still alive (it returned from --detach)" kill -0 "$LAUNCHER"

echo ""
echo "== the child is a session leader outside the launcher's process group =="
read -r c_pid c_pgid c_tty <<< "$(ps -o pid=,pgid=,tty= -p "$PID" 2>/dev/null | awk '{print $1, $2, $3}')"
check "child pid" "$PID" "${c_pid:-}"
check "child leads its own process group (pgid == pid)" "$PID" "${c_pgid:-}"
check_true "child's group is not the launcher's" test "${c_pgid:-}" != "$LAUNCHER"
# macOS ps prints ?? for no controlling terminal, Linux ps prints ?; accept both.
case "${c_tty:-}" in "?"|"??") c_tty="??" ;; esac
check "child has no controlling terminal" "??" "${c_tty:-}"

echo ""
echo "== dispatch-status says running (exit 3) while the seats work =="
wait_for 15 has_line '"event":"seat_dispatch"' "$EVENTS/$ID.jsonl"
check "event stream opened under the printed id" "0" "$?"
st_out=$("$STATUS" "$ID" 2>&1); st_rc=$?
check "dispatch-status exit while running" "3" "$st_rc"
printf '%s\n' "$st_out" | grep -q "^dispatch $ID: running"; check "headline says running" "0" "$?"
printf '%s\n' "$st_out" | grep -q "devops.*feat/alpha-1.*running"; check "seat table shows the live seat" "0" "$?"
printf '%s\n' "$st_out" | grep -q "^log ("; check "log tail section present" "0" "$?"

echo ""
echo "== kill the launcher's whole process group: the dispatch survives =="
kill -TERM -"$LAUNCHER" 2>/dev/null
sleep 0.5
kill -KILL -"$LAUNCHER" 2>/dev/null
wait_for 5 bash -c "! kill -0 $LAUNCHER 2>/dev/null"
check_true "launcher group is dead" bash -c "! kill -0 $LAUNCHER 2>/dev/null"
check_true "detached dispatch still alive after the group kill" kill -0 "$PID"
sleep 1
check_true "still alive a second later" kill -0 "$PID"
check "still exit 3 from dispatch-status" "3" "$("$STATUS" "$ID" >/dev/null 2>&1; echo $?)"

echo ""
echo "== dispatch-wait returns when the run ends; status flips to 0 =="
w_out=$("$WAIT" "$ID" 60 2>&1); w_rc=$?
check "dispatch-wait exit after the end" "0" "$w_rc"
printf '%s\n' "$w_out" | grep -q "^dispatch $ID: ended  completed  2/2 succeeded, 0 failed"; check "wait printed the final summary" "0" "$?"
printf '%s\n' "$w_out" | grep -q "exit 0"; check "final summary carries the exit code" "0" "$?"
check "dispatch-status exit after the end" "0" "$("$STATUS" "$ID" >/dev/null 2>&1; echo $?)"
check "exit file holds 0" "0" "$(cat "$RUNS/$ID.exit" 2>/dev/null)"
check_true "child pid is gone" bash -c "! kill -0 $PID 2>/dev/null"

echo ""
echo "== events, queue marks, lock and log are what an attached run leaves =="
ev="$EVENTS/$ID.jsonl"
check "one dispatch_start" "1" "$(grep -c '"event":"dispatch_start"' "$ev")"
check "two seat_dispatch (one per wave)" "2" "$(grep -c '"event":"seat_dispatch"' "$ev")"
check "two seat_exit success" "2" "$(grep -c '"event":"seat_exit".*"status":"success"' "$ev")"
check "two wave_end" "2" "$(grep -c '"event":"wave_end"' "$ev")"
check "dispatch_end completed" "1" "$(grep -c '"event":"dispatch_end".*"status":"completed"' "$ev")"
check "latest pointer names this stream" "$ID.jsonl" "$(cat "$EVENTS/latest")"
q_status=$(python3 -c 'import json,sys; e=[x for x in json.load(open(sys.argv[1]))["entries"] if x["plan"]=="wave-plans/alpha.plan"][0]; print(e["status"], e["settled_status"], e["dispatch_id"])' "$QUEUE_FILE" 2>/dev/null)
check "queue entry settled completed under the printed id" "settled completed $ID" "$q_status"
check "branch locks released" "0" "$(ls "$LOCKS"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
has_line "Detached dispatch $ID: pid $PID, session leader" "$RUNS/$ID.log"; check "log opens with the detached banner" "0" "$?"
has_line "auto implied" "$RUNS/$ID.log"; check "log says --auto is implied" "0" "$?"
has_line "Dispatch Results" "$RUNS/$ID.log"; check "log holds the final report" "0" "$?"
has_line "\[notify\] Agent Succeeded" "$RUNS/$ID.log"; check "notify hook ran (stdout fallback in the log)" "0" "$?"
check "no color escapes in the log" "0" "$(grep -c $'\033\[' "$RUNS/$ID.log")"

echo ""
echo "== dispatch-wait with a short timeout returns 3 and a snapshot =="
out2=$(cd "$FLEET" && STUB_SEAT_SLEEP=6 "$BASH4" scripts/dispatch.sh "$ORIGIN" wave-plans/beta.plan --detach --retries 0 --skip-auth-preflight 2>&1)
ID2=$(printf '%s\n' "$out2" | sed -n 's/^dispatch id: *//p')
check_true "second detached run started" test -n "$ID2"
t_out=$("$WAIT" "$ID2" 1 2>&1); t_rc=$?
check "dispatch-wait exit on timeout" "3" "$t_rc"
printf '%s\n' "$t_out" | grep -q "^dispatch-wait: 1s passed, $ID2 still running"; check "timeout is announced" "0" "$?"
check "then it finishes" "0" "$("$WAIT" "$ID2" 60 >/dev/null 2>&1; echo $?)"
check "unknown id exits 2" "2" "$("$STATUS" no-such-run >/dev/null 2>&1; echo $?)"
check "no id exits 2" "2" "$("$STATUS" >/dev/null 2>&1; echo $?)"

echo ""
echo "== --detach refuses --interactive and a missing plan, in the foreground =="
check "--interactive with --detach" "1" "$(cd "$FLEET" && "$BASH4" scripts/dispatch.sh "$ORIGIN" --interactive --detach >/dev/null 2>&1; echo $?)"
check "missing plan with --detach" "1" "$(cd "$FLEET" && "$BASH4" scripts/dispatch.sh "$ORIGIN" wave-plans/nope.plan --detach >/dev/null 2>&1; echo $?)"
help_text=$("$BASH4" "$FLEET/scripts/dispatch.sh" --help 2>&1 || true)
printf '%s' "$help_text" | grep -q -- "--detach"; check "dispatch.sh --help lists --detach" "0" "$?"

echo ""
echo "== queue runner: starts one queued plan, not a second while it runs =="
rm -f "$QUEUE_FILE"
plan delta "Delta: one seat." feat/delta
printf '# Held: no DISPATCH line on purpose\n# TIER: C\n1 | devops | do the thing | feat/held\n' > "$FLEET/wave-plans/held.plan"
"$QUEUE" add wave-plans/held.plan other >/dev/null
"$QUEUE" block wave-plans/held.plan "waiting on a decision" >/dev/null
"$QUEUE" add wave-plans/gamma.plan product >/dev/null
"$QUEUE" add wave-plans/delta.plan product >/dev/null
"$QUEUE" list | grep -q "blocked: waiting on a decision"; check "queue list shows the blocked reason" "0" "$?"

dry=$(cd "$FLEET" && "$RUNNER" --dry-run 2>&1); check "dry run exit" "0" "$?"
printf '%s\n' "$dry" | grep -q "would start: .*wave-plans/gamma.plan --detach --auto --auto --retries 0 --skip-auth-preflight"; check "dry run names the first unblocked plan with the plan's own flags" "0" "$?"
check "dry run started nothing" "0" "$(new_pid_files "$ID" "$ID2")"

paused=$(cd "$FLEET" && QUEUE_RUNNER_PAUSE=1 "$RUNNER" --verbose 2>&1); check "paused tick exit" "0" "$?"
printf '%s\n' "$paused" | grep -q "paused (QUEUE_RUNNER_PAUSE=1)"; check "paused tick says so and starts nothing" "0" "$?"
check "paused tick started nothing" "0" "$(new_pid_files "$ID" "$ID2")"

tick1=$(cd "$FLEET" && STUB_SEAT_SLEEP=6 "$RUNNER" --verbose 2>&1); check "tick 1 exit" "0" "$?"
printf '%s\n' "$tick1" | grep -q "started wave-plans/gamma.plan for product: dispatch"; check "tick 1 started gamma (first unblocked, repo idle)" "0" "$?"
ID3=$(printf '%s\n' "$tick1" | sed -n 's/.*dispatch \([0-9]\{8\}-[0-9]\{6\}-product-[0-9]*\).*/\1/p' | head -n 1)
check_true "tick 1 reported a dispatch id" test -n "$ID3"
has_line "started wave-plans/gamma.plan for product: dispatch $ID3" "$RUNS/queue-runner.log"; check "runner log records the start" "0" "$?"
check_true "the blocked plan was skipped (still queued, still blocked)" bash -c "python3 -c 'import json,sys; e=[x for x in json.load(open(sys.argv[1]))[\"entries\"] if x[\"plan\"]==\"wave-plans/held.plan\"][0]; sys.exit(0 if e[\"status\"]==\"queued\" and e[\"blocked\"] else 1)' '$QUEUE_FILE'"

wait_for 15 has_line '"event":"seat_dispatch"' "$EVENTS/$ID3.jsonl"
check "gamma is running" "3" "$("$STATUS" "$ID3" >/dev/null 2>&1; echo $?)"
tick2=$(cd "$FLEET" && "$RUNNER" --verbose 2>&1); check "tick 2 exit" "0" "$?"
printf '%s\n' "$tick2" | grep -q "busy: product (detached dispatch pid"; check "tick 2 sees product busy" "0" "$?"
printf '%s\n' "$tick2" | grep -q "skip: wave-plans/delta.plan (product is busy)"; check "tick 2 does not start delta" "0" "$?"
check "delta still queued" "queued" "$(python3 -c 'import json,sys; print([x for x in json.load(open(sys.argv[1]))["entries"] if x["plan"]=="wave-plans/delta.plan"][0]["status"])' "$QUEUE_FILE")"
check "one running entry in the queue" "1" "$(python3 -c 'import json,sys; print(sum(1 for x in json.load(open(sys.argv[1]))["entries"] if x["status"]=="running"))' "$QUEUE_FILE")"

check "gamma ends" "0" "$("$WAIT" "$ID3" 60 >/dev/null 2>&1; echo $?)"
tick3=$(cd "$FLEET" && "$RUNNER" --verbose 2>&1); check "tick 3 exit" "0" "$?"
printf '%s\n' "$tick3" | grep -q "started wave-plans/delta.plan for product: dispatch"; check "tick 3 starts delta once gamma ended" "0" "$?"
ID4=$(printf '%s\n' "$tick3" | sed -n 's/.*dispatch \([0-9]\{8\}-[0-9]\{6\}-product-[0-9]*\).*/\1/p' | head -n 1)
check "delta ends" "0" "$("$WAIT" "$ID4" 60 >/dev/null 2>&1; echo $?)"
tick4=$(cd "$FLEET" && "$RUNNER" --verbose 2>&1); check "tick 4 exit" "0" "$?"
printf '%s\n' "$tick4" | grep -q "nothing queued and unblocked"; check "tick 4 is idle" "0" "$?"

echo ""
echo "== queue runner: a plan without a DISPATCH line is blocked with the reason =="
"$QUEUE" unblock wave-plans/held.plan >/dev/null
tick5=$(cd "$FLEET" && "$RUNNER" --verbose 2>&1); check "tick 5 exit" "0" "$?"
printf '%s\n' "$tick5" | grep -q "cannot start wave-plans/held.plan for other: no '# DISPATCH:"; check "tick 5 names the missing header" "0" "$?"
check "held is blocked again with the runner's reason" "runner: no DISPATCH header line in the plan" \
    "$(python3 -c 'import json,sys; print([x for x in json.load(open(sys.argv[1]))["entries"] if x["plan"]=="wave-plans/held.plan"][0]["blocked"])' "$QUEUE_FILE")"

echo ""
echo "== a live branch lock (an attached run) also counts as busy =="
mkdir -p "$LOCKS"
sleep 30 & HOLDER=$!
printf '%s\nwave-plans/attached.plan\n2026-09-13T00:00:00Z\n' "$HOLDER" > "$LOCKS/feat-attached.lock"
plan epsilon "Epsilon: one seat." feat/epsilon
"$QUEUE" add wave-plans/epsilon.plan product >/dev/null
tick6=$(cd "$FLEET" && "$RUNNER" --verbose 2>&1); check "tick 6 exit" "0" "$?"
printf '%s\n' "$tick6" | grep -q "busy: product (branch lock feat-attached.lock held by pid $HOLDER)"; check "tick 6 sees the attached run's lock" "0" "$?"
printf '%s\n' "$tick6" | grep -q "skip: wave-plans/epsilon.plan (product is busy)"; check "tick 6 starts nothing for product" "0" "$?"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -f "$LOCKS/feat-attached.lock"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
