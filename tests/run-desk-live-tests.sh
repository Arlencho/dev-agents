#!/usr/bin/env bash
# Fleet Desk v2 Phase B — event stream + Ops Floor projection tests.
#
#   Part A: scripts/fleet-events.sh writer shape (JSONL, seq, types, redaction,
#           FLEET_EVENTS=0 opt-out, unwritable dir)
#   Part B: scripts/desk_live.py live/1 projection over synthetic fixtures
#           (tests/fixtures/fleet-events/*.jsonl)
#   Part C: scripts/dispatch.sh wiring guards (no task text ever emitted)
#
# Offline by design: nothing here binds a socket or touches the network.
#
# Law: docs/proposals/fleet-desk-v2-SYNTHESIS.md §3 Phase B
# Schema: docs/experience-data.md § Live event stream
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/fleet-events"
EMITTER="$REPO_DIR/scripts/fleet-events.sh"
DESK_LIVE="$REPO_DIR/scripts/desk_live.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# assert_py <name> <json file> <expression over d (+ helpers S, W, E)>
assert_py() {
  local name="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
S = {s["task_id"]: s for s in d.get("seats", [])}
W = d.get("waiting_on", [])
E = d.get("recent_events", [])
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then ok "$name"; else bad "$name"; fi
}

# assert_jsonl <name> <jsonl file> <expression over rows list L>
assert_jsonl() {
  local name="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json, sys
L = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        L.append(json.loads(line))   # a malformed line fails the test loudly
K = {}
for r in L:
    K.setdefault(r["event"], []).append(r)
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then ok "$name"; else bad "$name"; fi
}

echo "== Part A: event writer (scripts/fleet-events.sh) =="

[ -f "$EMITTER" ] && ok "emitter exists" || { bad "emitter exists"; exit 1; }

A_DIR="$TMP/events-a"
(
  set -euo pipefail
  # shellcheck source=scripts/fleet-events.sh
  . "$EMITTER"
  FLEET_EVENTS_DIR="$A_DIR"
  fleet_events_init "dev-agents" "wave" "/abs/path/to/phase-b.plan" "20260729-000000-test"
  fleet_event dispatch_plan waves=2 seats=3 format=wave
  fleet_event wave_start wave=1 seats=2 mode=wave
  fleet_event seat_dispatch task_id=0 agent=devops branch='feat/quote"and\back' \
      wave=1 provider=claude model=opus worker=mac-mini-1 attempt=1
  fleet_event ratecap task_id=0 agent=devops wave=1 provider=claude cooldown_minutes=60
  fleet_event failover task_id=0 agent=devops from_provider=claude to_provider=kimi attempt=2
  fleet_event seat_exit task_id=0 agent=devops branch=feat/x wave=1 provider=kimi \
      status=success exit=0 duration_s=42 attempt=2
  fleet_event human_wait kind=wave_gate wave=1 next_wave=2 waiting_on="merge PRs, then start wave 2"
  fleet_event seat_log task_id=0 agent=devops log=dev-agents-feat-x-20260729.log
  fleet_event dispatch_end status=completed total=3 succeeded=3 failed=0 duration_s=900
  # hostile values: control chars, newline, over-long string, bogus key
  fleet_event seat_note task_id=0 note="$(printf 'line1\nline2\ttab')" \
      BadKey=ignored empty= long="$(python3 -c 'print("x"*400)')"
) >/dev/null 2>&1

A_FILE="$A_DIR/20260729-000000-test.jsonl"
[ -f "$A_FILE" ] && ok "stream file created (<dispatch_id>.jsonl)" || bad "stream file created"
[ -f "$A_DIR/latest" ] && ok "latest pointer written" || bad "latest pointer written"
[ "$(cat "$A_DIR/latest")" = "20260729-000000-test.jsonl" ] \
  && ok "latest pointer holds the stream basename" || bad "latest pointer holds the stream basename"

assert_jsonl "every line is valid JSON with the base envelope" "$A_FILE" \
  'all(set(("schema","seq","ts","dispatch_id","event")) <= set(r) for r in L)'
assert_jsonl "schema is fleet-events/1" "$A_FILE" 'all(r["schema"]=="fleet-events/1" for r in L)'
assert_jsonl "seq is monotonic from 1" "$A_FILE" '[r["seq"] for r in L] == list(range(1,len(L)+1))'
assert_jsonl "ts is UTC ISO-8601 Z" "$A_FILE" \
  'all(len(r["ts"])==20 and r["ts"].endswith("Z") and r["ts"][10]=="T" for r in L)'
