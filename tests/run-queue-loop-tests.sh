#!/usr/bin/env bash
# Ground Truth: the orchestrator loop in scripts/queue-runner.sh and
# scripts/queue_loop.py. Five claims, each against fixtures under
# tests/fixtures/loop/, no network, no vendor CLIs, nothing real started:
#
#   1. memory guard: a fake vm_stat / sysctl under the thresholds holds every
#      start, is logged once per change of state, shows in the queue render
#      and the stops file, and resumes by itself; nothing is ever killed
#   2. AFTER header: a plan naming another plan waits, says why in place, and
#      is released only by a dispatch_end with outcome landed
#   3. one fix round: a BLOCK-FIX writes <plan>-fix1.plan (same producer role
#      and branch, the comment quoted in full, the same critic for round 2,
#      AFTER the original) and queues it first; a second BLOCK-FIX, an
#      escalation, a close, a bare word, a quoted verdict and a silent critic
#      queue nothing and are stops
#   4. landing: every critic SAFE-TO-MERGE or APPROVE-MERGE plus green checks
#      plus CLEAN calls land.sh (a draft is marked ready first); one silent
#      critic of two, a stale comment from before the run, a pending check or
#      a BEHIND merge state never merge
#   5. stops: a red check and a refused merge are one line each in the stops
#      file with the critic sentence and one action; the desk reads them; a
#      merged PR clears its stop; no absolute path and no comment body ever
#      enters the file
#
# Also: --dry-run writes nothing, and the verdict parser is imported from
# scripts/desk_live.py, never re-implemented.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/loop"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-64s -> %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-64s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}
check_true() { # <name> <command...>
    local name="$1"; shift
    if "$@"; then printf '  ok   %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL %s\n' "$name"; fail=$((fail+1)); fi
}
command -v python3 >/dev/null 2>&1 || { echo "  skip python3 not found"; exit 0; }

# ---- sandbox -----------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
FLEET="$SANDBOX/fleet"; mkdir -p "$FLEET/logs" "$FLEET/wave-plans" "$FLEET/bin"
for d in scripts config; do cp -R "$REPO_DIR/$d" "$FLEET/$d"; done
unset FLEET_EVENTS_FILE FLEET_EVENTS_DIR FLEET_QUEUE_FILE DISPATCH_RUNS_DIR QUEUE_RUNNER_PAUSE FLEET_STOPS_FILE
unset QUEUE_RUNNER_MIN_FREE_PCT QUEUE_RUNNER_MAX_SWAP_GB DISPATCH_DETACHED DISPATCH_RUN_LOG FLEET_DISPATCH_ID
export LOCK_DIR="$SANDBOX/locks"; mkdir -p "$LOCK_DIR"

RUNS="$FLEET/logs/dispatch-runs"; EVENTS="$FLEET/logs/fleet-events"
QUEUE_FILE="$FLEET/logs/fleet-queue.json"; STOPS="$FLEET/logs/fleet-stops.jsonl"
RUNNER_LOG="$RUNS/queue-runner.log"
mkdir -p "$RUNS" "$EVENTS"
RUNNER="$FLEET/scripts/queue-runner.sh"; QUEUE="$FLEET/scripts/queue.sh"
ORIGIN="git@github.com:acme/product.git"

# Fake memory readers: vm_stat and sysctl answer from files the tests point at.
export FAKE_VM_STAT="$SANDBOX/vm_stat.txt" FAKE_SWAP="$SANDBOX/swap.txt"
cat > "$FLEET/bin/vm_stat" <<'STUB'
#!/bin/sh
cat "$FAKE_VM_STAT"
STUB
cat > "$FLEET/bin/sysctl" <<'STUB'
#!/bin/sh
case "$*" in
  *hw.memsize*) echo 34359738368 ;;
  *vm.swapusage*) cat "$FAKE_SWAP" ;;
  *) exit 1 ;;