assert_jsonl "dispatch_start opens the stream" "$A_FILE" \
  'L[0]["event"]=="dispatch_start" and L[0]["mode"]=="wave" and L[0]["repo"]=="dev-agents"'
assert_jsonl "plan travels as a basename only" "$A_FILE" 'L[0]["plan"]=="phase-b.plan"'
assert_jsonl "seat_dispatch carries the redaction-safe fields" "$A_FILE" \
  'set(("task_id","agent","branch","provider","worker","wave")) <= set(K["seat_dispatch"][0])'
assert_jsonl "quotes and backslashes survive escaping" "$A_FILE" \
  'K["seat_dispatch"][0]["branch"] == chr(102)+"eat/quote\"and\\back"'
assert_jsonl "numeric keys are JSON numbers" "$A_FILE" \
  'isinstance(K["seat_exit"][0]["exit"], int) and isinstance(K["seat_exit"][0]["duration_s"], int) '\
'and isinstance(K["wave_start"][0]["wave"], int)'
assert_jsonl "task_id stays a string (never coerced)" "$A_FILE" \
  'isinstance(K["seat_dispatch"][0]["task_id"], str)'
assert_jsonl "ratecap names the provider" "$A_FILE" 'K["ratecap"][0]["provider"]=="claude"'
assert_jsonl "failover names both vendors" "$A_FILE" \
  'K["failover"][0]["from_provider"]=="claude" and K["failover"][0]["to_provider"]=="kimi"'
assert_jsonl "human_wait says what the fleet waits on" "$A_FILE" \
  '"waiting_on" in K["human_wait"][0] and K["human_wait"][0]["kind"]=="wave_gate"'
assert_jsonl "dispatch_end closes with counts" "$A_FILE" \
  'K["dispatch_end"][0]["status"]=="completed" and K["dispatch_end"][0]["succeeded"]==3'
assert_jsonl "newlines/tabs are flattened (one event per line)" "$A_FILE" \
  '"\n" not in K["seat_note"][0]["note"] and "\t" not in K["seat_note"][0]["note"]'
assert_jsonl "values are truncated at 200 chars" "$A_FILE" \
  'len(K["seat_note"][0]["long"])==200'
assert_jsonl "non-snake keys are dropped" "$A_FILE" '"BadKey" not in K["seat_note"][0]'
assert_jsonl "empty values are omitted, never emitted as \"\"" "$A_FILE" \
  '"empty" not in K["seat_note"][0]'

# Redaction: nothing resembling a home path or a token may reach the stream.
if grep -qE '/Users/|/home/|(sk|ghp|gho)_[A-Za-z0-9]{8,}' "$A_FILE"; then
  bad "no absolute paths or token-shaped strings in the stream"
else
  ok "no absolute paths or token-shaped strings in the stream"
fi

# Opt-out
B_DIR="$TMP/events-off"
(
  set -euo pipefail
  . "$EMITTER"
  FLEET_EVENTS=0 FLEET_EVENTS_DIR="$B_DIR" fleet_events_init "dev-agents" "wave" "plan.txt"
  FLEET_EVENTS=0 fleet_event wave_start wave=1
) >/dev/null 2>&1
if [ -d "$B_DIR" ] && ls "$B_DIR"/*.jsonl >/dev/null 2>&1; then
  bad "FLEET_EVENTS=0 writes nothing"
else
  ok "FLEET_EVENTS=0 writes nothing"
fi

# Unwritable target must degrade, not explode.
RO_DIR="$TMP/readonly"
mkdir -p "$RO_DIR" && chmod 555 "$RO_DIR"
if (
  set -euo pipefail
  . "$EMITTER"
  FLEET_EVENTS_DIR="$RO_DIR/nested" fleet_events_init "dev-agents" "wave" "plan.txt"
  fleet_event wave_start wave=1
  [ -z "${FLEET_EVENTS_FILE:-}" ]
) >/dev/null 2>&1; then
  ok "unwritable events dir disables the stream without failing the dispatch"
else
  bad "unwritable events dir disables the stream without failing the dispatch"
fi
chmod 755 "$RO_DIR"

# CLI mode (used by ops one-liners and by this suite)
C_DIR="$TMP/events-cli"
CLI_FILE="$(FLEET_EVENTS_DIR="$C_DIR" bash "$EMITTER" init dev-agents wave plan.txt 20260729-010101-cli)"
FLEET_EVENTS_FILE="$CLI_FILE" FLEET_DISPATCH_ID=20260729-010101-cli \
  bash "$EMITTER" emit wave_start wave=1 seats=2 mode=wave
assert_jsonl "CLI mode appends and continues the sequence" "$CLI_FILE" \
  'len(L)==2 and L[1]["event"]=="wave_start" and L[1]["seq"]==2'

echo ""
echo "== Part B: live/1 projection (scripts/desk_live.py) =="

[ -f "$DESK_LIVE" ] && ok "desk_live.py exists" || { bad "desk_live.py exists"; exit 1; }
python3 -c "import ast,sys; ast.parse(open('$DESK_LIVE').read())" \
  && ok "desk_live.py parses" || bad "desk_live.py parses"

# Fixture streams into a scratch events dir (+ latest pointer).
E_DIR="$TMP/events-fix"
mkdir -p "$E_DIR"
cp "$FIX/wave-run.jsonl" "$FIX/conductor-run.jsonl" "$E_DIR/"
echo "wave-run.jsonl" > "$E_DIR/latest"

OUT="$TMP/out/live.json"
python3 "$DESK_LIVE" --once --events-dir "$E_DIR" --out "$OUT" >/dev/null 2>&1 \
  && ok "--once exits 0 (no server, no network)" || bad "--once exits 0"
[ -f "$OUT" ] && ok "--once writes live.json" || { bad "--once writes live.json"; exit 1; }

assert_py "schema is live/1" "$OUT" 'd["schema"]=="live/1"'
assert_py "latest pointer selects the stream" "$OUT" 'd["dispatch_id"]=="20260729-100000-dev-agents"'
assert_py "source is a repo-relative path" "$OUT" \
  'd["source"].endswith("wave-run.jsonl") and not d["source"].startswith("/")'
assert_py "mode is wave" "$OUT" 'd["mode"]=="wave"'
assert_py "repo + plan carried from dispatch_start" "$OUT" \
  'd["repo"]=="dev-agents" and d["plan"]=="phase-b.plan"'
assert_py "status is running (no dispatch_end yet)" "$OUT" 'd["status"]=="running"'
assert_py "three seats projected" "$OUT" 'len(d["seats"])==3'
assert_py "settled seat keeps exit + duration" "$OUT" \
  'S["0"]["status"]=="success" and S["0"]["exit"]==0 and S["0"]["duration_s"]==718'
assert_py "retried seat shows the vendor it landed on" "$OUT" 'S["1"]["provider"]=="kimi"'
assert_py "failover recorded with both vendors" "$OUT" \
  'S["1"]["failovers"][0]["from"]=="claude" and S["1"]["failovers"][0]["to"]=="kimi"'
assert_py "providers_tried keeps the honest trail" "$OUT" \
  'S["1"]["providers_tried"]==["claude","kimi"]'
assert_py "ratecap flagged on the lane" "$OUT" 'S["1"]["ratecapped"] is True'
assert_py "wave 2 seat is in flight" "$OUT" \
  'S["2"]["status"]=="running" and S["2"]["wave"]==2 and S["2"]["pipeline"]=="in_flight"'
assert_py "pipeline counts add up" "$OUT" \
  'd["counts"]["settled"]==2 and d["counts"]["in_flight"]==1 and d["counts"]["total"]==3'
assert_py "wave position known" "$OUT" 'd["wave"]["current"]==2 and d["wave"]["total"]==2'
assert_py "resolved human gate is not still waiting" "$OUT" \
  'not any(w["kind"]=="human_gate" for w in W)'
assert_py "waiting_on falls back to the running seat" "$OUT" \
  'len(W)==1 and W[0]["kind"]=="seat" and W[0]["task_id"]=="2"'
assert_py "last_event_ts is the newest event" "$OUT" 'd["last_event_ts"]=="2026-07-29T10:20:02Z"'
assert_py "old stream reads offline, never live" "$OUT" 'd["staleness"]["state"]=="offline"'
assert_py "staleness thresholds are published" "$OUT" \
  'd["staleness"]["stale_after_s"]==120 and d["staleness"]["offline_after_s"]==900'
assert_py "recent_events tail is present" "$OUT" 'len(E)==16 and E[-1]["event"]=="seat_dispatch"'
assert_py "no live seats invented" "$OUT" 'all(s["agent"] for s in d["seats"])'

# Conductor stream: serial spine + an OPEN human gate.
OUT_C="$TMP/out/live-conductor.json"
python3 "$DESK_LIVE" --once --events-dir "$E_DIR" --dispatch-id conductor-run --out "$OUT_C" >/dev/null 2>&1
assert_py "--dispatch-id selects a specific run" "$OUT_C" \
  'd["dispatch_id"]=="20260729-120000-olympus-platform"'
assert_py "mode is conductor" "$OUT_C" 'd["mode"]=="conductor"'
assert_py "guardrail block is Blocked, not failed noise" "$OUT_C" \
  'S["0"]["status"]=="blocked" and S["0"]["exit"]==77 and S["0"]["pipeline"]=="blocked"'
assert_py "log travels as a filename only" "$OUT_C" \
  'S["0"]["log"]=="olympus-platform-feat-payments-svc-20260729-120002.log" and "/" not in S["0"]["log"]'
assert_py "open human gate is first-class in waiting_on" "$OUT_C" \
  'W[0]["kind"]=="human_gate" and W[0]["gate"]=="failure_gate" and W[0]["next_wave"]==2'
assert_py "gate label says what the human must do" "$OUT_C" '"continue after failed wave 1" in W[0]["label"]'

# Empty events dir → honest idle, not a crash.
OUT_E="$TMP/out/live-empty.json"
mkdir -p "$TMP/events-empty"
python3 "$DESK_LIVE" --once --events-dir "$TMP/events-empty" --out "$OUT_E" >/dev/null 2>&1 \
  && ok "empty events dir exits 0" || bad "empty events dir exits 0"
assert_py "empty dir projects idle with a teaching reason" "$OUT_E" \
  'd["status"]=="idle" and d["seats"]==[] and d["staleness"]["state"]=="none" and "dispatch" in d["reason"]'

# Fresh synthetic run → live chrome; a seat still "running" after dispatch_end
# must read unknown, never an eternal spinner.
F_DIR="$TMP/events-fresh"
mkdir -p "$F_DIR"
python3 - "$F_DIR/fresh.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc).replace(tzinfo=None)
def ts(delta):
    return (now - timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = [
    {"schema":"fleet-events/1","seq":1,"ts":ts(20),"dispatch_id":"fresh","event":"dispatch_start",
     "mode":"wave","repo":"dev-agents","plan":"p.plan"},
    {"schema":"fleet-events/1","seq":2,"ts":ts(19),"dispatch_id":"fresh","event":"wave_start",
     "wave":1,"seats":1,"mode":"wave"},
    {"schema":"fleet-events/1","seq":3,"ts":ts(18),"dispatch_id":"fresh","event":"seat_dispatch",
     "task_id":"0","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"mac-mini-1"},
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
    fh.write("this line is not json\n")
PY
OUT_F="$TMP/out/live-fresh.json"
python3 "$DESK_LIVE" --once --events-dir "$F_DIR" --out "$OUT_F" >/dev/null 2>&1
assert_py "fresh stream reads live" "$OUT_F" 'd["staleness"]["state"]=="live" and d["staleness"]["seconds"] < 120'
assert_py "running seat reports elapsed seconds" "$OUT_F" 'S["0"]["elapsed_s"] >= 0'
assert_py "malformed line is skipped with a warning" "$OUT_F" \
  'len(d["warnings"])==1 and "malformed" in d["warnings"][0]'

printf '{"schema":"fleet-events/1","seq":4,"ts":"%s","dispatch_id":"fresh","event":"dispatch_end","status":"aborted","total":1,"succeeded":0,"failed":1}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$F_DIR/fresh.jsonl"
python3 "$DESK_LIVE" --once --events-dir "$F_DIR" --out "$OUT_F" >/dev/null 2>&1
assert_py "aborted dispatch is reported as aborted" "$OUT_F" 'd["status"]=="aborted"'
assert_py "seat that never reported reads unknown, not running" "$OUT_F" \
  'S["0"]["status"]=="unknown"'

# The live projection must never leak machine paths or transcript prose.
if grep -qE '/Users/|/home/|(sk|ghp|gho)_[A-Za-z0-9]{8,}' "$OUT" "$OUT_C" "$OUT_F"; then
  bad "no absolute paths or token-shaped strings in live.json"
else
  ok "no absolute paths or token-shaped strings in live.json"
fi

# ── Mutation pins (critic loop 2: M5, M8, M9 survived the suite) ────────────

# M5: a stream with dispatch events but no seat events must project zero
# seats — never a fabricated one.
M5_DIR="$TMP/events-noseats"
mkdir -p "$M5_DIR"
python3 - "$M5_DIR/noseats.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc).replace(tzinfo=None)
def ts(delta):
    return (now - timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = [
    {"schema":"fleet-events/1","seq":1,"ts":ts(10),"dispatch_id":"noseats","event":"dispatch_start",
     "mode":"wave","repo":"dev-agents","plan":"p.plan"},
    {"schema":"fleet-events/1","seq":2,"ts":ts(9),"dispatch_id":"noseats","event":"wave_start",
     "wave":1,"seats":2,"mode":"wave"},
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
OUT_M5="$TMP/out/live-noseats.json"
python3 "$DESK_LIVE" --once --events-dir "$M5_DIR" --out "$OUT_M5" >/dev/null 2>&1
assert_py "events without seat events project zero seats — none fabricated" "$OUT_M5" \
  'd["seats"]==[] and d["status"]=="running" and d["wave"]["current"]==1'

# M8: a seat_log path is stripped to its basename — an absolute path never
# reaches live.json.
M8_DIR="$TMP/events-seatlog"
mkdir -p "$M8_DIR"
python3 - "$M8_DIR/seatlog.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc).replace(tzinfo=None)
def ts(delta):
    return (now - timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = [
    {"schema":"fleet-events/1","seq":1,"ts":ts(10),"dispatch_id":"seatlog","event":"dispatch_start",
     "mode":"wave","repo":"dev-agents","plan":"p.plan"},
    {"schema":"fleet-events/1","seq":2,"ts":ts(9),"dispatch_id":"seatlog","event":"seat_dispatch",
     "task_id":"0","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"mac-mini-1"},
    {"schema":"fleet-events/1","seq":3,"ts":ts(8),"dispatch_id":"seatlog","event":"seat_log",
     "task_id":"0","agent":"devops","log":"/Users/operator/logs/seat-0.log"},
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
OUT_M8="$TMP/out/live-seatlog.json"
python3 "$DESK_LIVE" --once --events-dir "$M8_DIR" --out "$OUT_M8" >/dev/null 2>&1
assert_py "seat_log projects as a basename, never an absolute path" "$OUT_M8" \
  'S["0"]["log"]=="seat-0.log"'

# M9: the latest pointer must stay inside the events dir — a pointer naming a
# path outside is ignored in favor of the newest in-dir stream.
M9_DIR="$TMP/events-m9"
mkdir -p "$M9_DIR"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-07-29T10:00:00Z","dispatch_id":"real-dispatch","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' \
  > "$M9_DIR/real.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-07-29T10:00:00Z","dispatch_id":"outside-dispatch","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' \
  > "$TMP/outside.jsonl"
printf '../outside.jsonl\n' > "$M9_DIR/latest"
OUT_M9="$TMP/out/live-m9.json"
python3 "$DESK_LIVE" --once --events-dir "$M9_DIR" --out "$OUT_M9" >/dev/null 2>&1
assert_py "latest pointer with a path separator is not followed outside the events dir" "$OUT_M9" \
  'd["dispatch_id"]=="real-dispatch"'

echo ""
echo "== Part C: dispatch.sh wiring =="

bash -n "$REPO_DIR/scripts/dispatch.sh" && ok "dispatch.sh parses" || bad "dispatch.sh parses"
grep -q 'fleet-events.sh' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "dispatch.sh sources the emitter" || bad "dispatch.sh sources the emitter"
# dispatch_start is emitted by fleet_events_init, the rest from dispatch.sh
# call sites — the pair must cover the whole Phase B vocabulary.
for ev in dispatch_start wave_start wave_end seat_dispatch seat_exit ratecap failover human_wait dispatch_end; do
  if grep -qE "fleet_event $ev" "$REPO_DIR/scripts/dispatch.sh" "$EMITTER"; then
    ok "dispatch.sh can emit $ev"
  else
    bad "dispatch.sh can emit $ev"
  fi
done
# Hard redaction guard: the task description must never reach an event.
if grep -n 'fleet_event' "$REPO_DIR/scripts/dispatch.sh" | grep -qE 'TASK_DESC|\$task|\$desc'; then
  bad "no task text is ever emitted"
else
  ok "no task text is ever emitted"
fi

# M1: the close-out must EXECUTE, not just grep. Replay every trap line
# dispatch.sh installs for fleet_close_dispatch into a harness shaped like the
# inter-wave gate (dispatch.sh `read -r answer`), then prove dispatch_end is
# written on (a) plain early exit and (b) Ctrl-C (SIGINT). Deleting any one of
# the trap lines turns this block RED.
CLOSE_TRAPS="$(grep -E '^trap .*fleet_close_dispatch' "$REPO_DIR/scripts/dispatch.sh" || true)"
[ -n "$CLOSE_TRAPS" ] \
  && ok "dispatch.sh installs close-out traps" \
  || bad "dispatch.sh installs close-out traps"

mk_closeout_harness() {  # $1 = harness body, run after the traps are installed
  cat > "$TMP/closeout-harness.sh" <<HARNESS
#!/usr/bin/env bash
set -uo pipefail
FLEET_DISPATCH_CLOSED=false
fleet_close_dispatch() {
    [ "\$FLEET_DISPATCH_CLOSED" = true ] && return 0
    FLEET_DISPATCH_CLOSED=true
    echo "dispatch_end status=\${1:-aborted}" >> "$TMP/closeout.log"
}
$CLOSE_TRAPS
$1
HARNESS
}

# (a) plain exit — kills the "delete the EXIT trap" mutation.
rm -f "$TMP/closeout.log"
mk_closeout_harness 'exit 3'
bash "$TMP/closeout-harness.sh" >/dev/null 2>&1 || true
if [ "$(grep -c 'dispatch_end status=aborted' "$TMP/closeout.log" 2>/dev/null)" = "1" ]; then
  ok "early exit runs the close-out exactly once (EXIT trap executes)"
else
  bad "early exit runs the close-out exactly once (EXIT trap executes)"
fi

# (b) SIGINT at the wave gate — the ordinary operator abort. The harness runs
# in the FOREGROUND on purpose: an async (&) child of a non-interactive shell
# inherits SIGINT as SIG_IGN and bash refuses to trap a signal that was
# ignored at entry (measured: `trap -p INT` -> `trap -- '' SIGINT`), so a
# backgrounded harness can never exercise an INT trap under make test/CI.
# The harness writes its own pid for the async killer ($BASHPID is empty
# under /bin/bash 3.2, so the subshell cannot name itself).
CLOSE_FIFO="$TMP/gate.fifo"; mkfifo "$CLOSE_FIFO"
rm -f "$TMP/closeout.log" "$TMP/closeout-harness.pid"
mk_closeout_harness "echo \$\$ > \"$TMP/closeout-harness.pid\"; read -r answer"
( for _ in $(seq 1 60); do [ -f "$TMP/closeout-harness.pid" ] && break; sleep 0.1; done
  sleep 0.3; kill -INT "$(cat "$TMP/closeout-harness.pid")" 2>/dev/null
  sleep 2;   kill -KILL "$(cat "$TMP/closeout-harness.pid")" 2>/dev/null ) >/dev/null 2>&1 &
bash "$TMP/closeout-harness.sh" <> "$CLOSE_FIFO" >/dev/null 2>&1 || true
if [ "$(grep -c 'dispatch_end status=aborted' "$TMP/closeout.log" 2>/dev/null)" = "1" ]; then
  ok "Ctrl-C (SIGINT) runs the close-out exactly once — the Floor stops showing running"
else
  bad "Ctrl-C (SIGINT) runs the close-out exactly once — the Floor stops showing running"
fi
rm -f "$CLOSE_FIFO"

# Wiring pin for the signal traps (execution above proves the close-out path;
# on macOS bash the EXIT trap also fires on fatal SIGINT, so execution alone
# cannot distinguish EXIT-only from EXIT+INT+TERM — this grep locks the
# deliberate wiring and its documented exit codes).
printf '%s\n' "$CLOSE_TRAPS" | grep -q 'INT' && printf '%s\n' "$CLOSE_TRAPS" | grep -q 'TERM' \
  && ok "dispatch.sh closes out on INT/TERM explicitly, not EXIT alone" \
  || bad "dispatch.sh closes out on INT/TERM explicitly, not EXIT alone"

grep -q 'FLEET_EVENTS' "$REPO_DIR/docs/experience-data.md" \
  && ok "event schema documented in docs/experience-data.md" \
  || bad "event schema documented in docs/experience-data.md"
grep -qE '^desk-live:' "$REPO_DIR/Makefile" && ok "make desk-live target exists" || bad "make desk-live target exists"
grep -qE '^experience-live:' "$REPO_DIR/Makefile" \
  && ok "make experience-live target exists" || bad "make experience-live target exists"

echo ""
echo "----------------------------------------"
echo "  passed: $pass   failed: $fail"
echo "----------------------------------------"
[ "$fail" -eq 0 ] || exit 1