esac
STUB
# Fake gh: records every call, answers `pr list` from the scenario file, `pr
# view N` from view-N.json when present (else an open clean PR), `pr ready` ok.
export GH_LOG="$SANDBOX/gh.log" GH_SCENARIO="$SANDBOX/gh.scenario" GH_DIR="$SANDBOX/gh"
mkdir -p "$GH_DIR"; cp "$FIX"/pr-*.json "$GH_DIR/"
cat > "$FLEET/bin/gh" <<'STUB'
#!/bin/sh
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") cat "$GH_DIR/$(cat "$GH_SCENARIO").json" ;;
  "pr view") if [ -f "$GH_DIR/view-$3.json" ]; then cat "$GH_DIR/view-$3.json"; else echo '{"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN"}'; fi ;;
  "pr ready") exit 0 ;;
  *) exit 1 ;;
esac
STUB
# Stub dispatch.sh: records the start, starts nothing.
export DISPATCH_LOG="$SANDBOX/dispatch.log"
cat > "$FLEET/scripts/dispatch.sh" <<'STUB'
#!/bin/sh
echo "$*" >> "$DISPATCH_LOG"
echo "dispatch id: stub-run"
echo "pid:         1 (session leader)"
STUB
# Stub land.sh: records the PR and the repo it was told, exits as told.
export LAND_LOG="$SANDBOX/land.log" LAND_RC_FILE="$SANDBOX/land.rc"
echo 0 > "$LAND_RC_FILE"
cat > "$FLEET/scripts/land.sh" <<'STUB'
#!/bin/sh
echo "$* LAND_REPO=${LAND_REPO:-} LAND_ROOT=${LAND_ROOT:-}" >> "$LAND_LOG"
echo "== PR #$1"
exit "$(cat "$LAND_RC_FILE")"
STUB
chmod +x "$FLEET/bin"/* "$FLEET/scripts"/*.sh "$FLEET/scripts"/*.py
export PATH="$FLEET/bin:$PATH"

plan() { # <name> <purpose> <branch> [after]
    {
        echo "# $1: $2"
        echo "# DISPATCH: ./scripts/dispatch.sh $ORIGIN wave-plans/$1.plan --retries 0 --skip-auth-preflight"
        [ -n "${4:-}" ] && echo "# AFTER: wave-plans/$4.plan"
        echo "1 | devops | build the thing, with the words fix | and pipe kept | $3"
        echo "2 | devops-critic | READ-ONLY REVIEW of the PR on $3. Post ONE comment whose first line reads CRITIC $(echo "$1" | tr a-z A-Z) with SAFE-TO-MERGE or BLOCK-FIX. | $3"
    } > "$FLEET/wave-plans/$1.plan"
}
# A pid that is certainly dead: a process that has already exited.
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
ended_run() { # <id> <plan> <stream fixture>
    printf '%s\nproduct\nwave-plans/%s.plan\n2026-09-13T10:00:00Z\n%s\n' "$DEAD" "$2" "$ORIGIN" > "$RUNS/$1.pid"
    cp "$FIX/$3" "$EVENTS/$1.jsonl"
    # What dispatch.sh does for any plan it runs: mark it running, then settle it.
    "$QUEUE" start "wave-plans/$2.plan" "$1" product >/dev/null
    "$QUEUE" settle "wave-plans/$2.plan" completed >/dev/null
}
tick() { (cd "$FLEET" && "$RUNNER" --verbose 2>&1); }
dry() { (cd "$FLEET" && "$RUNNER" --dry-run 2>&1); }
count() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
qfield() { # <plan> <field>
    python3 -c 'import json,sys; e=[x for x in json.load(open(sys.argv[1]))["entries"] if x["plan"]==sys.argv[2]]; print((e[0].get(sys.argv[3]) or "") if e else "(absent)")' "$QUEUE_FILE" "$1" "$2"
}
qpos() { python3 -c 'import json,sys; print([x["plan"] for x in json.load(open(sys.argv[1]))["entries"]].index(sys.argv[2]) + 1)' "$QUEUE_FILE" "$1" 2>/dev/null || echo absent; }
stop_field() { # <key> <field>  newest record for the key
    python3 -c 'import json,sys
recs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hits=[r for r in recs if r.get("key")==sys.argv[2]]
print(hits[-1].get(sys.argv[3], "") if hits else "(none)")' "$STOPS" "$1" "$2" 2>/dev/null || echo "(none)"
}
stop_count() { python3 -c 'import json,sys
print(sum(1 for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("key")==sys.argv[2] and json.loads(l).get("state")==sys.argv[3]))' "$STOPS" "$1" "$2" 2>/dev/null || echo 0; }

echo "== 0. one verdict parser =="
check "queue_loop.py defines no verdict parser of its own" "0" "$(grep -c 'def first_line_verdict\|def critic_verdict\|def critic_record' "$REPO_DIR/scripts/queue_loop.py")"
check_true "queue_loop.py imports desk_live" grep -q '^import desk_live' "$REPO_DIR/scripts/queue_loop.py"
check_true "desk_live.first_line_verdict reads the convention" python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import desk_live as d
assert d.first_line_verdict("CRITIC ALPHA BLOCK-FIX") == "BLOCK-FIX"
assert d.first_line_verdict("CRITIC ALPHA ROUND 2: SAFE-TO-MERGE") == "SAFE-TO-MERGE"
assert d.first_line_verdict("CRITIC NOTE: the last review said BLOCK-FIX but this is not a verdict") is None
assert d.first_line_verdict("CRITIC ALPHA BLOCK-FIX SAFE-TO-MERGE") is None
' "$REPO_DIR/scripts"
check "runner never kills a process (kill -0 liveness probes only)" "0" "$(grep -E 'kill (-[^0]|[0-9]|"\$)|pkill|killall' "$REPO_DIR/scripts/queue-runner.sh" "$REPO_DIR/scripts/queue_loop.py" | grep -vc 'kill -0')"
check "queue_loop.py signals nothing (os.kill with 0 only)" "0" "$(grep -c 'os.kill(' "$REPO_DIR/scripts/queue_loop.py" | awk '{print ($1==1)?0:1}')"

echo ""
echo "== 1. memory guard =="
plan gamma "one seat, no AFTER." feat/gamma
"$QUEUE" add wave-plans/gamma.plan product >/dev/null
cp "$FIX/vm_stat-low.txt" "$FAKE_VM_STAT"; cp "$FIX/swap-ok.txt" "$FAKE_SWAP"
out=$(tick); check "tick exit under low free memory" "0" "$?"
printf '%s\n' "$out" | grep -q "memory guard: starts held, free memory 18% is under 50%"; check "the tick says why it holds (free percent against the threshold)" "0" "$?"
printf '%s\n' "$out" | grep -q "nothing is killed"; check "and that nothing is killed" "0" "$?"
check "nothing started" "0" "$(count . "$DISPATCH_LOG")"
check "guard logged once" "1" "$(count 'memory guard: starts held' "$RUNNER_LOG")"
"$QUEUE" list | grep -q "hold: memory guard: starts held"; check "queue render shows the hold" "0" "$?"
check "stops file has the guard open" "open" "$(stop_field memory-guard state)"
check "guard stop has one action" "free memory or wait; the runner resumes by itself" "$(stop_field memory-guard action)"
out=$(tick); check "second tick, same state" "0" "$?"
check "still logged once (once per change of state)" "1" "$(count 'memory guard: starts held' "$RUNNER_LOG")"
check "still nothing started" "0" "$(count . "$DISPATCH_LOG")"
cp "$FIX/vm_stat-ok.txt" "$FAKE_VM_STAT"; cp "$FIX/swap-high.txt" "$FAKE_SWAP"
out=$(tick)
printf '%s\n' "$out" | grep -q "swap used 5.0 GB is over 3.5 GB"; check "swap alone holds too (reason names swap)" "0" "$?"
check "state did not change, still one log line" "1" "$(count 'memory guard: starts held' "$RUNNER_LOG")"
check "still nothing started" "0" "$(count . "$DISPATCH_LOG")"
cp "$FIX/swap-ok.txt" "$FAKE_SWAP"
out=$(tick); check "tick exit once memory recovered" "0" "$?"
printf '%s\n' "$out" | grep -q "memory guard cleared, starts resume"; check "recovery is announced" "0" "$?"
check "recovery logged once" "1" "$(count 'memory guard cleared' "$RUNNER_LOG")"
"$QUEUE" list | grep -q "hold:"; check "hold released in the queue render (grep exit 1)" "1" "$?"
check "guard stop cleared in the stops file" "cleared" "$(stop_field memory-guard state)"
printf '%s\n' "$out" | grep -q "started wave-plans/gamma.plan for product"; check "the held plan started by itself" "0" "$?"
check "dispatch.sh called once, detached and auto" "1" "$(count '--detach --auto' "$DISPATCH_LOG")"
out=$(QUEUE_RUNNER_MIN_FREE_PCT=99 dry)
printf '%s\n' "$out" | grep -q "would log: memory guard: starts held, free memory 51% is under 99%"; check "thresholds come from config, env overrides for one run" "0" "$?"
check "dry run did not touch the guard state" "1" "$(count 'memory guard cleared' "$RUNNER_LOG")"
"$QUEUE" rm wave-plans/gamma.plan >/dev/null

echo ""
echo "== 2. AFTER header =="
plan alpha "producer and critic on one branch." feat/alpha
plan beta "runs after alpha." feat/beta alpha
"$QUEUE" add wave-plans/beta.plan product >/dev/null
out=$(tick); check "tick exit" "0" "$?"
printf '%s\n' "$out" | grep -q "skip: wave-plans/beta.plan (after alpha.plan: not run yet)"; check "beta skipped: alpha not run yet" "0" "$?"
check "reason written in place" "after alpha.plan: not run yet" "$(qfield wave-plans/beta.plan waiting)"
"$QUEUE" list | grep -q "waiting: after alpha.plan: not run yet"; check "queue render shows it" "0" "$?"
check "nothing started" "1" "$(count . "$DISPATCH_LOG")"
cp "$FIX/stream-alpha-failed.jsonl" "$EVENTS/run-alpha-0.jsonl"
out=$(tick)
check "alpha failed: beta still waits and says so" "after alpha.plan: its last run failed (fixture); fix and run it again" "$(qfield wave-plans/beta.plan waiting)"
check "still nothing started" "1" "$(count . "$DISPATCH_LOG")"
ended_run run-alpha-1 alpha stream-alpha-landed.jsonl
echo pr-none > "$GH_SCENARIO"
out=$(tick); check "tick exit after alpha landed" "0" "$?"
check "beta released, reason cleared" "" "$(qfield wave-plans/beta.plan waiting)"
printf '%s\n' "$out" | grep -q "beta.plan no longer waits: alpha.plan has landed"; check "release is logged" "0" "$?"
printf '%s\n' "$out" | grep -q "started wave-plans/beta.plan for product"; check "beta started" "0" "$?"
"$QUEUE" rm wave-plans/beta.plan >/dev/null
# desk_live: AFTER and FIX-ROUND are directives, never the purpose
check "AFTER is a machine header, not a purpose" "" "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import desk_live as d; print("" if d.is_machine_header("AFTER: wave-plans/x.plan") and d.is_machine_header("FIX-ROUND: 1 of x") else "purpose")' "$REPO_DIR/scripts")"

echo ""
echo "== 3. one fix round =="
# run-alpha-1 ended landed with no PR (scenario pr-none): a stop, not a merge.
check "no PR for the critic branch is a stop" "no_pr" "$(stop_field run-alpha-1 kind)"
check "and the run is marked handled" "stop:no_pr" "$(cut -f1 "$RUNS/run-alpha-1.loop")"
rm -f "$RUNS/run-alpha-1.loop"
echo pr-block-fix > "$GH_SCENARIO"
out=$(tick); check "tick exit" "0" "$?"
FIXPLAN="$FLEET/wave-plans/alpha-fix1.plan"
check_true "fix plan written next to the original as <plan>-fix1.plan" test -f "$FIXPLAN"
grep -q "^# AFTER: wave-plans/alpha.plan$" "$FIXPLAN"; check "fix plan carries AFTER the original" "0" "$?"
grep -q "^# FIX-ROUND: 1 of wave-plans/alpha.plan$" "$FIXPLAN"; check "fix plan marks itself round 1" "0" "$?"
grep -q "^# DISPATCH: ./scripts/dispatch.sh $ORIGIN wave-plans/alpha-fix1.plan --retries 0 --skip-auth-preflight$" "$FIXPLAN"; check "DISPATCH line copied with the fix plan path and the same flags" "0" "$?"
check "seat count" "2" "$(grep -c '^[0-9] |' "$FIXPLAN")"
grep -q "^1 | devops | .* | feat/alpha$" "$FIXPLAN"; check "seat 1 is the producer role on the same branch" "0" "$?"
grep -q "^2 | devops-critic | ROUND 2 .* | feat/alpha$" "$FIXPLAN"; check "seat 2 is the same critic for round 2" "0" "$?"
grep -q "quoted in full: CRITIC ALPHA BLOCK-FIX / Findings: / 1. runner has no test for the guard path / 2. the fix plan quotes half the comment / Fix both and cite the tests. Fix every finding and add a test per finding." "$FIXPLAN"; check "task quotes the whole comment and adds the fix words" "0" "$?"
grep -q "Original task: READ-ONLY REVIEW of the PR on feat/alpha" "$FIXPLAN"; check "critic round 2 carries the original critic task" "0" "$?"
check "fix plan queued first for the repo" "1" "$(qpos wave-plans/alpha-fix1.plan)"
check "fix plan purpose from the original header" "alpha: producer and critic on one branch. Fix round 1 after BLOCK-FIX." "$(qfield wave-plans/alpha-fix1.plan purpose)"
check "run marked handled as a fix round" "fix-round" "$(cut -f1 "$RUNS/run-alpha-1.loop")"
check "a fix round is not a stop (only the earlier no_pr record exists)" "1" "$(stop_count run-alpha-1 open)"
printf '%s\n' "$out" | grep -q "started wave-plans/alpha-fix1.plan for product"; check "the fix plan started at once (alpha landed, so AFTER is satisfied)" "0" "$?"
out=$(tick)
check "second tick writes no second plan" "1" "$(ls "$FLEET"/wave-plans/alpha-fix*.plan | wc -l | tr -d ' ')"
"$QUEUE" settle wave-plans/alpha-fix1.plan >/dev/null
# the fix plan's own run ends with a second BLOCK-FIX
ended_run run-fix-1 alpha-fix1 stream-alpha-fix1-landed.jsonl
echo pr-block-fix-round2 > "$GH_SCENARIO"
out=$(tick); check "tick exit" "0" "$?"
check "no second fix plan" "1" "$(ls "$FLEET"/wave-plans/alpha-fix*.plan | wc -l | tr -d ' ')"
check_true "no alpha-fix1-fix1.plan either" test ! -f "$FLEET/wave-plans/alpha-fix1-fix1.plan"
check "second BLOCK-FIX is a stop" "second_block" "$(stop_field run-fix-1 kind)"
check "stop carries the critic sentence" "CRITIC ALPHA ROUND 2: BLOCK-FIX" "$(stop_field run-fix-1 sentence)"
check "stop carries one action" "open the comment; the runner fired its one fix round" "$(stop_field run-fix-1 action)"
check "stop names the PR" "41" "$(stop_field run-fix-1 pr)"
check "nothing queued for it" "(absent)" "$(qfield wave-plans/alpha-fix2.plan purpose)"
# escalation, close, bare word, quoted verdict, silence: nothing queued, a stop each
plan delta "one branch." feat/delta
for case in "pr-block-fix-escalation-sentence escalate BLOCK-ESCALATE" "pr-escalate escalate BLOCK-ESCALATE" "pr-close close BLOCK-CLOSE" "pr-unparsed unparsed BLOCK" "pr-quoted-only critic_silent" "pr-silent critic_silent"; do
    set -- $case
    ended_run "run-delta-$1" delta stream-alpha-landed.jsonl
    echo "$1" > "$GH_SCENARIO"
    tick >/dev/null
    check "$1: stop kind" "$2" "$(stop_field "run-delta-$1" kind)"
    [ -n "${3:-}" ] && check "$1: stop verdict" "$3" "$(stop_field "run-delta-$1" verdict)"
    check_true "$1: no fix plan written" test ! -f "$FLEET/wave-plans/delta-fix1.plan"
done
check "no landing happened in part 3" "0" "$(count . "$LAND_LOG")"

echo ""
echo "== 4. landing =="
plan epsilon "one branch." feat/alpha
ended_run run-eps-1 epsilon stream-alpha-landed.jsonl
echo pr-all-safe-green-draft > "$GH_SCENARIO"
out=$(tick); check "tick exit" "0" "$?"
check "draft marked ready first" "1" "$(count 'pr ready 42 -R acme/product' "$GH_LOG")"
check "land.sh called for the PR with the repo slug" "1" "$(count '^42 LAND_REPO=acme/product' "$LAND_LOG")"
check "run marked landed" "landed" "$(cut -f1 "$RUNS/run-eps-1.loop")"
check "a landing is not a stop" "(none)" "$(stop_field run-eps-1 kind)"
printf '%s\n' "$out" | grep -q "landed PR #42 of acme/product via land.sh"; check "landing logged" "0" "$?"
plan zeta "two critics." feat/zeta
ended_run run-zeta-1 zeta stream-zeta-two-critics.jsonl
echo pr-two-critics-one-silent > "$GH_SCENARIO"
tick >/dev/null
check "one critic of two silent: stop, no merge" "critic_silent" "$(stop_field run-zeta-1 kind)"
check "its sentence counts the seats" "1 of 2 critic seats posted a verdict since the run started" "$(stop_field run-zeta-1 sentence)"
check "land.sh not called" "1" "$(count . "$LAND_LOG")"
ended_run run-zeta-2 zeta stream-zeta-two-critics.jsonl
echo pr-two-critics-safe > "$GH_SCENARIO"
tick >/dev/null
check "both critics safe: landed" "landed" "$(cut -f1 "$RUNS/run-zeta-2.loop")"
check "land.sh called for 51" "1" "$(count '^51 LAND_REPO' "$LAND_LOG")"
plan eta "one branch." feat/alpha
ended_run run-eta-stale eta stream-alpha-landed.jsonl
echo pr-stale-comment > "$GH_SCENARIO"
tick >/dev/null
check "a SAFE comment from before the run started does not count" "critic_silent" "$(stop_field run-eta-stale kind)"
ended_run run-eta-pending eta stream-alpha-landed.jsonl
echo pr-pending > "$GH_SCENARIO"
out=$(tick)
check_true "pending checks: not handled yet, looked at again next tick" test ! -f "$RUNS/run-eta-pending.loop"
check "pending checks: no stop" "(none)" "$(stop_field run-eta-pending kind)"
printf '%s\n' "$out" | grep -q "checks still running: lint; will look again next tick"; check "pending checks are said" "0" "$?"
rm -f "$RUNS/run-eta-pending.pid" "$EVENTS/run-eta-pending.jsonl"
ended_run run-eta-behind eta stream-alpha-landed.jsonl
echo pr-behind > "$GH_SCENARIO"
tick >/dev/null
check "BEHIND merge state: stop, never a merge" "not_clean" "$(stop_field run-eta-behind kind)"
check "land.sh still called twice in total" "2" "$(count . "$LAND_LOG")"

echo ""
echo "== 5. stops =="
ended_run run-eta-red eta stream-alpha-landed.jsonl
echo pr-red-check > "$GH_SCENARIO"
tick >/dev/null
check "red check is a stop" "red_checks" "$(stop_field run-eta-red kind)"
check "its sentence carries the critic line and the red check" "CRITIC ETA: SAFE-TO-MERGE; red checks: lint failure" "$(stop_field run-eta-red sentence)"
check "its action" "open the checks" "$(stop_field run-eta-red action)"
check "a draft with a red check is not marked ready" "0" "$(count 'pr ready 52' "$GH_LOG")"
plan theta "one branch." feat/alpha
ended_run run-theta-1 theta stream-alpha-landed.jsonl
echo pr-all-safe-green > "$GH_SCENARIO"; echo 1 > "$LAND_RC_FILE"
tick >/dev/null
check "land.sh refusing is a stop" "merge_refused" "$(stop_field run-theta-1 kind)"
check "with the critic sentence and the exit" "CRITIC THETA: APPROVE-MERGE; land.sh exit 1: == PR #77" "$(stop_field run-theta-1 sentence)"
check "and one action" "merge by hand; land.sh refused" "$(stop_field run-theta-1 action)"
echo 0 > "$LAND_RC_FILE"
check "every stop is one line each (open records per key)" "1 1 1" "$(stop_count run-eta-red open) $(stop_count run-theta-1 open) $(stop_count run-fix-1 open)"
check "no absolute path in the stops file" "0" "$(count "$SANDBOX" "$STOPS")"
check "no comment body in the stops file" "0" "$(count 'Findings' "$STOPS")"
check "plans are basenames" "theta.plan" "$(stop_field run-theta-1 plan)"
# the desk reads the stops
LIVE="$SANDBOX/live.json"
(cd "$FLEET" && FLEET_STOPS_FILE="$STOPS" python3 scripts/desk_live.py --once --no-gh --events-dir "$EVENTS" --queue-file "$QUEUE_FILE" --out "$LIVE" >/dev/null 2>&1); check "desk_live --once with stops" "0" "$?"
check "live.json lists the open stops" "$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()) )' "$STOPS" >/dev/null; python3 -c '
import json,sys
recs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
last={}
for r in recs: last[r["key"]]=r
print(sum(1 for r in last.values() if r.get("state")=="open"))' "$STOPS")" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["stops"]))' "$LIVE")"
check "each stop has kind, sentence and action" "ok" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("ok" if all(s["kind"] and s["sentence"] and s["action"] for s in d["stops"]) else "missing")' "$LIVE")"
check "stops_meta counts" "ok" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); m=d["stops_meta"]; print("ok" if m["open"]==len(d["stops"]) and m["total"]>=m["open"] and m["source"] and "/" not in m["source"].strip("/").split("/")[0] else m)' "$LIVE")"
check "queue rows carry blocked and waiting keys" "ok" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("ok" if all("blocked" in q and "waiting" in q for q in d["queue"]) and "hold" in d["queue_meta"] else "missing")' "$LIVE")"
# a merged PR clears its stop on the next tick
echo '{"state":"MERGED","isDraft":false,"mergeStateStatus":"CLEAN"}' > "$GH_DIR/view-77.json"
tick >/dev/null
check "merged PR clears the stop" "cleared" "$(stop_field run-theta-1 state)"
check "the red check stop stays open" "open" "$(stop_field run-eta-red state)"
"$QUEUE" rm wave-plans/eta.plan >/dev/null
check "a plan gone from the queue clears its stop" "cleared" "$(tick >/dev/null; stop_field run-eta-red state)"

echo ""
echo "== 6. dry run writes nothing =="
plan iota "one branch." feat/alpha
ended_run run-iota-1 iota stream-alpha-landed.jsonl
echo pr-block-fix > "$GH_SCENARIO"
before_stops=$(wc -l < "$STOPS"); before_land=$(count . "$LAND_LOG"); before_log=$(wc -l < "$RUNNER_LOG")
out=$(dry); check "dry run exit" "0" "$?"
printf '%s\n' "$out" | grep -q "would write wave-plans/iota-fix1.plan and queue it"; check "dry run says what it would write" "0" "$?"
check_true "no fix plan written" test ! -f "$FLEET/wave-plans/iota-fix1.plan"
check_true "run not marked handled" test ! -f "$RUNS/run-iota-1.loop"
check "stops file unchanged" "$before_stops" "$(wc -l < "$STOPS")"
check "runner log unchanged" "$before_log" "$(wc -l < "$RUNNER_LOG")"
check "land.sh not called" "$before_land" "$(count . "$LAND_LOG")"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
