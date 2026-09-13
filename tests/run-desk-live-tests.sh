#!/usr/bin/env bash
# Fleet Desk v2 Phase B — event stream + Ops Floor projection tests.
#
#   Part A: scripts/fleet-events.sh writer shape (JSONL, seq, types, redaction,
#           FLEET_EVENTS=0 opt-out, unwritable dir)
#   Part B: scripts/desk_live.py live/1 projection over synthetic fixtures
#           (tests/fixtures/fleet-events/*.jsonl)
#   Part C: scripts/dispatch.sh wiring guards (no task text ever emitted)
#   Part G: scripts/seat-progress.py reader (pass-through, counts, redaction)
#   Part H: live-activity wiring (launcher stream, reader placement, Floor)
#   Part I: the plain sentence (issue 69): program-name reduction in the
#           reader (credential shapes redacted), seats[].now per live seat,
#           the top-line summary, today[].outcome
#   Part J: repo, issue, task line and PR on every seat (issue 72): the
#           parses, two repos live at once, the gh skip, verified, failing
#           and hanging paths (fake gh on PATH, no network)
#   Part L: yesterday and the push (Floor v3, wave C): the day before is
#           read the same way as today and marked so; notify.sh needs-you
#           sends one toast per NEEDS YOU item that waited N minutes, never
#           twice, and nothing at all with the env var unset
#   Part K: NEEDS YOU and INITIATIVES (Floor v3, wave A): one fixture with a
#           BLOCK comment, a SAFE plus CLEAN PR, a quiet seat, a failed
#           dispatch, a PROPOSED row and a missing variable; the six entries
#           with gh answering, the unverified marks with gh absent; round 2:
#           an offline stream with no close-out is no quiet seat, a verdict
#           quoted on the first line is no verdict, a variable gh could not
#           check is no item, a fallback initiative row carries every key
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
assert_py "wave 2 seat with no close-out on an offline stream reads unknown, never running" "$OUT" \
  'S["2"]["status"]=="unknown" and S["2"]["wave"]==2 and S["2"]["pipeline"]=="blocked"'
assert_py "pipeline counts add up" "$OUT" \
  'd["counts"]["settled"]==2 and d["counts"]["blocked"]==1 and d["counts"]["in_flight"]==0 and d["counts"]["total"]==3'
assert_py "wave position known" "$OUT" 'd["wave"]["current"]==2 and d["wave"]["total"]==2'
assert_py "resolved human gate is not still waiting" "$OUT" \
  'not any(w["kind"]=="human_gate" for w in W)'
assert_py "waiting_on names the quiet stream, never a seat the stream stopped reporting" "$OUT" \
  'any(w.get("kind")=="quiet_stream" for w in W) and not any(w.get("kind")=="seat" for w in W)'
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
  'any(w.get("kind")=="human_gate" and w.get("gate")=="failure_gate" and w.get("next_wave")==2 for w in W)'
assert_py "gate label says what the human must do" "$OUT_C" \
  'any(w.get("kind")=="human_gate" and "continue after failed wave 1" in (w.get("label") or "") for w in W)'

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

# Ops Floor queue wiring: the machine maintains logs/fleet-queue.json, so a
# dispatch must mark its plan running on the way in and settled on the way out.
grep -q 'fleet_queue start' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "dispatch.sh marks the plan running in the queue" \
  || bad "dispatch.sh marks the plan running in the queue"
grep -q 'fleet_queue settle' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "dispatch.sh settles the plan in the queue" \
  || bad "dispatch.sh settles the plan in the queue"
# Same redaction law on the queue path: purposes come from the plan header,
# never from a task body.
if grep -n 'fleet_queue' "$REPO_DIR/scripts/dispatch.sh" | grep -qE 'TASK_DESC|\$task|\$desc'; then
  bad "no task text ever reaches the queue"
else
  ok "no task text ever reaches the queue"
fi
# Queue bookkeeping is best effort: a missing queue.sh must not kill a dispatch.
if ( SCRIPT_DIR="$TMP/nonexistent"; eval "$(sed -n '/^fleet_queue() {/,/^}/p' "$REPO_DIR/scripts/dispatch.sh")"; fleet_queue start plan.plan ) >/dev/null 2>&1; then
  ok "fleet_queue survives a missing queue.sh (never blocks a dispatch)"
else
  bad "fleet_queue survives a missing queue.sh (never blocks a dispatch)"
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

# ── Part D: Phase C replay ─────────────────────────────────────────────
echo ""
echo "== Part D: Phase C replay (scrubber + REPLAY watermark) =="

SETTLED_DIR="$TMP/settled-events"
mkdir -p "$SETTLED_DIR"
# Stream filename must match dispatch_id (resolve_stream looks up <id>.jsonl).
cp "$FIX/settled-run.jsonl" "$SETTLED_DIR/20260729-180000-dev-agents.jsonl"
echo "20260729-180000-dev-agents.jsonl" > "$SETTLED_DIR/latest"

# Full settled projection (live view of a finished run — status settled, not necessarily replay)
python3 "$DESK_LIVE" --once --events-dir "$SETTLED_DIR" --out "$TMP/settled-full.json" \
  --dispatch-id 20260729-180000-dev-agents >/dev/null 2>&1
assert_py "settled full projects status settled" "$TMP/settled-full.json" \
  'd["status"]=="settled"'
assert_py "settled full default view is live (not auto-replay)" "$TMP/settled-full.json" \
  'd.get("view","live")=="live"'
assert_py "settled full has 2 seats" "$TMP/settled-full.json" \
  'len(d["seats"])==2'

# --as-of-seq mid-run: only first 4 events → 1 seat dispatch, no exits
python3 "$DESK_LIVE" --once --events-dir "$SETTLED_DIR" --out "$TMP/settled-mid.json" \
  --dispatch-id 20260729-180000-dev-agents --as-of-seq 4 >/dev/null 2>&1
assert_py "as_of_seq 4 sets view=replay" "$TMP/settled-mid.json" \
  'd["view"]=="replay"'
assert_py "as_of_seq 4 forces staleness.state=replay (never live)" "$TMP/settled-mid.json" \
  'd["staleness"]["state"]=="replay"'
assert_py "as_of_seq 4 watermark is REPLAY" "$TMP/settled-mid.json" \
  '(d.get("replay") or {}).get("watermark")=="REPLAY"'
assert_py "as_of_seq 4 keeps as_of_seq in replay block" "$TMP/settled-mid.json" \
  'd["replay"]["as_of_seq"]==4 and d["replay"]["total_events"]==9'
assert_py "as_of_seq 4 projects only early seats (1 dispatched, still running/unknown)" "$TMP/settled-mid.json" \
  'len(d["seats"])==1'
assert_py "as_of_seq 4 has fewer events_seen than full stream" "$TMP/settled-mid.json" \
  'd["events_seen"] < 9'

# --replay without as_of_seq: whole stream, watermarked
python3 "$DESK_LIVE" --once --events-dir "$SETTLED_DIR" --out "$TMP/settled-replay.json" \
  --dispatch-id 20260729-180000-dev-agents --replay >/dev/null 2>&1
assert_py "--replay stamps view=replay on full stream" "$TMP/settled-replay.json" \
  'd["view"]=="replay" and d["staleness"]["state"]=="replay"'
assert_py "--replay still projects all seats" "$TMP/settled-replay.json" \
  'len(d["seats"])==2 and d["counts"]["settled"]==2'

# list_runs catalog
python3 "$DESK_LIVE" --list-runs --events-dir "$SETTLED_DIR" > "$TMP/runs.json" 2>/dev/null
assert_py "list_runs schema fleet-runs/1" "$TMP/runs.json" \
  'd["schema"]=="fleet-runs/1" and isinstance(d["runs"], list)'
assert_py "list_runs marks settled run" "$TMP/runs.json" \
  'any(r.get("dispatch_id")=="20260729-180000-dev-agents" and r.get("settled") for r in d["runs"])'
assert_py "list_runs reports event count" "$TMP/runs.json" \
  'any(r.get("events")==9 for r in d["runs"])'

# truncate never invents seats past the cut
python3 "$DESK_LIVE" --once --events-dir "$SETTLED_DIR" --out "$TMP/settled-early.json" \
  --dispatch-id 20260729-180000-dev-agents --as-of-seq 2 >/dev/null 2>&1
assert_py "as_of_seq 2 has zero seats (only plan, no seat_dispatch)" "$TMP/settled-early.json" \
  'd["seats"]==[]'

# docs pin
grep -q 'REPLAY' "$REPO_DIR/docs/experience.md" \
  && ok "docs/experience.md documents REPLAY" \
  || bad "docs/experience.md documents REPLAY"
grep -q 'as_of_seq\|as-of-seq\|Phase C' "$REPO_DIR/docs/experience-data.md" \
  && ok "docs/experience-data.md documents Phase C replay fields" \
  || bad "docs/experience-data.md documents Phase C replay fields"
grep -q 'floor-watermark\|REPLAY\|replay' "$REPO_DIR/templates/experience/floor.js" \
  && ok "floor.js carries REPLAY scrubber chrome" \
  || bad "floor.js carries REPLAY scrubber chrome"
grep -q 'api/replay\|/api/runs' "$REPO_DIR/scripts/desk_live.py" \
  && ok "desk_live.py serves /api/runs and /api/replay" \
  || bad "desk_live.py serves /api/runs and /api/replay"

# ── Part E: follow live (quiet hang + fleet-session bridge) ───────────
echo ""
echo "== Part E: follow live (quiet_stream + fleet-session) =="

# Quiet hang: running seat, last event 200s ago → waiting_on quiet_stream
QUIET_DIR="$TMP/quiet-events"
mkdir -p "$QUIET_DIR"
python3 - "$QUIET_DIR/quiet-run.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta
path = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None)
old = now - timedelta(seconds=200)
def ts(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
did = "quiet-run"
rows = [
    {"schema":"fleet-events/1","seq":1,"ts":ts(old),"dispatch_id":did,"event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"quiet.plan"},
    {"schema":"fleet-events/1","seq":2,"ts":ts(old),"dispatch_id":did,"event":"wave_start","wave":1,"seats":1,"mode":"wave"},
    {"schema":"fleet-events/1","seq":3,"ts":ts(old),"dispatch_id":did,"event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/hang","wave":1,"provider":"claude","attempt":1},
]
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
echo "quiet-run.jsonl" > "$QUIET_DIR/latest"
python3 "$DESK_LIVE" --once --events-dir "$QUIET_DIR" --out "$TMP/quiet.json" \
  --dispatch-id quiet-run >/dev/null 2>&1
assert_py "quiet hang projects status running" "$TMP/quiet.json" \
  'd["status"]=="running"'
assert_py "quiet hang marks stream stale or offline" "$TMP/quiet.json" \
  'd["staleness"]["state"] in ("stale","offline")'
assert_py "quiet hang surfaces quiet_stream on waiting_on" "$TMP/quiet.json" \
  'any(w.get("kind")=="quiet_stream" for w in d.get("waiting_on") or [])'
assert_py "staleness publishes quiet_after_s" "$TMP/quiet.json" \
  'isinstance((d.get("staleness") or {}).get("quiet_after_s"), int)'

# fleet-session.sh run wraps a command and closes the stream
SESS_DIR="$TMP/session-events"
mkdir -p "$SESS_DIR"
FLEET_EVENTS_DIR="$SESS_DIR" bash "$REPO_DIR/scripts/fleet-session.sh" run \
  --label follow-test --repo dev-agents -- true >/dev/null 2>&1
sess_files="$(ls "$SESS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
[ "$sess_files" -ge 1 ] && ok "fleet-session run writes a jsonl stream" || bad "fleet-session run writes a jsonl stream"
python3 "$DESK_LIVE" --once --events-dir "$SESS_DIR" --out "$TMP/sess.json" >/dev/null 2>&1
assert_py "fleet-session settles the orchestrator seat" "$TMP/sess.json" \
  'd["status"]=="settled" and any(s.get("agent")=="orchestrator" for s in d.get("seats") or [])'
assert_py "fleet-session progress events appear in the tail" "$TMP/sess.json" \
  'any(e.get("event")=="progress" for e in d.get("recent_events") or [])'

grep -qE '^desk-follow:' "$REPO_DIR/Makefile" \
  && ok "make desk-follow target exists" || bad "make desk-follow target exists"
grep -q 'fleet-session' "$REPO_DIR/docs/experience.md" \
  && ok "docs/experience.md documents fleet-session follow path" \
  || bad "docs/experience.md documents fleet-session follow path"
grep -q 'quiet_stream\|QUIET' "$REPO_DIR/templates/experience/floor.js" \
  && ok "floor.js surfaces QUIET hang chrome" || bad "floor.js surfaces QUIET hang chrome"
test -x "$REPO_DIR/scripts/fleet-session.sh" \
  && ok "fleet-session.sh is executable" || bad "fleet-session.sh is executable"
grep -q 'seat_heartbeat' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "dispatch.sh emits seat_heartbeat while seats run" \
  || bad "dispatch.sh emits seat_heartbeat while seats run"
grep -q 'FLEET_HEARTBEAT_S' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "seat heartbeat interval is configurable (FLEET_HEARTBEAT_S)" \
  || bad "seat heartbeat interval is configurable (FLEET_HEARTBEAT_S)"
grep -q 'elapsed_s' "$REPO_DIR/scripts/fleet-events.sh" \
  && ok "fleet-events treats elapsed_s as numeric on heartbeats" \
  || bad "fleet-events treats elapsed_s as numeric on heartbeats"

echo ""
echo "== Part F: Ops Floor queue + day view =="

bash -n "$REPO_DIR/scripts/queue.sh" && ok "queue.sh parses" || bad "queue.sh parses"
test -x "$REPO_DIR/scripts/queue.sh" && ok "queue.sh is executable" || bad "queue.sh is executable"

Q_FILE="$TMP/fleet-queue.json"
QUEUE="$REPO_DIR/scripts/queue.sh"
PLAN_DIR="$TMP/plans"
mkdir -p "$PLAN_DIR"
cat > "$PLAN_DIR/alpha.plan" <<'PLAN'
# Alpha purpose taken from the plan header. Issue 1.
1 | devops | do the alpha thing | feat/alpha
PLAN
cat > "$PLAN_DIR/beta.plan" <<'PLAN'
# Beta purpose from the header.
1 | go-backend | do the beta thing | feat/beta
PLAN

FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" add "$PLAN_DIR/alpha.plan" olympus-platform >/dev/null 2>&1 \
  && ok "queue add exits 0" || bad "queue add exits 0"
FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" add "$PLAN_DIR/beta.plan" dev-agents "beta declared purpose" >/dev/null 2>&1
assert_py "queue file is fleet-queue/1 with both entries in order" "$Q_FILE" \
  'd["schema"]=="fleet-queue/1" and [e["plan"] for e in d["entries"]]==["alpha.plan","beta.plan"]'
assert_py "purpose defaults to the first comment line of the plan" "$Q_FILE" \
  'd["entries"][0]["purpose"].startswith("Alpha purpose taken from the plan header")'
assert_py "an explicit purpose wins over the header" "$Q_FILE" \
  'd["entries"][1]["purpose"]=="beta declared purpose"'

# The default purpose is the first PROSE line: a machine directive is not why a
# run exists, and the Floor prints this line as the reason (issue 69). Its own
# queue file, so the order the projection asserts below is untouched.
cat > "$PLAN_DIR/gamma.plan" <<'PLAN'
# DISPATCH: ./scripts/dispatch.sh git@example.invalid:x/y.git plan --auto
#
# Gamma purpose, the line a person would read out loud.
1 | devops | do the gamma thing | feat/gamma
PLAN
H_FILE="$TMP/fleet-queue-header.json"
FLEET_QUEUE_FILE="$H_FILE" "$QUEUE" add "$PLAN_DIR/gamma.plan" dev-agents >/dev/null 2>&1
assert_py "a machine directive is never the default purpose" "$H_FILE" \
  'd["entries"][0]["purpose"]=="Gamma purpose, the line a person would read out loud."'

FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" mv "$PLAN_DIR/beta.plan" 1 >/dev/null 2>&1
assert_py "mv reorders the queue" "$Q_FILE" \
  '[e["plan"] for e in d["entries"]]==["beta.plan","alpha.plan"]'
FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" start "$PLAN_DIR/alpha.plan" 20260912-090000-olympus-platform >/dev/null 2>&1
assert_py "start marks running with the dispatch id, keeping position" "$Q_FILE" \
  'd["entries"][1]["status"]=="running" and d["entries"][1]["dispatch_id"]=="20260912-090000-olympus-platform"'
FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" settle "$PLAN_DIR/alpha.plan" completed >/dev/null 2>&1
assert_py "settle records status and time" "$Q_FILE" \
  'd["entries"][1]["status"]=="settled" and d["entries"][1]["settled_status"]=="completed" and d["entries"][1]["settled_at"]'
if FLEET_QUEUE_FILE="$Q_FILE" "$QUEUE" rm "$PLAN_DIR/nope.plan" >/dev/null 2>&1; then
  bad "rm of an unknown plan reports failure"
else
  ok "rm of an unknown plan reports failure"
fi

# Crash safety: parallel writers must not lose an entry.
P_FILE="$TMP/fleet-queue-par.json"
for i in 1 2 3 4 5 6 7 8; do
  ( FLEET_QUEUE_FILE="$P_FILE" "$QUEUE" add "plan-$i.plan" "repo-$i" "purpose $i" >/dev/null 2>&1 ) &
done
wait
assert_py "8 concurrent adds keep 8 entries (lock + atomic rename)" "$P_FILE" \
  'len(d["entries"])==8 and len({e["plan"] for e in d["entries"]})==8'

# A malformed queue is refused, never overwritten.
BAD_FILE="$TMP/fleet-queue-bad.json"
printf '{ not json\n' > "$BAD_FILE"
if FLEET_QUEUE_FILE="$BAD_FILE" "$QUEUE" add x.plan r p >/dev/null 2>&1; then
  bad "malformed queue is refused"
else
  ok "malformed queue is refused"
fi
[ "$(cat "$BAD_FILE")" = "{ not json" ] \
  && ok "malformed queue is left untouched" || bad "malformed queue is left untouched"

# FLEET_QUEUE=0 writes nothing at all.
OPT_FILE="$TMP/fleet-queue-optout.json"
FLEET_QUEUE=0 FLEET_QUEUE_FILE="$OPT_FILE" "$QUEUE" add x.plan r p >/dev/null 2>&1
[ -f "$OPT_FILE" ] && bad "FLEET_QUEUE=0 writes nothing" || ok "FLEET_QUEUE=0 writes nothing"

# ── projection: queue[] + today[] over a multi-dispatch day ────────────────
DAY_DIR="$TMP/events-day"
mkdir -p "$DAY_DIR"
python3 - "$DAY_DIR" <<'DAYFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
# Never before local midnight: a landing stamped N seconds ago must still fall
# on today's local date when the suite runs just after midnight.
midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
midnight = midnight.astimezone(timezone.utc).replace(tzinfo=None)


def ts(delta_s):
    return max(now - timedelta(seconds=delta_s), midnight).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")


# landed today
write("day-landed.jsonl", [
    {"ts": ts(3000), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "alpha.plan"},
    {"ts": ts(2990), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/alpha", "wave": 1, "provider": "provider-a"},
    {"ts": ts(2400), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/alpha", "wave": 1, "status": "success", "exit": 0, "duration_s": 590},
    {"ts": ts(2395), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 1, "failed": 0, "duration_s": 605},
])
# live now (this is the followed run)
write("day-live-a.jsonl", [
    {"ts": ts(120), "event": "dispatch_start", "mode": "wave",
     "repo": "dev-agents", "plan": "beta.plan"},
    {"ts": ts(110), "event": "seat_dispatch", "task_id": "0", "agent": "go-backend",
     "branch": "feat/beta", "wave": 1, "provider": "provider-a"},
])
# live now (second, concurrent)
write("day-live-b.jsonl", [
    {"ts": ts(90), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "gamma.plan"},
    {"ts": ts(80), "event": "seat_dispatch", "task_id": "0", "agent": "web-frontend",
     "branch": "feat/gamma", "wave": 1, "provider": "provider-b"},
])
# an older run in the same directory: must not land in today[]
old = (now - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
write("day-old.jsonl", [
    {"ts": old, "event": "dispatch_start", "mode": "wave", "repo": "dev-agents", "plan": "old.plan"},
    {"ts": old, "event": "dispatch_end", "status": "completed", "total": 0, "succeeded": 0, "failed": 0},
])
DAYFIX
printf 'day-live-a.jsonl\n' > "$DAY_DIR/latest"

DAY_OUT="$TMP/out/live-day.json"
python3 "$DESK_LIVE" --once --events-dir "$DAY_DIR" --queue-file "$Q_FILE" --out "$DAY_OUT" >/dev/null 2>&1 \
  && ok "--once with a queue exits 0" || bad "--once with a queue exits 0"
assert_py "queue[] carries only queued entries, in order" "$DAY_OUT" \
  '[q["plan_basename"] for q in d["queue"]]==["beta.plan"] and d["queue"][0]["position"]==1'
assert_py "queue entries carry purpose and repo" "$DAY_OUT" \
  'd["queue"][0]["purpose"]=="beta declared purpose" and d["queue"][0]["repo"]=="dev-agents"'
assert_py "queue_meta publishes the newest added_at as the declaration time" "$DAY_OUT" \
  'd["queue_meta"]["declared"] is True and d["queue_meta"]["declared_at"] and d["queue_meta"]["total"]==2'
assert_py "a queued plan is never reported as running" "$DAY_OUT" \
  'all(q["status"]=="queued" for q in d["queue"])'
assert_py "today[] holds only dispatches that ended on the local day" "$DAY_OUT" \
  '[t["dispatch_id"] for t in d["today"]]==["day-landed"]'
assert_py "today entry carries status, duration and the branches created" "$DAY_OUT" \
  'd["today"][0]["status"]=="settled" and d["today"][0]["duration_s"]==605 and d["today"][0]["branches"]==["feat/alpha"]'
assert_py "today purpose comes from the queue when the plan is known" "$DAY_OUT" \
  'd["today"][0]["purpose"].startswith("Alpha purpose") and d["today"][0]["purpose_source"]=="queue"'
assert_py "every stream of the day is read, not only the newest" "$DAY_OUT" \
  'd["today_meta"]["streams_read"]==4 and sorted(d["today_meta"]["live"])==["day-live-a","day-live-b"]'
assert_py "concurrent live dispatches both show seats" "$DAY_OUT" \
  'sorted(s["dispatch_id"] for s in d["seats"])==["day-live-a","day-live-b"]'
assert_py "the followed run stays the subject of the page" "$DAY_OUT" \
  'd["dispatch_id"]=="day-live-a" and d["multi_dispatch"]["followed"]=="day-live-a" and d["multi_dispatch"]["merged_seats"]==1'
assert_py "merged seats are labelled as foreign to the followed run" "$DAY_OUT" \
  'all(s.get("foreign") is True for s in d["seats"] if s["dispatch_id"]!="day-live-a")'

# A malformed queue degrades to an empty queue plus a warning, never a crash.
BAD_OUT="$TMP/out/live-badqueue.json"
python3 "$DESK_LIVE" --once --events-dir "$DAY_DIR" --queue-file "$BAD_FILE" --out "$BAD_OUT" >/dev/null 2>&1 \
  && ok "a malformed queue still projects" || bad "a malformed queue still projects"
assert_py "malformed queue is an empty queue plus a warning" "$BAD_OUT" \
  'd["queue"]==[] and any("queue file" in w for w in d["warnings"])'

grep -q 'fleet-queue/1' "$REPO_DIR/docs/experience-data.md" \
  && ok "docs/experience-data.md documents the fleet-queue/1 schema" \
  || bad "docs/experience-data.md documents the fleet-queue/1 schema"
grep -q 'queue_meta' "$REPO_DIR/docs/experience-data.md" \
  && ok "docs/experience-data.md documents the new live.json fields" \
  || bad "docs/experience-data.md documents the new live.json fields"
for t in queue-add queue-list queue-rm; do
  grep -qE "^$t:.*## " "$REPO_DIR/Makefile" \
    && ok "make $t exists with help text" || bad "make $t exists with help text"
done
grep -q 'floor-queue-list' "$REPO_DIR/templates/experience/floor.js" \
  && ok "floor.js renders the Up next list" || bad "floor.js renders the Up next list"
grep -q 'floor-today-list' "$REPO_DIR/templates/experience/floor.js" \
  && ok "floor.js renders the Landed today list" || bad "floor.js renders the Landed today list"
grep -q 'floor-queue-list' "$REPO_DIR/scripts/experience_build.py" \
  && ok "the static Floor snapshot carries the same regions" \
  || bad "the static Floor snapshot carries the same regions"

# Replay must not carry today's queue into a historical scrub.
REPLAY_OUT="$TMP/out/live-replay-queue.json"
python3 "$DESK_LIVE" --once --events-dir "$DAY_DIR" --queue-file "$Q_FILE" \
  --dispatch-id day-landed --replay --out "$REPLAY_OUT" >/dev/null 2>&1
assert_py "replay carries no live queue or day view" "$REPLAY_OUT" \
  'd["view"]=="replay" and d["queue"]==[] and d["today"]==[]'

# ── the now view: purpose, one-line task, wave x of N, attempt, quiet ──────
NOW_PLAN="$PLAN_DIR/now.plan"
cat > "$NOW_PLAN" <<'PLAN'
# Now-view purpose taken from the plan header. Issue 4242.
#
# DISPATCH: ./scripts/dispatch.sh git@example.invalid:x/y.git plan --auto
1 | go-backend | Stand up the service boundary and nothing else. READ FIRST the contract in full, then the issue, then every route it touches, and do not stop there because this sentence keeps going well past any sensible length. | feat/now-a
2 | devops | Deploy it behind the edge. | feat/now-b
PLAN
NOW_Q="$TMP/now-queue.json"
python3 - "$NOW_Q" "$NOW_PLAN" <<'NOWQ'
import json, sys
json.dump({"schema": "fleet-queue/1", "updated_at": "2026-09-12T00:00:00Z",
           "entries": [{"plan": sys.argv[2], "repo": "olympus-platform",
                        "purpose": "declared purpose", "added_at": "2026-09-12T00:00:00Z",
                        "status": "running", "dispatch_id": "now-run",
                        "settled_at": None, "settled_status": None}]},
          open(sys.argv[1], "w"), indent=2)
NOWQ

NOW_DIR="$TMP/events-now"
mkdir -p "$NOW_DIR"
python3 - "$NOW_DIR" <<'NOWFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


def ts(d):
    return (now - timedelta(seconds=d)).strftime("%Y-%m-%dT%H:%M:%SZ")


rows = [
    {"ts": ts(600), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "now.plan"},
    {"ts": ts(599), "event": "dispatch_plan", "waves": 2, "seats": 2},
    {"ts": ts(598), "event": "wave_start", "wave": 1, "seats": 2, "mode": "wave"},
    # seat 0: heartbeat 10s ago, healthy
    {"ts": ts(590), "event": "seat_dispatch", "task_id": "0", "agent": "go-backend",
     "branch": "feat/now-a", "wave": 1, "provider": "claude", "model": "opus", "attempt": 2},
    {"ts": ts(10), "event": "seat_heartbeat", "task_id": "0", "agent": "go-backend",
     "branch": "feat/now-a", "wave": 1, "elapsed_s": 580},
    # seat 1: dispatched long ago, no heartbeat since, must read quiet
    {"ts": ts(585), "event": "seat_dispatch", "task_id": "1", "agent": "devops",
     "branch": "feat/now-b", "wave": 1, "provider": "kimi", "attempt": 1},
]
with open(os.path.join(out, "now-run.jsonl"), "w", encoding="utf-8") as fh:
    for i, row in enumerate(rows, 1):
        row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": "now-run"})
        fh.write(json.dumps(row) + "\n")
NOWFIX
printf 'now-run.jsonl\n' > "$NOW_DIR/latest"

NOW_OUT="$TMP/out/live-now.json"
python3 "$DESK_LIVE" --once --events-dir "$NOW_DIR" --queue-file "$NOW_Q" --out "$NOW_OUT" >/dev/null 2>&1 \
  && ok "--once projects the now view" || bad "--once projects the now view"
assert_py "a live seat carries the purpose of its plan" "$NOW_OUT" \
  'S["0"]["plan_purpose"].startswith("Now-view purpose taken from the plan header")'
assert_py "a live seat carries its task in one line, cut at 120 chars" "$NOW_OUT" \
  'len(S["0"]["task"])<=120 and S["0"]["task"].startswith("Stand up the service boundary")'
assert_py "the task is the first sentence, never the whole body" "$NOW_OUT" \
  '"READ FIRST" not in S["0"]["task"]'
assert_py "wave x of N comes from the plan wave count" "$NOW_OUT" \
  'S["0"]["wave"]==1 and S["0"]["wave_total"]==2'
assert_py "attempt number is projected" "$NOW_OUT" 'S["0"]["attempt"]==2'
assert_py "elapsed is measured from seat_dispatch" "$NOW_OUT" \
  'S["0"]["started_at"] and S["0"]["elapsed_s"]>=580'
assert_py "a heartbeat keeps a working seat out of quiet" "$NOW_OUT" \
  'S["0"]["last_heartbeat_ts"] and S["0"]["quiet"] is False and S["0"]["heartbeat_age_s"]<90'
assert_py "a seat with no sign of life past the threshold is quiet" "$NOW_OUT" \
  'S["1"]["quiet"] is True and S["1"]["last_heartbeat_ts"] is None and S["1"]["heartbeat_age_s"]>=90'
assert_py "plan context is published for the followed run" "$NOW_OUT" \
  'd["plan_context"]["waves"]==2 and d["plan_context"]["seats"]==2'
assert_py "a heartbeat never invents a seat" "$NOW_OUT" 'len(d["seats"])==2'

# An unresolvable plan degrades honestly: stream facts stay, nothing is guessed.
GONE_Q="$TMP/gone-queue.json"
python3 - "$GONE_Q" <<'GONEQ'
import json, sys
json.dump({"schema": "fleet-queue/1", "updated_at": None, "entries": []},
          open(sys.argv[1], "w"), indent=2)
GONEQ
GONE_OUT="$TMP/out/live-gone.json"
python3 "$DESK_LIVE" --once --events-dir "$NOW_DIR" --queue-file "$GONE_Q" --out "$GONE_OUT" >/dev/null 2>&1
assert_py "a plan that is not on this machine invents no task" "$GONE_OUT" \
  'S["0"]["task"] is None and S["0"]["plan_purpose"] is None and S["0"]["status"]=="running"'

grep -q 'data-elapsed-from' "$REPO_DIR/templates/experience/floor.js" \
  && ok "floor.js ticks elapsed from the seat_dispatch timestamp" \
  || bad "floor.js ticks elapsed from the seat_dispatch timestamp"
grep -q 'setInterval(tickElapsed, 1000)' "$REPO_DIR/templates/experience/floor.js" \
  && ok "elapsed updates every second in the browser" \
  || bad "elapsed updates every second in the browser"
grep -q 'floor-now-list' "$REPO_DIR/scripts/experience_build.py" \
  && ok "the static Floor snapshot carries the now view" \
  || bad "the static Floor snapshot carries the now view"
grep -q 'nowrow.quiet' "$REPO_DIR/templates/experience/site.css" \
  && ok "quiet seats use the watermark visual language" \
  || bad "quiet seats use the watermark visual language"

echo ""
echo "== Part G: seat activity (scripts/seat-progress.py) =="

READER="$REPO_DIR/scripts/seat-progress.py"
[ -f "$READER" ] && ok "stream reader exists" || bad "stream reader exists"

# A synthetic agent stream: prose, five tool calls (one inside the repo, one
# write, one file outside the repo, one test command, one commit), one result.
# Every secret-shaped string is tagged LEAKCANARY: none may reach the stream.
R_REPO="$TMP/reader-repo"
mkdir -p "$R_REPO/scripts"
R_IN="$TMP/reader-in.jsonl"
cat > "$R_IN" <<'STREAM'
{"type":"system","subtype":"init","cwd":"/private/tmp/x","tools":["Bash"]}
{"type":"assistant","message":{"content":[{"type":"text","text":"LEAKCANARY-PROSE"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"scripts/desk_live.py"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"scripts/new.py","content":"LEAKCANARY-BODY"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/etc/hosts"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo LEAKCANARY-TOKEN && ./tests/run-desk-live-tests.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git commit -m LEAKCANARY-MESSAGE"}}]}}
not json at all, the log keeps it
{"type":"result","subtype":"success","is_error":false,"result":"LEAKCANARY-RESULT"}
STREAM

R_EVENTS="$TMP/events-reader"
mkdir -p "$R_EVENTS"
R_FILE="$R_EVENTS/20260101-000000-reader.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-01-01T00:00:00Z","dispatch_id":"20260101-000000-reader","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' > "$R_FILE"
printf '%s\n' '{"schema":"fleet-events/1","seq":2,"ts":"2026-01-01T00:00:01Z","dispatch_id":"20260101-000000-reader","event":"seat_dispatch","task_id":"7","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","model":"opus","worker":"localhost","attempt":1}' >> "$R_FILE"
printf '%s\n' '20260101-000000-reader.jsonl' > "$R_EVENTS/latest"

R_OUT="$TMP/reader-out.jsonl"
FLEET_EVENTS_SH="$EMITTER" FLEET_EVENTS_FILE="$R_FILE" \
  FLEET_DISPATCH_ID="20260101-000000-reader" \
  SEAT_TASK_ID=7 SEAT_AGENT=devops SEAT_REPO_DIR="$R_REPO" \
  SEAT_PROGRESS_INTERVAL_S=999 \
  python3 "$READER" < "$R_IN" > "$R_OUT" 2>/dev/null
R_RC=$?
[ "$R_RC" -eq 0 ] && ok "reader exits 0 (telemetry never fails a dispatch)" \
  || bad "reader exits 0 (telemetry never fails a dispatch)"
if cmp -s "$R_IN" "$R_OUT"; then
  ok "the stream passes through byte for byte (the agent log loses nothing)"
else
  bad "the stream passes through byte for byte (the agent log loses nothing)"
fi

# Only progress rows were added, and they carry the four counts + the phase.
assert_jsonl "seat_progress reaches the stream through the existing emitter" "$R_FILE" \
  'len(K.get("seat_progress",[]))>=6'
assert_jsonl "progress names the seat it belongs to" "$R_FILE" \
  'all(r["task_id"]=="7" and r["agent"]=="devops" for r in K["seat_progress"])'
assert_jsonl "counts are JSON numbers, folded from the whole stream" "$R_FILE" \
  'K["seat_progress"][-1]["files_edited"]==1 and K["seat_progress"][-1]["commands_run"]==2 '\
'and K["seat_progress"][-1]["tests_run"]==1 and K["seat_progress"][-1]["commits_made"]==1'
assert_jsonl "the phase ladder ends on committing" "$R_FILE" \
  'K["seat_progress"][-1]["phase"]=="committing"'
assert_jsonl "the first progress event says reading before any tool ran" "$R_FILE" \
  'K["seat_progress"][0]["phase"]=="reading"'
assert_jsonl "a repo file travels as a repo-relative path" "$R_FILE" \
  'any(r.get("path")=="scripts/desk_live.py" for r in K["seat_progress"])'
assert_jsonl "a file outside the repo travels as the literal marker" "$R_FILE" \
  'any(r.get("path")=="outside-repo" for r in K["seat_progress"]) '\
'and not any("/etc/hosts" in str(r.get("path")) for r in K["seat_progress"])'
assert_jsonl "tool names travel, nothing else from the call" "$R_FILE" \
  'set(r.get("tool") for r in K["seat_progress"] if r.get("tool"))=={"Read","Write","Bash"}'
# The hard one: no prose, no argument value, no command line, ever.
if grep -q "LEAKCANARY" "$R_FILE"; then
  bad "no prompt, message, argument or command line reaches the stream"
else
  ok "no prompt, message, argument or command line reaches the stream"
fi
if grep -qE '"(command|content|text|thinking|input|prompt|task)"' "$R_FILE"; then
  bad "progress events carry no transcript-shaped keys"
else
  ok "progress events carry no transcript-shaped keys"
fi

# No emitter env: a plain pass-through, no crash, nothing written anywhere.
R_OUT2="$TMP/reader-out-bare.jsonl"
( unset FLEET_EVENTS_SH FLEET_EVENTS_FILE; python3 "$READER" < "$R_IN" > "$R_OUT2" 2>/dev/null )
R_RC2=$?
if [ "$R_RC2" -eq 0 ] && cmp -s "$R_IN" "$R_OUT2"; then
  ok "without the emitter env the reader is a plain pass-through"
else
  bad "without the emitter env the reader is a plain pass-through"
fi

# Projection: the newest progress lands on the seat as activity.
OUT_R="$TMP/out/live-reader.json"
python3 "$DESK_LIVE" --once --events-dir "$R_EVENTS" --out "$OUT_R" >/dev/null 2>&1
assert_py "the newest seat_progress projects onto the seat as activity" "$OUT_R" \
  'S["7"]["activity"]["phase"]=="committing" and S["7"]["activity"]["tool"]=="Bash" '\
'and S["7"]["activity"]["commits_made"]==1'
assert_py "a seat with no progress reports activity as null" "$OUT_R" \
  'all(s["activity"] is None for s in d["seats"] if s["task_id"]!="7")'

# Progress never invents a lane, and never renders an operator path.
R2_DIR="$TMP/events-reader2"
mkdir -p "$R2_DIR"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-01-01T00:00:00Z","dispatch_id":"r2","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' > "$R2_DIR/r2.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":2,"ts":"2026-01-01T00:00:02Z","dispatch_id":"r2","event":"seat_progress","task_id":"9","agent":"devops","phase":"editing","tool":"Edit","path":"/Users/someone/secret/plan.md","files_edited":3,"commands_run":0,"tests_run":0,"commits_made":0}' >> "$R2_DIR/r2.jsonl"
OUT_R2="$TMP/out/live-reader2.json"
python3 "$DESK_LIVE" --once --events-dir "$R2_DIR" --out "$OUT_R2" >/dev/null 2>&1
assert_py "seat_progress never creates a seat the stream did not dispatch" "$OUT_R2" \
  'not d["seats"]'

# Same absolute path, this time on a seat the stream did dispatch: the seat
# object the Floor renders must carry the marker, never the operator path.
R3_DIR="$TMP/events-reader3"
mkdir -p "$R3_DIR"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-01-01T00:00:00Z","dispatch_id":"r3","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' > "$R3_DIR/r3.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":2,"ts":"2026-01-01T00:00:01Z","dispatch_id":"r3","event":"seat_dispatch","task_id":"9","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"localhost","attempt":1}' >> "$R3_DIR/r3.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":3,"ts":"2026-01-01T00:00:02Z","dispatch_id":"r3","event":"seat_progress","task_id":"9","agent":"devops","phase":"editing","tool":"Edit","path":"/Users/someone/secret/plan.md","files_edited":3,"commands_run":0,"tests_run":0,"commits_made":0}' >> "$R3_DIR/r3.jsonl"
OUT_R3="$TMP/out/live-reader3.json"
python3 "$DESK_LIVE" --once --events-dir "$R3_DIR" --out "$OUT_R3" >/dev/null 2>&1
assert_py "the projector re-marks an absolute progress path as outside-repo" "$OUT_R3" \
  'S["9"]["activity"]["path"]=="outside-repo" and S["9"]["activity"]["phase"]=="editing"'

# Replay: the two writers share no seq space, so a scrub must cut the reader's
# lines on time. Progress at 00:00:09 must not show at a scrub of the spine's
# seq 2 (00:00:01).
R4_DIR="$TMP/events-reader4"
mkdir -p "$R4_DIR"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-01-01T00:00:00Z","dispatch_id":"r4","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' > "$R4_DIR/r4.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":2,"ts":"2026-01-01T00:00:01Z","dispatch_id":"r4","event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"localhost","attempt":1}' >> "$R4_DIR/r4.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":3,"ts":"2026-01-01T00:00:09Z","dispatch_id":"r4","event":"seat_progress","task_id":"0","agent":"devops","phase":"editing","tool":"Edit","path":"a.py","files_edited":1,"commands_run":0,"tests_run":0,"commits_made":0}' >> "$R4_DIR/r4.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":3,"ts":"2026-01-01T00:00:20Z","dispatch_id":"r4","event":"seat_exit","task_id":"0","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"localhost","status":"success","exit":0,"duration_s":19,"attempt":1}' >> "$R4_DIR/r4.jsonl"
OUT_R4="$TMP/out/live-reader4.json"
python3 "$DESK_LIVE" --once --events-dir "$R4_DIR" --as-of-seq 2 --out "$OUT_R4" >/dev/null 2>&1
assert_py "a replay scrub shows no activity from after the scrub point" "$OUT_R4" \
  'S["0"]["status"]=="running" and S["0"]["activity"] is None'
OUT_R5="$TMP/out/live-reader5.json"
python3 "$DESK_LIVE" --once --events-dir "$R4_DIR" --as-of-seq 3 --out "$OUT_R5" >/dev/null 2>&1
assert_py "a full scrub keeps the activity the stream recorded" "$OUT_R5" \
  'S["0"]["activity"]["files_edited"]==1'

echo ""
echo "== Part H: live-activity wiring =="

bash -n "$REPO_DIR/providers/lib.sh" && ok "providers/lib.sh parses" || bad "providers/lib.sh parses"
bash -n "$REPO_DIR/providers/claude/launch.sh" && ok "the launcher parses" || bad "the launcher parses"
# Streamed print output is what makes the log grow during a run at all.
grep -q -- '--output-format stream-json' "$REPO_DIR/providers/claude/launch.sh" \
  && ok "the launcher streams its output as JSON lines" \
  || bad "the launcher streams its output as JSON lines"
# The reader must sit BEFORE the tee, so the log keeps the raw stream, and the
# vendor CLI must stay PIPESTATUS[0], so rate-cap classification is unchanged.
grep -q 'reader\[@\]}" | tee "\$tmp"' "$REPO_DIR/providers/lib.sh" \
  && ok "the reader sits between the CLI and the log tee" \
  || bad "the reader sits between the CLI and the log tee"
grep -q 'cmd_exit="\${PIPESTATUS\[0\]}"' "$REPO_DIR/providers/lib.sh" \
  && ok "the vendor CLI stays PIPESTATUS[0] (exit + rate-cap intact)" \
  || bad "the vendor CLI stays PIPESTATUS[0] (exit + rate-cap intact)"
grep -q 'seat-progress.py' "$REPO_DIR/scripts/run-remote.sh" \
  && ok "run-remote ships the reader to the worker" \
  || bad "run-remote ships the reader to the worker"
grep -q 'AGENT_TASK_ID' "$REPO_DIR/scripts/dispatch.sh" \
  && ok "dispatch passes the seat id down to the reader" \
  || bad "dispatch passes the seat id down to the reader"
grep -q 'nowact' "$REPO_DIR/templates/experience/floor.js" \
  && ok "the Floor renders the activity line under a live seat" \
  || bad "the Floor renders the activity line under a live seat"
grep -q 'nowact' "$REPO_DIR/templates/experience/site.css" \
  && ok "the activity line has the pipeline-language pill" \
  || bad "the activity line has the pipeline-language pill"
grep -q '_live_activity_line' "$REPO_DIR/scripts/experience_build.py" \
  && ok "the static Floor snapshot carries the same activity line" \
  || bad "the static Floor snapshot carries the same activity line"
grep -q 'seat_progress' "$REPO_DIR/docs/experience-data.md" \
  && ok "seat_progress is documented in the data contract" \
  || bad "seat_progress is documented in the data contract"

echo ""
echo "== Part I: the plain sentence (program name, seats[].now, summary) =="

# ── the token reduction, straight on the reader's own function ─────────────
# assert_program <name> <command> <expected|NONE>
assert_program() {
  local name="$1" command="$2" expected="$3"
  if python3 - "$READER" "$command" "$expected" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("seat_progress", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
got = mod.program_name(sys.argv[2])
want = None if sys.argv[3] == "NONE" else sys.argv[3]
if got != want:
    sys.stderr.write("program_name(%r) = %r, expected %r\n" % (sys.argv[2], got, want))
    sys.exit(1)
PY
  then ok "$name"; else bad "$name"; fi
}

assert_program "a plain program reduces to itself" "make test" "make"
assert_program "an env assignment is not the program" "FOO=bar BAZ=1 make test" "make"
assert_program "sudo, nohup and time are wrappers, not programs" \
  "sudo nohup time systemctl restart nginx" "systemctl"
assert_program "a path reduces to its basename" "/usr/local/bin/python3 -m pytest" "python3"
assert_program "a repo-relative path reduces to its basename too" \
  "./scripts/deploy.sh --prod" "deploy.sh"
assert_program "an operator path leaves only the basename" \
  "/Users/someone/secret/tool.sh run" "tool.sh"
assert_program "an option is never published as a program" "sudo -u deploy ./x.sh" "NONE"
assert_program "an unparseable command publishes nothing" "echo 'unbalanced" "NONE"
assert_program "an empty command publishes nothing" "   " "NONE"
assert_program "a token-shaped basename is written as the literal redacted" \
  "sudo /Users/someone/.ssh/ghp_abcdefghijklmnopqrstuvwxyz012345" "redacted"
assert_program "an api-key-shaped basename is redacted too" \
  "./sk-abcdefghijklmnopqrstuvwxyz --verify" "redacted"
assert_program "a long token is redacted whole, never truncated to a prefix" \
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c" "redacted"

# ── end to end: the program reaches the stream, its arguments never do ────
P_REPO="$TMP/program-repo"
mkdir -p "$P_REPO"
P_IN="$TMP/program-in.jsonl"
cat > "$P_IN" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"FOO=LEAKCANARY-ENV sudo /usr/local/bin/deploy.sh --token LEAKCANARY-ARG"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"make LEAKCANARY-TARGET"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/Users/someone/.ssh/ghp_LEAKCANARYabcdefghijklmnopqrstuv"}}]}}
STREAM
P_EVENTS="$TMP/events-program"
mkdir -p "$P_EVENTS"
P_FILE="$P_EVENTS/20260101-000000-program.jsonl"
printf '%s\n' '{"schema":"fleet-events/1","seq":1,"ts":"2026-01-01T00:00:00Z","dispatch_id":"20260101-000000-program","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"p.plan"}' > "$P_FILE"
printf '%s\n' '{"schema":"fleet-events/1","seq":2,"ts":"2026-01-01T00:00:01Z","dispatch_id":"20260101-000000-program","event":"seat_dispatch","task_id":"3","agent":"devops","branch":"feat/x","wave":1,"provider":"local","worker":"localhost","attempt":1}' >> "$P_FILE"
FLEET_EVENTS_SH="$EMITTER" FLEET_EVENTS_FILE="$P_FILE" \
  FLEET_DISPATCH_ID="20260101-000000-program" \
  SEAT_TASK_ID=3 SEAT_AGENT=devops SEAT_REPO_DIR="$P_REPO" \
  SEAT_PROGRESS_INTERVAL_S=999 \
  python3 "$READER" < "$P_IN" > /dev/null 2>/dev/null \
  && ok "the reader still exits 0 with program names on" \
  || bad "the reader still exits 0 with program names on"
assert_jsonl "the program name of the last shell command travels" "$P_FILE" \
  '[r.get("program") for r in K["seat_progress"]][:3]==["deploy.sh","make","redacted"]'
if grep -q "LEAKCANARY" "$P_FILE"; then
  bad "no env value, argument or absolute path travels with the program"
else
  ok "no env value, argument or absolute path travels with the program"
fi

# ── the sentence and the top line, over one day of real-shaped streams ────
I_PLAN="$PLAN_DIR/floor.plan"
cat > "$I_PLAN" <<'PLAN'
# DISPATCH: ./scripts/dispatch.sh git@example.invalid:x/y.git plan --auto
# Make the Floor readable without a legend. Issue 69.
1 | devops | Project the sentence. | feat/floor-a
2 | web-frontend | Draw the sentence. | feat/floor-b
3 | devops | Prove it with real streams. | feat/floor-c
PLAN
I_HEADER_PLAN="$PLAN_DIR/header-only.plan"
cat > "$I_HEADER_PLAN" <<'PLAN'
# Purpose that only the plan file knows. Issue 69.
1 | devops | Do the thing. | feat/header-a
PLAN

I_Q="$TMP/floor-queue.json"
python3 - "$I_Q" "$I_PLAN" "$I_HEADER_PLAN" <<'IQ'
import json, sys
out, plan, header_plan = sys.argv[1], sys.argv[2], sys.argv[3]
def entry(p, status, purpose, dispatch_id=None):
    return {"plan": p, "repo": "olympus-platform", "purpose": purpose,
            "added_at": "2026-09-12T00:00:00Z", "status": status,
            "dispatch_id": dispatch_id, "settled_at": None, "settled_status": None}
json.dump({"schema": "fleet-queue/1", "updated_at": "2026-09-12T00:00:00Z", "entries": [
    entry(plan, "running", "Make the Floor readable without a legend. Issue 69.", "floor-a"),
    entry(header_plan, "running", "", "floor-b"),
    entry("next-one.plan", "queued", "First up next."),
    entry("next-two.plan", "queued", "Second up next."),
]}, open(out, "w"), indent=2)
IQ

I_DIR="$TMP/events-floor"
mkdir -p "$I_DIR"
python3 - "$I_DIR" <<'IFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
# Never before local midnight: a landing stamped N seconds ago must still fall
# on today's local date when the suite runs just after midnight.
midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
midnight = midnight.astimezone(timezone.utc).replace(tzinfo=None)


def ts(d):
    return max(now - timedelta(seconds=d), midnight).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")


# one dispatch that ended today
write("floor-landed.jsonl", [
    {"ts": ts(400), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "floor.plan"},
    {"ts": ts(390), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/landed", "wave": 1, "provider": "local"},
    {"ts": ts(130), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/landed", "wave": 1, "status": "success", "exit": 0, "duration_s": 260},
    {"ts": ts(120), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 1, "failed": 0, "duration_s": 280},
])
# a run that died by itself: the seat failed, the dispatcher's exit trap closed it
write("floor-failed.jsonl", [
    {"ts": ts(700), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "floor.plan"},
    {"ts": ts(690), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/failed", "wave": 1, "provider": "local"},
    {"ts": ts(300), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/failed", "wave": 1, "status": "failed", "exit": 1, "duration_s": 390},
    {"ts": ts(299), "event": "dispatch_end", "status": "aborted",
     "total": 1, "succeeded": 0, "failed": 1},
])
# a run the operator stopped: a seat still in flight when the close-out came
write("floor-aborted.jsonl", [
    {"ts": ts(600), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "floor.plan"},
    {"ts": ts(590), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/aborted", "wave": 1, "provider": "local"},
    {"ts": ts(400), "event": "dispatch_end", "status": "aborted",
     "total": 1, "succeeded": 0, "failed": 0, "duration_s": 200},
])
# a run that reached the normal close-out with one seat failed
write("floor-completed-fail.jsonl", [
    {"ts": ts(560), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "floor.plan"},
    {"ts": ts(550), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/cf-a", "wave": 1, "provider": "local"},
    {"ts": ts(549), "event": "seat_dispatch", "task_id": "1", "agent": "devops",
     "branch": "feat/cf-b", "wave": 1, "provider": "local"},
    {"ts": ts(500), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/cf-a", "wave": 1, "status": "success", "exit": 0, "duration_s": 50},
    {"ts": ts(480), "event": "seat_exit", "task_id": "1", "agent": "devops",
     "branch": "feat/cf-b", "wave": 1, "status": "failed", "exit": 2, "duration_s": 69},
    {"ts": ts(470), "event": "dispatch_end", "status": "completed",
     "total": 2, "succeeded": 1, "failed": 1, "duration_s": 90},
])
# the followed run: one seat running with activity, one seat already settled
write("floor-a.jsonl", [
    {"ts": ts(900), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "floor.plan"},
    {"ts": ts(899), "event": "dispatch_plan", "waves": 3, "seats": 3},
    {"ts": ts(898), "event": "wave_start", "wave": 2, "seats": 2, "mode": "wave"},
    {"ts": ts(890), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-a", "wave": 2, "provider": "local", "model": "local", "attempt": 1},
    {"ts": ts(880), "event": "seat_dispatch", "task_id": "1", "agent": "web-frontend",
     "branch": "feat/floor-b", "wave": 2, "provider": "local", "attempt": 1},
    {"ts": ts(300), "event": "seat_exit", "task_id": "1", "agent": "web-frontend",
     "branch": "feat/floor-b", "wave": 2, "status": "success", "exit": 0, "duration_s": 580},
    {"ts": ts(20), "event": "seat_progress", "task_id": "0", "agent": "devops",
     "phase": "testing", "tool": "Bash", "path": "tests/run-desk-live-tests.sh",
     "program": "make", "files_edited": 2, "commands_run": 9, "tests_run": 1,
     "commits_made": 0},
    {"ts": ts(10), "event": "seat_heartbeat", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-a", "wave": 2, "elapsed_s": 880},
])
# a second live dispatch, on the plan whose queue purpose is empty
write("floor-b.jsonl", [
    {"ts": ts(200), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "header-only.plan"},
    {"ts": ts(190), "event": "seat_dispatch", "task_id": "5", "agent": "devops",
     "branch": "feat/header-a", "wave": 1, "provider": "local", "attempt": 1},
])
IFIX
printf 'floor-a.jsonl\n' > "$I_DIR/latest"

I_OUT="$TMP/out/live-floor.json"
python3 "$DESK_LIVE" --once --events-dir "$I_DIR" --queue-file "$I_Q" --out "$I_OUT" >/dev/null 2>&1 \
  && ok "--once projects the sentence and the top line" \
  || bad "--once projects the sentence and the top line"

assert_py "summary counts the seats running right now, across live dispatches" "$I_OUT" \
  'd["summary"]["running"]==2'
assert_py "summary counts the plans declared queued" "$I_OUT" 'd["summary"]["queued"]==2'
assert_py "summary counts the dispatches that landed today" "$I_OUT" \
  'd["summary"]["landed_today"]==4'
assert_py "summary carries the last event timestamp, never a precomputed age" "$I_OUT" \
  'isinstance(d["summary"]["last_event_ts"], str) '\
'and d["summary"]["last_event_ts"]==d["last_event_ts"] and "last_event_age_s" not in d["summary"]'
assert_py "the summary counts agree with the blocks they summarise" "$I_OUT" \
  'd["summary"]["queued"]==len(d["queue"]) and d["summary"]["landed_today"]==len(d["today"]) '\
'and d["summary"]["running"]==len([s for s in d["seats"] if s["status"]=="running"])'

assert_py "a live seat carries role, phase and program in one object" "$I_OUT" \
  'S["0"]["now"]["role"]=="devops" and S["0"]["now"]["phase"]=="testing" '\
'and S["0"]["now"]["program"]=="make"'
assert_py "the sentence takes its purpose from the queue entry" "$I_OUT" \
  'S["0"]["now"]["purpose"].startswith("Make the Floor readable") '\
'and S["0"]["now"]["purpose_source"]=="queue"'
assert_py "the sentence says wave x of N, N from the plan file" "$I_OUT" \
  'S["0"]["now"]["wave"]==2 and S["0"]["now"]["wave_total"]==3'
assert_py "the sentence carries elapsed and the age of the last sign of life" "$I_OUT" \
  'S["0"]["now"]["elapsed_s"]>=880 and S["0"]["now"]["heartbeat_age_s"]<90'
assert_py "the purpose falls back to the plan header when the queue has none" "$I_OUT" \
  'S["5"]["now"]["purpose"].startswith("Purpose that only the plan file knows") '\
'and S["5"]["now"]["purpose_source"]=="plan"'
assert_py "a machine directive is never published as a purpose" "$I_OUT" \
  'all("DISPATCH" not in (s["now"]["purpose"] or "") for s in d["seats"] if s["now"])'
assert_py "a seat that is not running has no sentence" "$I_OUT" \
  'S["1"]["status"]=="success" and S["1"]["now"] is None'
assert_py "the sentence never carries an absolute path" "$I_OUT" \
  'all(not str(s["now"]).count("/Users/") for s in d["seats"] if s["now"])'

# The outcome word: derived from the seat exits and the close-out, one per run.
assert_py "today names the outcome landed when every seat succeeded" "$I_OUT" \
  '{t["dispatch_id"]: t["outcome"] for t in d["today"]}["floor-landed"]=="landed"'
assert_py "a seat failure that ended the run by itself reads failed, not aborted" "$I_OUT" \
  '{t["dispatch_id"]: t["outcome"] for t in d["today"]}["floor-failed"]=="failed"'
assert_py "a completed close-out with a failure counted reads failed" "$I_OUT" \
  '{t["dispatch_id"]: t["outcome"] for t in d["today"]}["floor-completed-fail"]=="failed"'
assert_py "a run stopped with a seat still in flight reads aborted" "$I_OUT" \
  '{t["dispatch_id"]: t["outcome"] for t in d["today"]}["floor-aborted"]=="aborted"'
assert_py "today keeps status beside outcome for compatibility" "$I_OUT" \
  '{t["dispatch_id"]: t["status"] for t in d["today"]}=={"floor-landed":"settled",'\
'"floor-failed":"aborted","floor-aborted":"aborted","floor-completed-fail":"settled"}'

# A replay has no present tense: no summary, no sentence.
I_REPLAY="$TMP/out/live-floor-replay.json"
python3 "$DESK_LIVE" --once --events-dir "$I_DIR" --queue-file "$I_Q" \
  --dispatch-id floor-a --replay --out "$I_REPLAY" >/dev/null 2>&1
assert_py "a replay carries neither summary nor sentence" "$I_REPLAY" \
  'd["view"]=="replay" and d["summary"] is None '\
'and all(s["now"] is None for s in d["seats"])'
# mark_replay walks the seats itself, so a caller that attached now first
# cannot leak a present-tense sentence into a historical scrub.
if python3 - "$DESK_LIVE" "$I_OUT" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("desk_live", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
proj = json.load(open(sys.argv[2]))
assert any(s["now"] for s in proj["seats"]), "fixture has no live sentence"
mod.mark_replay(proj, 5, 5)
sys.exit(0 if proj["summary"] is None and all(s["now"] is None for s in proj["seats"]) else 1)
PY
then ok "mark_replay clears every seat's sentence itself"; else bad "mark_replay clears every seat's sentence itself"; fi

# An idle desk still answers the header question honestly.
I_EMPTY="$TMP/events-empty-floor"
mkdir -p "$I_EMPTY"
I_IDLE="$TMP/out/live-floor-idle.json"
python3 "$DESK_LIVE" --once --events-dir "$I_EMPTY" --queue-file "$I_Q" --out "$I_IDLE" >/dev/null 2>&1
assert_py "an idle desk reports 0 running, the queue it has, and no age" "$I_IDLE" \
  'd["status"]=="idle" and d["summary"]["running"]==0 and d["summary"]["queued"]==2 '\
'and d["summary"]["landed_today"]==0 and d["summary"]["last_event_ts"] is None'

grep -q 'program name of the last shell command' "$REPO_DIR/docs/experience-data.md" \
  && ok "the program name is documented in the event envelope" \
  || bad "the program name is documented in the event envelope"
grep -q 'landed_today' "$REPO_DIR/docs/experience-data.md" \
  && ok "the summary object is documented in the live schema" \
  || bad "the summary object is documented in the live schema"
grep -q 'seats\[\].now' "$REPO_DIR/docs/experience-data.md" \
  && ok "the per-seat sentence is documented in the live schema" \
  || bad "the per-seat sentence is documented in the live schema"
echo ""
echo "== Part J: repo, issue, task line and PR on every seat (issue 72) =="

# ── the parses, straight on the projector's own functions ──────────────────
# assert_fn <name> <python expression over mod (desk_live)>
assert_fn() {
  local name="$1" expr="$2"
  if python3 - "$DESK_LIVE" "$expr" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("desk_live", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.exit(0 if eval(sys.argv[2], {"mod": mod}) else 1)
PY
  then ok "$name"; else bad "$name"; fi
}

assert_fn "parse_issue reads Issue NNNN from a header line" \
  'mod.parse_issue("Make the Floor readable without a legend. Issue 72.") == 72'
assert_fn "parse_issue accepts a hash and any case" \
  'mod.parse_issue("issue #2799: the consent screen") == 2799'
assert_fn "parse_issue ignores bare numbers and words that only contain issue" \
  'mod.parse_issue("Fix 404 pages, reissue 55 tokens, PR 70") is None'
assert_fn "parse_issue is None for nothing" \
  'mod.parse_issue(None) is None and mod.parse_issue("") is None'
assert_fn "the task line is the first sentence only" \
  'mod.first_sentence("Project the sentence. Then the body, with /Users/someone/secret.") == "Project the sentence."'
assert_fn "the task line is cut at 120 characters" \
  'len(mod.first_sentence("word " * 80)) <= 120'
assert_fn "the task line passes the same secret scrub as the program token" \
  '"ghp_" not in mod.first_sentence("Push with ghp_abcdefghijklmnopqrstuvwxyz0123456789 now. Then more.") '\
'and "[redacted]" in mod.first_sentence("Push with ghp_abcdefghijklmnopqrstuvwxyz0123456789 now. Then more.")'
# The three inputs from the PR 74 review: a home path never reaches the page,
# and a short opener never lets the rest of the body through.
assert_fn "review input 1: token redacted and home path marked in a long first sentence" \
  'mod.first_sentence("Push with ghp_abcdefghijklmnopqrstuvwxyz0123456789 and write /Users/arlenrios/.ssh/id_rsa now.") '\
'== "Push with [redacted] and write outside-repo now."'
assert_fn "review input 2: a short opener is cut at its own full stop" \
  'mod.first_sentence("Go. Then leak ghp_abcdefghijklmnopqrstuvwxyz0123456789 and /Users/arlenrios/.ssh/id_rsa onto the Floor.") == "Go."'
assert_fn "review input 3: the first sentence only, the path in the body never read" \
  'mod.first_sentence("Project the sentence. Then the body, with /Users/someone/secret.") == "Project the sentence."'
assert_fn "a path inside this worktree is kept, repo-relative" \
  'mod.first_sentence("Edit scripts/desk_live.py and " + mod.REPO_DIR + "/docs/experience-data.md.") '\
'== "Edit scripts/desk_live.py and docs/experience-data.md."'
assert_fn "a home, variable or parent-escaping path reads outside-repo" \
  'mod.first_sentence("Read ~/.ssh/config, $HOME/.netrc and ../other/secret") == "Read outside-repo, outside-repo and outside-repo"'
assert_fn "a branch slug survives, a file URL does not" \
  'mod.first_sentence("Push feat/floor-context to origin/main (see file:///Users/x/y).") == "Push feat/floor-context to origin/main (see outside-repo)."'
assert_fn "no sentence end: cut at exactly 120 characters" \
  'len(mod.first_sentence("word " * 80)) == 120'

# ── two repos live at once, over real-shaped streams ──────────────────────
J_PLANS="$TMP/plans-72"
mkdir -p "$J_PLANS"
cat > "$J_PLANS/floor-context.plan" <<'PLAN'
# DISPATCH: ./scripts/dispatch.sh git@example.invalid:x/y.git plan --auto
# Floor: repo-first seats with issue, milestone, task line and PR. Issue 72.
1 | devops | Project repo, issue and PR onto every seat. Never publish this second sentence, nor /Users/someone/secret. | feat/floor-context
PLAN
cat > "$J_PLANS/iris-scaffold.plan" <<'PLAN'
# Assistant Channel W2-A: the Iris service, scaffold and edge. Issue 2800.
1 | go-backend | Scaffold the Iris service, pushing with ghp_abcdefghijklmnopqrstuvwxyz0123456789 when asked. Second sentence. | feat/iris-scaffold
1 | go-backend | Wire the edge. | feat/iris-edge
PLAN

J_Q="$TMP/queue-72.json"
python3 - "$J_Q" "$J_PLANS" <<'JQ'
import json, sys
out, plans = sys.argv[1], sys.argv[2]
def entry(plan, repo, status, purpose, issue=None, dispatch_id=None):
    return {"plan": plan, "repo": repo, "purpose": purpose, "issue": issue,
            "added_at": "2026-09-12T00:00:00Z", "status": status,
            "dispatch_id": dispatch_id, "settled_at": None, "settled_status": None}
json.dump({"schema": "fleet-queue/1", "updated_at": "2026-09-12T00:00:00Z", "entries": [
    entry(plans + "/floor-context.plan", "dev-agents", "running", "", None, "j-a"),
    entry(plans + "/iris-scaffold.plan", "olympus-platform", "running", "", None, "j-b"),
    # a queued plan that is not on this machine: the header line queue.sh stored is all there is
    entry("w1c-tile.plan", "olympus-platform", "queued",
          "Assistant Channel W1-C: the consent screen. Issue 2799."),
    # a queued plan whose header names no issue at all
    entry("no-issue.plan", "olympus-platform", "queued", "A plan without a requirement."),
]}, open(out, "w"), indent=2)
JQ

J_DIR="$TMP/events-72"
mkdir -p "$J_DIR"
python3 - "$J_DIR" <<'JFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone
out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
# Never before local midnight: a landing stamped N seconds ago must still fall
# on today's local date when the suite runs just after midnight.
midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
midnight = midnight.astimezone(timezone.utc).replace(tzinfo=None)
def ts(d):
    return max(now - timedelta(seconds=d), midnight).strftime("%Y-%m-%dT%H:%M:%SZ")
def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")
# the followed run: dev-agents, one seat live
write("j-a.jsonl", [
    {"ts": ts(600), "event": "dispatch_start", "mode": "wave", "repo": "dev-agents",
     "plan": "floor-context.plan"},
    {"ts": ts(590), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-context", "wave": 1, "provider": "local", "attempt": 1},
    {"ts": ts(10), "event": "seat_heartbeat", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-context", "wave": 1, "elapsed_s": 580},
])
# a second repo live at the same time, two seats
write("j-b.jsonl", [
    {"ts": ts(300), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform",
     "plan": "iris-scaffold.plan"},
    # task ids 5 and 6: the test helper S is keyed by task_id, so the two
    # dispatches must not collide on "0"
    {"ts": ts(290), "event": "seat_dispatch", "task_id": "5", "agent": "go-backend",
     "branch": "feat/iris-scaffold", "wave": 1, "provider": "local", "attempt": 1},
    {"ts": ts(280), "event": "seat_dispatch", "task_id": "6", "agent": "go-backend",
     "branch": "feat/iris-edge", "wave": 1, "provider": "local", "attempt": 1},
])
# a dev-agents run that landed today on the same branch
write("j-landed.jsonl", [
    {"ts": ts(2000), "event": "dispatch_start", "mode": "wave", "repo": "dev-agents",
     "plan": "floor-context.plan"},
    {"ts": ts(1990), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-context", "wave": 1, "provider": "local"},
    {"ts": ts(1500), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/floor-context", "wave": 1, "status": "success", "exit": 0, "duration_s": 490},
    {"ts": ts(1490), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 1, "failed": 0, "duration_s": 510},
])
JFIX
printf 'j-a.jsonl\n' > "$J_DIR/latest"

# The skip path: gh disabled. Every field still exists and says it was skipped.
J_OFF="$TMP/out/live-72-off.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --events-dir "$J_DIR" --queue-file "$J_Q" --out "$J_OFF" >/dev/null 2>&1 \
  && ok "--once exits 0 with gh disabled" || bad "--once exits 0 with gh disabled"
assert_py "every seat carries repo, issue, task_line and pr" "$J_OFF" \
  'all(all(k in s for k in ("repo","issue","task_line","pr")) for s in d["seats"]) and len(d["seats"])==3'
assert_py "the followed seat carries its repo, the foreign seats carry theirs" "$J_OFF" \
  '[s["repo"] for s in d["seats"]]==["dev-agents","olympus-platform","olympus-platform"]'
assert_py "the projector follows every live dispatch of the day" "$J_OFF" \
  'sorted(d["today_meta"]["live"])==["j-a","j-b"] and d["multi_dispatch"]["merged_seats"]==2'
assert_py "the issue number comes from the plan header line that names it" "$J_OFF" \
  'S["0"]["issue"]["number"]==72 and S["0"]["issue"]["source"]=="plan"'
assert_py "a skipped lookup says so, with the reason, and no milestone" "$J_OFF" \
  'S["0"]["issue"]["lookup"]=="skipped" and "disabled" in S["0"]["issue"]["reason"] '\
'and S["0"]["issue"]["milestone"] is None and S["0"]["pr"]["lookup"]=="skipped"'
assert_py "task_line is the first sentence of the seat line, nothing more" "$J_OFF" \
  'S["0"]["task_line"]=="Project repo, issue and PR onto every seat."'
assert_py "task_line never carries a secret shape" "$J_OFF" \
  '[s for s in d["seats"] if s["branch"]=="feat/iris-scaffold"][0]["task_line"].count("[redacted]")==1 '\
'and not any("ghp_" in json.dumps(s) for s in d["seats"])'
assert_py "task_line is cut at 120 characters" "$J_OFF" \
  'all(len(s["task_line"] or "")<=120 for s in d["seats"])'
# Replay: a historical seat still carries repo, issue, task_line and pr (the
# plan on disk explains it), while summary, repos and now stay empty.
J_REPLAY="$TMP/out/live-72-replay.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --replay --dispatch-id j-a --events-dir "$J_DIR" --queue-file "$J_Q" --out "$J_REPLAY" >/dev/null 2>&1 \
  && ok "--once --replay exits 0" || bad "--once --replay exits 0"
assert_py "a replay seat keeps issue, task_line and pr as the schema says" "$J_REPLAY" \
  'd["view"]=="replay" and S["0"]["repo"]=="dev-agents" and S["0"]["issue"]["number"]==72 '\
'and S["0"]["task_line"]=="Project repo, issue and PR onto every seat." and S["0"]["pr"]["branch"]=="feat/floor-context"'
assert_py "a replay still carries no summary, no repos and no now" "$J_REPLAY" \
  'd["summary"] is None and d["repos"]==[] and all(s["now"] is None for s in d["seats"])'

# A dispatch that crossed local midnight: no dispatch_end, started yesterday,
# a heartbeat 30 s ago. Still in motion, so still followed and counted; one
# from before yesterday is not. (Without the heartbeat the stream would be
# offline and its seat would read unknown: Part K covers that.)
J_NIGHT="$TMP/events-72-night"
mkdir -p "$J_NIGHT"
cp "$J_DIR"/*.jsonl "$J_DIR/latest" "$J_NIGHT/"
python3 - "$J_NIGHT" <<'JNIGHT'
import json, os, sys
from datetime import datetime, timedelta, timezone
out = sys.argv[1]
local_now = datetime.now().astimezone()
def noon_utc(days_ago):
    local = (local_now - timedelta(days=days_ago)).replace(hour=12, minute=0, second=0, microsecond=0)
    return local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def ago(seconds):
    return (local_now - timedelta(seconds=seconds)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")
write("j-overnight.jsonl", [
    {"ts": noon_utc(1), "event": "dispatch_start", "mode": "wave", "repo": "other-repo",
     "plan": "overnight.plan"},
    {"ts": noon_utc(1), "event": "seat_dispatch", "task_id": "9", "agent": "devops",
     "branch": "feat/overnight", "wave": 1, "provider": "local", "attempt": 1},
    {"ts": ago(30), "event": "seat_heartbeat", "task_id": "9", "agent": "devops", "elapsed_s": 86370},
])
write("j-stale.jsonl", [
    {"ts": noon_utc(3), "event": "dispatch_start", "mode": "wave", "repo": "other-repo",
     "plan": "stale.plan"},
    {"ts": noon_utc(3), "event": "seat_dispatch", "task_id": "8", "agent": "devops",
     "branch": "feat/stale", "wave": 1, "provider": "local", "attempt": 1},
])
JNIGHT
J_NIGHT_OUT="$TMP/out/live-72-night.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --dispatch-id j-a --events-dir "$J_NIGHT" --queue-file "$J_Q" --out "$J_NIGHT_OUT" >/dev/null 2>&1 \
  && ok "--once exits 0 with an overnight dispatch on disk" || bad "--once exits 0 with an overnight dispatch on disk"
assert_py "a dispatch that crossed local midnight is still followed" "$J_NIGHT_OUT" \
  'sorted(d["today_meta"]["live"])==["j-a","j-b","j-overnight"] and S["9"]["repo"]=="other-repo" and S["9"]["foreign"] is True'
assert_py "the overnight seat is counted in summary and in its own repo bucket" "$J_NIGHT_OUT" \
  'd["summary"]["running"]==4 and {r["repo"]: (r["seats_live"], r["dispatches_live"]) for r in d["repos"]}["other-repo"]==(1,1)'
assert_py "a stream with no end from before yesterday is not live" "$J_NIGHT_OUT" \
  '"j-stale" not in d["today_meta"]["live"] and "8" not in S'

assert_py "a queue entry names its issue from the stored header line when the plan is gone" "$J_OFF" \
  '{q["plan_basename"]: q["issue"]["number"] for q in d["queue"]}=={"w1c-tile.plan":2799,"no-issue.plan":None} '\
'and d["queue"][0]["issue"]["source"]=="queue"'
assert_py "a plan that names no issue says so rather than guessing" "$J_OFF" \
  'd["queue"][1]["issue"]["source"]=="none" and "names an issue" in d["queue"][1]["issue"]["reason"]'
assert_py "a landing carries repo first and a pr object per branch" "$J_OFF" \
  'd["today"][0]["repo"]=="dev-agents" and d["today"][0]["pr"]["branch"]=="feat/floor-context" '\
'and len(d["today"][0]["prs"])==1'
assert_py "repos[] carries seats live and dispatches live per repo" "$J_OFF" \
  '{r["repo"]: (r["seats_live"], r["dispatches_live"], r["queued"], r["landed_today"]) for r in d["repos"]}'\
'=={"olympus-platform": (2,1,2,0), "dev-agents": (1,1,0,1)}'
assert_py "repos[] adds up to the global summary from #70" "$J_OFF" \
  'sum(r["seats_live"] for r in d["repos"])==d["summary"]["running"]==3 '\
'and sum(r["queued"] for r in d["repos"])==d["summary"]["queued"] '\
'and sum(r["landed_today"] for r in d["repos"])==d["summary"]["landed_today"]'
assert_py "gh_enrichment reports disabled and no call was made" "$J_OFF" \
  'd["gh_enrichment"]["status"]=="disabled" and d["gh_enrichment"]["calls"]==0'
if grep -q '/Users/' "$J_OFF"; then
  bad "no operator path reaches the projection through the task line"
else
  ok "no operator path reaches the projection through the task line"
fi

# The verified path: a fake gh on PATH answers, so no network is touched.
J_BIN="$TMP/bin-72"
mkdir -p "$J_BIN"
J_LOG="$TMP/gh-72.log"
cat > "$J_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# Fake gh for the desk tests: records every call, answers from canned data.
echo "$*" >> "${GH_SHIM_LOG:?}"
[ "${GH_SHIM_MODE:-ok}" = "slow" ] && sleep 3
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue view")
    [ "${GH_SHIM_MODE:-ok}" = "ok" ] || exit 1
    printf '{"number":%s,"milestone":{"title":"Milestone from shim %s"}}\n' "$3" "$3" ;;
  "pr list")
    [ "${GH_SHIM_MODE:-ok}" = "ok" ] || exit 1
    branch=""; prev=""
    for a in "$@"; do [ "$prev" = "--head" ] && branch="$a"; prev="$a"; done
    if [ "$branch" = "feat/floor-context" ]; then
      printf '[{"number":73,"title":"Floor context data half","state":"OPEN","url":"https://example.invalid/pr/73"}]\n'
    else
      printf '[]\n'
    fi ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$J_BIN/gh"

J_ON="$TMP/out/live-72-on.json"
: > "$J_LOG"
PATH="$J_BIN:$PATH" GH_SHIM_LOG="$J_LOG" FLEET_GH_OWNER=testowner \
  python3 "$DESK_LIVE" --once --events-dir "$J_DIR" --queue-file "$J_Q" --out "$J_ON" >/dev/null 2>&1 \
  && ok "--once exits 0 with gh answering" || bad "--once exits 0 with gh answering"
assert_py "a verified issue carries the milestone title from gh" "$J_ON" \
  'S["0"]["issue"]["lookup"]=="verified" and S["0"]["issue"]["milestone"]=="Milestone from shim 72"'
assert_py "a verified PR carries number, title and state for the seat branch" "$J_ON" \
  'S["0"]["pr"]["number"]==73 and S["0"]["pr"]["title"]=="Floor context data half" '\
'and S["0"]["pr"]["state"]=="open" and S["0"]["pr"]["lookup"]=="verified"'
assert_py "a verified absence reads as no PR, not as a guess" "$J_ON" \
  '[s for s in d["seats"] if s["branch"]=="feat/iris-edge"][0]["pr"]["lookup"]=="verified" '\
'and [s for s in d["seats"] if s["branch"]=="feat/iris-edge"][0]["pr"]["number"] is None'
assert_py "the landing carries the PR of its branch" "$J_ON" \
  'd["today"][0]["pr"]["number"]==73'
assert_py "the queue entry off a stored header line is verified through gh too" "$J_ON" \
  'd["queue"][0]["issue"]["number"]==2799 and d["queue"][0]["issue"]["milestone"]=="Milestone from shim 2799"'
assert_py "gh_enrichment reports ok with the owner used" "$J_ON" \
  'd["gh_enrichment"]["status"]=="ok" and d["gh_enrichment"]["owner"]=="testowner"'
grep -q -- '-R testowner/olympus-platform' "$J_LOG" && grep -q -- '-R testowner/dev-agents' "$J_LOG" \
  && ok "each lookup goes to the slug of its own repo" \
  || bad "each lookup goes to the slug of its own repo"
[ "$(grep -c 'issue view 2800' "$J_LOG")" = "1" ] \
  && ok "one question per run: the same issue is fetched once" \
  || bad "one question per run: the same issue is fetched once"
[ "$(grep -c 'auth status' "$J_LOG")" = "1" ] \
  && ok "gh auth is probed once per run" || bad "gh auth is probed once per run"

# gh that fails: never fatal, every lookup says skipped and why.
J_FAIL="$TMP/out/live-72-fail.json"
: > "$J_LOG"
PATH="$J_BIN:$PATH" GH_SHIM_LOG="$J_LOG" GH_SHIM_MODE=fail FLEET_GH_OWNER=testowner \
  python3 "$DESK_LIVE" --once --events-dir "$J_DIR" --queue-file "$J_Q" --out "$J_FAIL" >/dev/null 2>&1 \
  && ok "--once exits 0 when gh fails" || bad "--once exits 0 when gh fails"
assert_py "a failed lookup is skipped with the failure as reason, number kept" "$J_FAIL" \
  'S["0"]["issue"]["lookup"]=="skipped" and "failed" in S["0"]["issue"]["reason"] '\
'and S["0"]["issue"]["number"]==72 and S["0"]["pr"]["lookup"]=="skipped"'

# gh that hangs: the per-call timeout bounds it, the projection still lands.
J_SLOW="$TMP/out/live-72-slow.json"
: > "$J_LOG"
PATH="$J_BIN:$PATH" GH_SHIM_LOG="$J_LOG" GH_SHIM_MODE=slow FLEET_GH_OWNER=testowner FLEET_GH_TIMEOUT_S=0.5 \
  python3 "$DESK_LIVE" --once --events-dir "$J_DIR" --queue-file "$J_Q" --out "$J_SLOW" >/dev/null 2>&1 \
  && ok "--once exits 0 when gh hangs" || bad "--once exits 0 when gh hangs"
assert_py "a hung gh reads as unauthenticated with a timeout reason, never blocking" "$J_SLOW" \
  'd["gh_enrichment"]["status"]=="unauthenticated" and "timed out" in d["gh_enrichment"]["reason"] '\
'and S["0"]["issue"]["lookup"]=="skipped" and "timed out" in S["0"]["issue"]["reason"] and d["summary"]["running"]==3'

# A replay has no repos block: the past has no present.
J_REPLAY="$TMP/out/live-72-replay.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --events-dir "$J_DIR" --queue-file "$J_Q" \
  --dispatch-id j-a --replay --out "$J_REPLAY" >/dev/null 2>&1
assert_py "a replay carries no repos block and still names the repo on its seats" "$J_REPLAY" \
  'd["view"]=="replay" and d["repos"]==[] and S["0"]["repo"]=="dev-agents"'

# ── queue.sh stores the issue it parsed, so a gone plan still names it ─────
JQ_FILE="$TMP/queue-72-store.json"
FLEET_QUEUE_FILE="$JQ_FILE" "$QUEUE" add "$J_PLANS/floor-context.plan" dev-agents >/dev/null 2>&1
FLEET_QUEUE_FILE="$JQ_FILE" "$QUEUE" add "$J_PLANS/missing.plan" olympus-platform "Consent screen. Issue 2799." >/dev/null 2>&1
FLEET_QUEUE_FILE="$JQ_FILE" "$QUEUE" add "$J_PLANS/also-missing.plan" olympus-platform "No requirement named." >/dev/null 2>&1
assert_py "queue add stores the issue the plan header names" "$JQ_FILE" \
  'd["entries"][0]["issue"]==72'
assert_py "queue add falls back to the issue the declared purpose names" "$JQ_FILE" \
  'd["entries"][1]["issue"]==2799'
assert_py "queue add stores null when nothing names an issue" "$JQ_FILE" \
  'd["entries"][2]["issue"] is None'
FLEET_QUEUE_FILE="$JQ_FILE" "$QUEUE" list 2>/dev/null | grep -q '#2799' \
  && ok "queue list prints the issue beside the plan" || bad "queue list prints the issue beside the plan"

grep -q 'task_line' "$REPO_DIR/docs/experience-data.md" \
  && ok "task_line is documented in the live schema" || bad "task_line is documented in the live schema"
grep -q 'gh_enrichment' "$REPO_DIR/docs/experience-data.md" \
  && ok "gh_enrichment is documented in the live schema" || bad "gh_enrichment is documented in the live schema"
grep -q 'repos\[\]' "$REPO_DIR/docs/experience-data.md" \
  && ok "repos[] is documented in the live schema" || bad "repos[] is documented in the live schema"
# ── Part K: NEEDS YOU, INITIATIVES and blocked queue entries (Floor v3-A) ──
echo "== Part K: NEEDS YOU + INITIATIVES (Floor v3, wave A) =="

# The parses, on the projector's own functions.
assert_fn "critic_record reads a verdict from the first line" \
  'mod.critic_record("IC_1", "https://example.invalid/c/1", "2026-09-13T10:00:00Z", "CRITIC TILE CONNECT GUIDE ROUND 2: SAFE-TO-MERGE\nAll clear.")["verdict"]=="SAFE-TO-MERGE"'
assert_fn "critic_record reads the round and the heading without the verdict" \
  '(lambda r: r["round"]==2 and r["stem"]=="CRITIC TILE CONNECT GUIDE")(mod.critic_record("IC_1", "u", "2026-09-13T10:00:00Z", "CRITIC TILE CONNECT GUIDE ROUND 2: SAFE-TO-MERGE\nAll clear."))'
assert_fn "critic_record reads a verdict that opens a body line" \
  'mod.critic_record("IC_2", "u", "2026-09-13T10:00:00Z", "CRITIC W2A IRIS SCAFFOLD ROUND 4\nVerdict: BLOCK-FIX on B4.\n")["verdict"]=="BLOCK-FIX"'
assert_fn "a verdict quoted mid-sentence is never a verdict" \
  'mod.critic_record("IC_3", "u", "2026-09-13T10:00:00Z", "CRITIC K NOTE\nThe options were SAFE-TO-MERGE or BLOCK-FIX.") is None'
assert_fn "a verdict quoted mid-sentence on the first line is not a verdict either" \
  'mod.critic_record("IC_3b", "u", "2026-09-13T10:00:00Z", "CRITIC V3A NOTE: the last review said BLOCK-FIX but this is not a verdict.\nMore prose.") is None'
assert_fn "a heading word BLOCK never steals BLOCK-FIX after the colon" \
  'mod.critic_record("IC_3c", "u", "2026-09-13T10:00:00Z", "CRITIC V3A BLOCK: BLOCK-FIX\nOne finding.")["verdict"]=="BLOCK-FIX"'
assert_fn "a heading word SAFE never steals SAFE-TO-MERGE after the colon" \
  'mod.critic_record("IC_3d", "u", "2026-09-13T10:00:00Z", "CRITIC SAFE HARBOR ROUND 2: SAFE-TO-MERGE\nAll clear.")["verdict"]=="SAFE-TO-MERGE"'
assert_fn "a verdict that closes the first line counts, with no colon" \
  'mod.critic_record("IC_3e", "u", "2026-09-13T10:00:00Z", "CRITIC FLOOR V3A BLOCK-FIX\nFour findings.")["verdict"]=="BLOCK-FIX"'
assert_fn "two verdict tokens on the first line, no colon: ambiguous, no verdict" \
  'mod.first_line_verdict("CRITIC FLOOR V3A BLOCK-FIX SAFE-TO-MERGE") is None and mod.critic_record("IC_3f", "u", "2026-09-13T10:00:00Z", "CRITIC FLOOR V3A BLOCK-FIX SAFE-TO-MERGE\nTwo tokens, no colon.") is None'
assert_fn "two verdict tokens after a colon: ambiguous, no verdict" \
  'mod.first_line_verdict("CRITIC FLOOR V3A: BLOCK-FIX SAFE-TO-MERGE") is None and mod.critic_record("IC_3g", "u", "2026-09-13T10:00:00Z", "CRITIC FLOOR V3A: BLOCK-FIX SAFE-TO-MERGE\nTwo tokens after a colon.") is None'
assert_fn "two verdict tokens reversed, no colon: ambiguous, no verdict" \
  'mod.first_line_verdict("CRITIC FLOOR V3A SAFE-TO-MERGE BLOCK-FIX") is None and mod.critic_record("IC_3h", "u", "2026-09-13T10:00:00Z", "CRITIC FLOOR V3A SAFE-TO-MERGE BLOCK-FIX\nReversed, no colon.") is None'
assert_fn "two verdict tokens reversed after a colon: ambiguous, no verdict" \
  'mod.first_line_verdict("CRITIC FLOOR V3A: SAFE-TO-MERGE BLOCK-FIX") is None and mod.critic_record("IC_3i", "u", "2026-09-13T10:00:00Z", "CRITIC FLOOR V3A: SAFE-TO-MERGE BLOCK-FIX\nReversed after a colon.") is None'
assert_fn "the same verdict word twice is one verdict, a heading word before the colon is none" \
  'mod.first_line_verdict("CRITIC K ROUND 2: BLOCK-FIX (round 1 BLOCK-FIX stands)")=="BLOCK-FIX" and mod.first_line_verdict("CRITIC SAFE HARBOR ROUND 2: SAFE-TO-MERGE")=="SAFE-TO-MERGE" and mod.first_line_verdict("CRITIC V3A BLOCK: BLOCK-FIX")=="BLOCK-FIX"'
assert_fn "a comment whose first line is not a critic heading is ignored" \
  'mod.critic_record("IC_4", "u", "2026-09-13T10:00:00Z", "Starting work on the block-fix: BLOCK-FIX items 1 and 2") is None'
assert_fn "the heading stops at the first lower-case word" \
  'mod.critic_record("IC_5", "u", "2026-09-13T10:00:00Z", "API CRITIC W2C PR 2833 head fae97478 at start: BLOCK-FIX")["stem"]=="API CRITIC W2C PR 2833"'
assert_fn "the body never leaves critic_record" \
  '(lambda c: all(not k.startswith("_") for k in c) and "Two findings" not in str(c) and "feat/x" not in str(c))(mod.public_comment(mod.critic_record("IC_6", "u", "2026-09-13T10:00:00Z", "CRITIC K: BLOCK-FIX\nTwo findings in feat/x.")))'
assert_fn "latest_round keeps the newest comment per heading" \
  '[(r["stem"], r["round"], r["verdict"]) for r in mod.latest_round([mod.critic_record("a","u","2026-09-13T09:00:00Z","CRITIC K: BLOCK-FIX\n"), mod.critic_record("b","u","2026-09-13T10:00:00Z","CRITIC K ROUND 2: SAFE-TO-MERGE\n"), mod.critic_record("c","u","2026-09-13T09:30:00Z","SECURITY CRITIC K: SAFE\n")])]==[("CRITIC K",2,"SAFE-TO-MERGE"),("SECURITY CRITIC K",1,"SAFE")]'
assert_fn "wave_id reads W2-A from the header and -w2a- from the file name" \
  'mod.wave_id("Assistant Channel W2-A: the Iris service", "x.plan")=="W2-A" and mod.wave_id("", "2026-09-12-w2a-iris.plan")=="W2-A" and mod.wave_id("W0: contract", "x")=="W0" and mod.wave_id("no wave", "x.plan") is None'
assert_fn "track_name is the header before the wave id" \
  'mod.track_name("Assistant Channel W2-A: the Iris service")=="Assistant Channel" and mod.track_name("Fix wave after BLOCK-FIX") is None'
assert_fn "plan_refs reads S numbers, variables, the findings issue and the repo" \
  '(lambda r: r["s_numbers"]==[11] and r["variables"]==["IRIS_PUBLIC_URL"] and r["findings_issues"]==[2340] and r["repo"]=="olympus-platform" and r["epic"]==2797 and r["prs"]==[2829])(mod.plan_refs("# W2-A fixes. PR 2829, epic 2797.\n# DISPATCH: ./scripts/dispatch.sh git@github.com:x/olympus-platform.git p.plan --auto\n1 | devops | Move S11 to ACCEPTED, set IRIS_PUBLIC_URL. Post ONE comment on issue 2340. | feat/x\n", "p.plan"))'

# ── the fixture: one of each ────────────────────────────────────────────────
K_PLANS="$TMP/plans-k"; mkdir -p "$K_PLANS"
K_DISPATCH='# DISPATCH: ./scripts/dispatch.sh git@example.invalid:testowner/olympus-platform.git plan --auto'
cat > "$K_PLANS/k-w0.plan" <<PLAN
# Track K W0: the contract. Issue 500, epic 500.
$K_DISPATCH
1 | docs-writer | Write the contract. | feat/k-w0
PLAN
cat > "$K_PLANS/k-blocked.plan" <<PLAN
# Track K W1-A: the blocked wave. Issue 501, epic 500.
$K_DISPATCH
1 | devops | Do the blocked thing. | feat/k-blocked
2 | backend-critic | READ-ONLY REVIEW. Post ONE comment on issue 900 with SAFE-TO-MERGE or BLOCK-FIX. | feat/k-blocked
PLAN
cat > "$K_PLANS/k-ready.plan" <<PLAN
# Track K W1-B: the ready wave. Issue 502, epic 500.
$K_DISPATCH
1 | go-backend | Do the ready thing. | feat/k-ready
PLAN
cat > "$K_PLANS/k-failed.plan" <<PLAN
# Track K W1-C: the failed wave. Issue 504, epic 500.
$K_DISPATCH
1 | devops | Fail loudly. | feat/k-failed
PLAN
cat > "$K_PLANS/k-live.plan" <<PLAN
# Track K W1-D: the quiet wave. Issue 505, epic 500.
$K_DISPATCH
1 | devops | Be quiet for a long time. | feat/k-quiet
PLAN
cat > "$K_PLANS/k-queued.plan" <<PLAN
# Track K W2-A: the next wave. Issue 503, epic 500.
$K_DISPATCH
1 | devops | Move S11 to ACCEPTED and set IRIS_PUBLIC_URL from repository variables. | feat/k-next
PLAN

K_Q="$TMP/queue-k.json"
python3 - "$K_Q" "$K_PLANS" <<'KQ'
import json, sys
out, plans = sys.argv[1], sys.argv[2]
def entry(name, status, dispatch_id=None, blocked=None):
    e = {"plan": plans + "/" + name, "repo": "olympus-platform", "purpose": "", "issue": None,
         "added_at": "2026-09-12T00:00:00Z", "status": status,
         "dispatch_id": dispatch_id, "settled_at": None, "settled_status": None}
    if blocked is not None:
        e["blocked"] = blocked
    return e
json.dump({"schema": "fleet-queue/1", "updated_at": "2026-09-12T00:00:00Z", "entries": [
    entry("k-w0.plan", "settled", "k-w0"),
    entry("k-blocked.plan", "settled", "k-landed-blocked"),
    entry("k-ready.plan", "settled", "k-landed-ready"),
    entry("k-failed.plan", "settled", "k-failed"),
    entry("k-live.plan", "running", "k-live"),
    entry("k-queued.plan", "queued"),
    entry("k-held.plan", "queued", blocked="held by the operator"),
]}, open(out, "w"), indent=2)
KQ

K_DIR="$TMP/events-k"; mkdir -p "$K_DIR"
python3 - "$K_DIR" <<'KFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone
out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
midnight = midnight.astimezone(timezone.utc).replace(tzinfo=None)
def ts(d):
    return max(now - timedelta(seconds=d), midnight).strftime("%Y-%m-%dT%H:%M:%SZ")
def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")
def landed(name, plan, branch, agent, start):
    write(name, [
        {"ts": ts(start), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform", "plan": plan},
        {"ts": ts(start - 5), "event": "seat_dispatch", "task_id": "0", "agent": agent, "branch": branch, "wave": 1, "provider": "local"},
        {"ts": ts(start - 300), "event": "seat_exit", "task_id": "0", "agent": agent, "branch": branch, "wave": 1, "status": "success", "exit": 0, "duration_s": 295},
        {"ts": ts(start - 305), "event": "dispatch_end", "status": "completed", "total": 1, "succeeded": 1, "failed": 0, "duration_s": 305},
    ])
landed("k-landed-blocked.jsonl", "k-blocked.plan", "feat/k-blocked", "devops", 4000)
landed("k-landed-ready.jsonl", "k-ready.plan", "feat/k-ready", "go-backend", 3000)
# landed today, three seats whose PRs each carry two verdict tokens on the
# first line of the critic comment (finding 5, round 2): no item may come of them
write("k-landed-two.jsonl", [
    {"ts": ts(2600), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform", "plan": "k-two.plan"},
    {"ts": ts(2595), "event": "seat_dispatch", "task_id": "0", "agent": "devops", "branch": "feat/k-twotail", "wave": 1, "provider": "local"},
    {"ts": ts(2594), "event": "seat_dispatch", "task_id": "1", "agent": "devops", "branch": "feat/k-twocolon", "wave": 1, "provider": "local"},
    {"ts": ts(2593), "event": "seat_dispatch", "task_id": "2", "agent": "devops", "branch": "feat/k-tworev", "wave": 1, "provider": "local"},
    {"ts": ts(2300), "event": "seat_exit", "task_id": "0", "agent": "devops", "branch": "feat/k-twotail", "wave": 1, "status": "success", "exit": 0, "duration_s": 295},
    {"ts": ts(2299), "event": "seat_exit", "task_id": "1", "agent": "devops", "branch": "feat/k-twocolon", "wave": 1, "status": "success", "exit": 0, "duration_s": 295},
    {"ts": ts(2298), "event": "seat_exit", "task_id": "2", "agent": "devops", "branch": "feat/k-tworev", "wave": 1, "status": "success", "exit": 0, "duration_s": 295},
    {"ts": ts(2290), "event": "dispatch_end", "status": "completed", "total": 3, "succeeded": 3, "failed": 0, "duration_s": 310},
])
write("k-failed.jsonl", [
    {"ts": ts(2000), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform", "plan": "k-failed.plan"},
    {"ts": ts(1995), "event": "seat_dispatch", "task_id": "0", "agent": "devops", "branch": "feat/k-failed", "wave": 1, "provider": "local"},
    {"ts": ts(1558), "event": "seat_exit", "task_id": "0", "agent": "devops", "branch": "feat/k-failed", "wave": 1, "status": "failed", "exit": 1, "duration_s": 437},
    {"ts": ts(1550), "event": "dispatch_end", "status": "completed", "total": 1, "succeeded": 0, "failed": 1, "duration_s": 450},
])
# live, one seat dispatched 600 s ago and never heard from since: quiet
write("k-live.jsonl", [
    {"ts": ts(610), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform", "plan": "k-live.plan"},
    {"ts": ts(600), "event": "seat_dispatch", "task_id": "7", "agent": "devops", "branch": "feat/k-quiet", "wave": 1, "provider": "local", "attempt": 1},
])
# offline: last event 1000 s ago (past offline_after_s 900), no close-out. Not
# clamped to midnight: a run that started yesterday is still in live_dates.
def raw(d):
    return (now - timedelta(seconds=d)).strftime("%Y-%m-%dT%H:%M:%SZ")
write("k-offline.jsonl", [
    {"ts": raw(1060), "event": "dispatch_start", "mode": "wave", "repo": "olympus-platform", "plan": "k-offline.plan"},
    {"ts": raw(1000), "event": "seat_dispatch", "task_id": "9", "agent": "devops", "branch": "feat/k-offline", "wave": 1, "provider": "local", "attempt": 1},
])
KFIX
printf 'k-live.jsonl\n' > "$K_DIR/latest"

# The target repo checkout: a PRD row still PROPOSED and the env contract.
K_CO="$TMP/checkouts"; mkdir -p "$K_CO/olympus-platform/docs/prd/pages" "$K_CO/olympus-platform/docs/operations"
cat > "$K_CO/olympus-platform/docs/prd/pages/k.md" <<'MD'
## 9. New strings
| # | String | Where | Note |
|---|---|---|---|
| S10 | `Connected` | tile | New. ACCEPTED, co-founder sign-off 2026-09-12. |
| S11 | `Not available right now.` | kill switch | New. PROPOSED. |
MD
cat > "$K_CO/olympus-platform/docs/operations/env-vars-iris.md" <<'MD'
# Env contract (Iris)
| Env var | Value (prod) | Local default | Set in prod by | Notes |
|---|---|---|---|---|
| `PORT` | `8080` | `8082` | Cloud Run | Injected. |
| `OLYMPUS_API_URL` | `https://api.example.invalid` | `http://localhost:8080` | `deploy-iris.yml`, from repository variable `OLYMPUS_API_URL` | The API origin. |
| `IRIS_PUBLIC_URL` | `https://iris.example.invalid` | `http://localhost:8082` | `deploy-iris.yml`, from repository variable `IRIS_PUBLIC_URL` | This service's own origin. |
MD

# The fake gh: canned answers, every call logged, no network.
K_BIN="$TMP/bin-k"; mkdir -p "$K_BIN"; K_LOG="$TMP/gh-k.log"
cat > "$K_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${GH_SHIM_LOG:?}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
branch=""; prev=""; state=""; json=""
for a in "$@"; do
  [ "$prev" = "--head" ] && branch="$a"
  [ "$prev" = "--state" ] && state="$a"
  [ "$prev" = "--json" ] && json="$a"
  prev="$a"
done
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue view")
    if [ "$json" = "body" ]; then
      [ "$3" = "500" ] && printf '{"body":"# Epic\\n\\nSome prose.\\n\\n**Exit criterion:** five distinct testers complete a checkout. Then more.\\n"}\n' || printf '{"body":"no criterion here"}\n'
    else
      printf '{"number":%s,"milestone":{"title":"Track K"}}\n' "$3"
    fi ;;
  "issue list")
    printf '[{"number":500,"title":"[Track K] Epic: the whole thing","state":"OPEN"},{"number":501,"title":"W1-A","state":"CLOSED"},{"number":502,"title":"W1-B","state":"OPEN"},{"number":503,"title":"W2-A","state":"OPEN"},{"number":504,"title":"W1-C","state":"OPEN"},{"number":505,"title":"W1-D","state":"OPEN"}]\n' ;;
  "pr list")
    if [ "$state" = "merged" ]; then
      printf '[{"number":95,"title":"feat: the contract (#500)","headRefName":"feat/k-w0","mergedAt":"2026-09-01T10:00:00Z","milestone":null}]\n'
    else
      case "$branch" in
        feat/k-blocked) printf '[{"number":101,"title":"Blocked PR","state":"OPEN","url":"https://example.invalid/pr/101"}]\n' ;;
        feat/k-ready)   printf '[{"number":102,"title":"Ready PR","state":"OPEN","url":"https://example.invalid/pr/102"}]\n' ;;
        feat/k-twotail)  printf '[{"number":301,"title":"Two tail","state":"OPEN","url":"https://example.invalid/pr/301"}]\n' ;;
        feat/k-twocolon) printf '[{"number":302,"title":"Two colon","state":"OPEN","url":"https://example.invalid/pr/302"}]\n' ;;
        feat/k-tworev)   printf '[{"number":303,"title":"Two rev","state":"OPEN","url":"https://example.invalid/pr/303"}]\n' ;;
        *) printf '[]\n' ;;
      esac
    fi ;;
  "pr view")
    case "$3" in
      101) printf '{"number":101,"title":"Blocked PR","state":"OPEN","isDraft":false,"mergeStateStatus":"BLOCKED","url":"https://example.invalid/pr/101","headRefName":"feat/k-blocked","comments":[{"id":"IC_101_1","url":"https://example.invalid/pr/101#c1","createdAt":"%s","body":"CRITIC K BLOCKED ROUND 1: BLOCK-FIX\\nTwo findings in the body."}],"reviews":[]}\n' "$NOW" ;;
      102) printf '{"number":102,"title":"Ready PR","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/102","headRefName":"feat/k-ready","comments":[{"id":"IC_102_1","url":"https://example.invalid/pr/102#c1","createdAt":"%s","body":"CRITIC K READY: SAFE-TO-MERGE\\nAll clear in the body."},{"id":"IC_102_2","url":"https://example.invalid/pr/102#c2","createdAt":"%s","body":"Starting work, nothing to see."}],"reviews":[{"id":"PRR_1","url":"https://example.invalid/pr/102#r1","submittedAt":"%s","state":"APPROVED","body":"SECURITY CRITIC K READY ROUND 1\\nVerdict: SAFE-TO-MERGE\\nNo secrets in the body."}]}\n' "$NOW" "$NOW" "$NOW" ;;
      301) printf '{"number":301,"title":"Two tail","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/301","headRefName":"feat/k-twotail","comments":[{"id":"IC_301","url":"https://example.invalid/pr/301#c1","createdAt":"%s","body":"CRITIC FLOOR V3A BLOCK-FIX SAFE-TO-MERGE\\nTwo tokens, no colon, in the body."}],"reviews":[]}\n' "$NOW" ;;
      302) printf '{"number":302,"title":"Two colon","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/302","headRefName":"feat/k-twocolon","comments":[{"id":"IC_302","url":"https://example.invalid/pr/302#c1","createdAt":"%s","body":"CRITIC FLOOR V3A: BLOCK-FIX SAFE-TO-MERGE\\nTwo tokens after a colon, in the body."}],"reviews":[]}\n' "$NOW" ;;
      303) printf '{"number":303,"title":"Two rev","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/303","headRefName":"feat/k-tworev","comments":[{"id":"IC_303","url":"https://example.invalid/pr/303#c1","createdAt":"%s","body":"CRITIC FLOOR V3A SAFE-TO-MERGE BLOCK-FIX\\nReversed two tokens, no colon, in the body."}],"reviews":[]}\n' "$NOW" ;;
      *) exit 1 ;;
    esac ;;
  "api repos/testowner/olympus-platform/issues/900/comments"*)
    printf '[{"id":9001,"html_url":"https://example.invalid/issues/900#c9001","created_at":"%s","body":"CRITIC K BLOCKED ROUND 2: BLOCK-FIX\\nStill open on PR 101 in the body."},{"id":9002,"html_url":"https://example.invalid/issues/900#c9002","created_at":"%s","body":"CRITIC K NOTE\\nThe options were SAFE-TO-MERGE or BLOCK-FIX, on PR 102."},{"id":9003,"html_url":"https://example.invalid/issues/900#c9003","created_at":"%s","body":"CRITIC K NOTE: the last review said BLOCK-FIX but this is not a verdict, on PR 102.\\nProse in the body."}]\n' "$NOW" "$NOW" "$NOW" ;;
  "api repos/testowner/olympus-platform/milestones"*)
    printf '[{"title":"Track K","number":1,"html_url":"https://example.invalid/milestone/1","open_issues":5,"closed_issues":1,"updated_at":"%s"},{"title":"Old Track","number":2,"html_url":"https://example.invalid/milestone/2","open_issues":3,"closed_issues":0,"updated_at":"2026-01-01T00:00:00Z"}]\n' "$NOW" ;;
  "variable list") printf '[{"name":"OLYMPUS_API_URL"}]\n' ;;
  "secret list") printf '[]\n' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$K_BIN/gh"

# ── with gh answering: the six entries ──────────────────────────────────────
K_ON="$TMP/out/live-k-on.json"; : > "$K_LOG"
PATH="$K_BIN:$PATH" GH_SHIM_LOG="$K_LOG" FLEET_GH_OWNER=testowner FLEET_CHECKOUTS="$K_CO" \
  python3 "$DESK_LIVE" --once --events-dir "$K_DIR" --queue-file "$K_Q" --out "$K_ON" >/dev/null 2>&1 \
  && ok "--once exits 0 with the v3 fixture and gh answering" || bad "--once exits 0 with the v3 fixture and gh answering"
assert_py "six entries, one of each type" "$K_ON" \
  'sorted(e["type"] for e in d["needs_you"])==["critic_block","failed_dispatch","missing_variable","prd_proposed","quiet_seat","ready_to_merge"]'
assert_py "newest first" "$K_ON" \
  '[e["at"] for e in d["needs_you"]]==sorted([e["at"] for e in d["needs_you"]], reverse=True)'
assert_py "every entry has a type, a one-line text, one action, a source and a verified flag" "$K_ON" \
  'all(set(("type","text","action","source","verified","at","repo","branch","pr","plan"))<=set(e) and e["text"] and "\n" not in e["text"] and e["source"].get("kind") for e in d["needs_you"])'
assert_py "the BLOCK: the newest round on the findings issue, cited by comment id" "$K_ON" \
  '(lambda e: e["pr"]==101 and e["branch"]=="feat/k-blocked" and "round 2" in e["text"] and "BLOCK-FIX" in e["text"] and e["action"]=="open the comment" and e["source"]["kind"]=="comment" and e["source"]["comment_id"]==9001 and e["source"]["issue"]==900 and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="critic_block"][0])'
assert_py "the ready PR: every latest verdict safe and merge state CLEAN, cited by PR and comments" "$K_ON" \
  '(lambda e: e["pr"]==102 and e["action"]=="merge" and e["source"]["kind"]=="pr" and e["source"]["merge_state"]=="CLEAN" and sorted(c["verdict"] for c in e["source"]["comments"])==["SAFE-TO-MERGE","SAFE-TO-MERGE"] and {c["kind"] for c in e["source"]["comments"]}=={"comment","review"} and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="ready_to_merge"][0])'
assert_py "the quiet seat: cited by its stream event" "$K_ON" \
  '(lambda e: e["branch"]=="feat/k-quiet" and "devops" in e["text"] and "quiet for" in e["text"] and e["action"]=="check the log" and e["source"]["kind"]=="stream" and e["source"]["dispatch_id"]=="k-live" and e["source"]["event"]=="seat_dispatch" and e["source"]["task_id"]=="7" and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="quiet_seat"][0])'
assert_py "the failed dispatch: cited by dispatch_end, stream named by basename" "$K_ON" \
  '(lambda e: "failed after" in e["text"] and e["action"]=="see the output" and e["source"]=={"kind":"stream","dispatch_id":"k-failed","stream":"k-failed.jsonl","event":"dispatch_end","ts":e["at"]} and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="failed_dispatch"][0])'
assert_py "the PROPOSED row: cited by file and line in the target checkout" "$K_ON" \
  '(lambda e: e["text"].startswith("S11 awaits sign-off") and e["action"]=="approve or edit" and e["source"]=={"kind":"file","checkout":"olympus-platform","file":"docs/prd/pages/k.md","line":5,"named_by":"k-queued.plan"} and e["plan"]=="k-queued.plan" and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="prd_proposed"][0])'
assert_py "the missing variable: named by the plan, required by the contract, absent from gh" "$K_ON" \
  '(lambda e: e["text"].startswith("IRIS_PUBLIC_URL unset") and e["action"]=="set it" and e["source"]["kind"]=="file" and e["source"]["file"]=="docs/operations/env-vars-iris.md" and e["source"]["line"]==6 and e["source"]["lookup"]=="verified" and e["verified"] is True)([e for e in d["needs_you"] if e["type"]=="missing_variable"][0])'
assert_py "a variable the contract lists and gh has is not an item" "$K_ON" \
  'not any("OLYMPUS_API_URL" in e["text"] for e in d["needs_you"])'
assert_py "every check ran" "$K_ON" \
  'all(c["status"]=="ok" for c in d["needs_you_meta"]["checks"]) and d["needs_you_meta"]["count"]==6 and d["needs_you_meta"]["unverified"]==0'
assert_py "the top line counts needs_you" "$K_ON" \
  'd["summary"]["needs_you"]==6'
assert_py "the offline stream with no close-out is no quiet seat: one quiet_seat, the live one" "$K_ON" \
  '[e["branch"] for e in d["needs_you"] if e["type"]=="quiet_seat"]==["feat/k-quiet"]'
assert_py "its seat is merged as foreign and reads unknown, never running" "$K_ON" \
  'S["9"]["dispatch_id"]=="k-offline" and S["9"]["foreign"] is True and S["9"]["status"]=="unknown" and S["9"]["pipeline"]=="blocked" and d["summary"]["running"]==1'
assert_py "a verdict quoted on the first line of the newest comment is no BLOCK: PR 102 stays ready" "$K_ON" \
  'not any(e["type"]=="critic_block" and e["pr"]==102 for e in d["needs_you"]) and any(e["type"]=="ready_to_merge" and e["pr"]==102 for e in d["needs_you"])'
assert_py "two verdict tokens on the first line (no colon, colon, reversed): CLEAN PRs 301-303 are neither ready nor blocked" "$K_ON" \
  'not any(e["pr"] in (301,302,303) for e in d["needs_you"]) and d["summary"]["needs_you"]==6'
assert_py "those three PRs were looked at, not skipped" "$K_ON" \
  '(lambda c: c["status"]=="ok" and c["looked_at"]==5)({c["check"]: c for c in d["needs_you_meta"]["checks"]}["ready_to_merge"])'
assert_py "the queued plan shows why it is blocked, in place" "$K_ON" \
  '(lambda q: q["blocked"] and q["blocked_by"]["type"] in ("prd_proposed","missing_variable") and q["blocked_by"]["source"]["kind"]=="file")({q["plan_basename"]: q for q in d["queue"]}["k-queued.plan"])'
assert_py "a reason stored by queue.sh block wins and is marked so" "$K_ON" \
  '(lambda q: q["blocked"]=="held by the operator" and q["blocked_by"]["type"]=="queue")({q["plan_basename"]: q for q in d["queue"]}["k-held.plan"])'
assert_py "one initiative row per active milestone, the stale one dropped" "$K_ON" \
  '[r["title"] for r in d["initiatives"]]==["Track K"] and d["initiatives_meta"]["repos"][0]["lookup"]=="verified"'
assert_py "waves landed of waves planned, from streams, merged PRs, plans and queue" "$K_ON" \
  '(lambda r: r["waves"]["landed"]==3 and r["waves"]["planned"]==6 and r["waves"]["planned_ids"]==["W0","W1-A","W1-B","W1-C","W1-D","W2-A"] and r["waves"]["landed_ids"]==["W0","W1-A","W1-B"])(d["initiatives"][0])'
assert_py "open issues, last landed PR, epic and its exit criterion sentence" "$K_ON" \
  '(lambda r: r["open_issues"]==5 and r["last_landed"]["number"]==95 and r["last_landed"]["title"].startswith("feat: the contract") and r["epic"]==500 and r["exit"]=="five distinct testers complete a checkout." and r["exit_lookup"]=="verified" and r["lookup"]=="verified")(d["initiatives"][0])'
if grep -q 'in the body' "$K_ON"; then
  bad "no comment or issue body reaches the projection"
else
  ok "no comment or issue body reaches the projection"
fi
if grep -q "$K_CO" "$K_ON"; then
  bad "no checkout path reaches the projection"
else
  ok "no checkout path reaches the projection"
fi
[ "$(grep -c 'issue view 500 -R testowner/olympus-platform --json body' "$K_LOG")" = "1" ] \
  && ok "the epic body is fetched once" || bad "the epic body is fetched once"
grep -q 'variable list -R testowner/olympus-platform' "$K_LOG" \
  && ok "variables are listed by name only" || bad "variables are listed by name only"

# ── the offline stream followed directly: offline, seat unknown, no quiet_seat ──
K_OFFLINE="$TMP/out/live-k-offline.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --dispatch-id k-offline --events-dir "$K_DIR" --queue-file "$K_Q" --out "$K_OFFLINE" >/dev/null 2>&1 \
  && ok "--once exits 0 following the offline stream" || bad "--once exits 0 following the offline stream"
assert_py "the followed stream reads offline and its seat unknown" "$K_OFFLINE" \
  'd["staleness"]["state"]=="offline" and d["staleness"]["seconds"]>=d["staleness"]["offline_after_s"] and S["9"]["status"]=="unknown"'
assert_py "no quiet_seat for the offline stream; the live foreign seat is still one" "$K_OFFLINE" \
  '[e["branch"] for e in d["needs_you"] if e["type"]=="quiet_seat"]==["feat/k-quiet"] and {c["check"]: c["status"] for c in d["needs_you_meta"]["checks"]}["quiet_seat"]=="ok"'
K_OFFLINE_REPLAY="$TMP/out/live-k-offline-replay.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --replay --dispatch-id k-offline --events-dir "$K_DIR" --queue-file "$K_Q" --out "$K_OFFLINE_REPLAY" >/dev/null 2>&1
assert_py "a replay keeps the stream's own word on the seat: the past has no offline" "$K_OFFLINE_REPLAY" \
  'd["view"]=="replay" and d["staleness"]["state"]=="replay" and S["9"]["status"]=="running" and d["needs_you"]==[]'

# ── gh absent: what the streams and files alone can prove, the rest marked ──
K_NOGH="$TMP/nogh"; mkdir -p "$K_NOGH"
ln -sf "$(command -v python3)" "$K_NOGH/python3"
K_PATH="$K_NOGH:/usr/bin:/bin"
if PATH="$K_PATH" command -v gh >/dev/null 2>&1; then
  echo "  note: gh is on the system PATH; using the disabled switch instead"
  K_PATH="$PATH"; K_OFF_ENV="FLEET_DESK_NO_GH=1"; K_OFF_STATUS="disabled"
else
  K_OFF_ENV="FLEET_DESK_NO_GH="; K_OFF_STATUS="unavailable"
fi
K_OFF="$TMP/out/live-k-off.json"
env PATH="$K_PATH" $K_OFF_ENV FLEET_CHECKOUTS="$K_CO" \
  python3 "$DESK_LIVE" --once --events-dir "$K_DIR" --queue-file "$K_Q" --out "$K_OFF" >/dev/null 2>&1 \
  && ok "--once exits 0 with gh absent" || bad "--once exits 0 with gh absent"
assert_py "gh absent reads as $K_OFF_STATUS" "$K_OFF" "d[\"gh_enrichment\"][\"status\"]==\"$K_OFF_STATUS\""
assert_py "the stream and file entries are still there, verified" "$K_OFF" \
  'sorted(e["type"] for e in d["needs_you"] if e["verified"])==["failed_dispatch","prd_proposed","quiet_seat"]'
assert_py "no BLOCK and no ready PR is invented without gh" "$K_OFF" \
  'not any(e["type"] in ("critic_block","ready_to_merge") for e in d["needs_you"])'
assert_py "a variable gh could not check is no item: the skipped check row is the record" "$K_OFF" \
  'not any(e["type"]=="missing_variable" for e in d["needs_you"]) and {c["check"]: c for c in d["needs_you_meta"]["checks"]}["missing_variable"]["status"]=="skipped" and d["needs_you_meta"]["unverified"]==0'
assert_py "summary.needs_you counts verified items only" "$K_OFF" \
  'd["summary"]["needs_you"]==3 and d["summary"]["needs_you"]==sum(1 for e in d["needs_you"] if e["verified"])'
assert_py "the gh checks are marked skipped with the reason" "$K_OFF" \
  '{c["check"]: c["status"] for c in d["needs_you_meta"]["checks"]}=={"critic_block":"skipped","ready_to_merge":"skipped","quiet_seat":"ok","failed_dispatch":"ok","prd_proposed":"ok","missing_variable":"skipped"} and all(c["reason"] for c in d["needs_you_meta"]["checks"] if c["status"]=="skipped")'
assert_py "the fallback initiative row comes from streams and queue alone and says so" "$K_OFF" \
  '(lambda r: r["lookup"]=="skipped" and r["reason"] and r["number"] is None and r["open_issues"] is None and r["exit"] is None and r["waves"]["planned"]==4 and r["waves"]["landed"]==2 and r["waves"]["landed_ids"]==["W1-A","W1-B"] and r["source"]["landed"]=="streams of the day")({r["title"]: r for r in d["initiatives"]}["Track K"]) and d["initiatives_meta"]["repos"][0]["lookup"]=="skipped"'
assert_py "the fallback row carries epic_title and exit_lookup as the schema says" "$K_OFF" \
  '(lambda r: r["epic"] is None and r["epic_title"] is None and r["exit"] is None and r["exit_lookup"]=="skipped")({r["title"]: r for r in d["initiatives"]}["Track K"])'
if python3 - "$K_ON" "$K_OFF" <<'KEYS'
import json, sys
on = json.load(open(sys.argv[1]))["initiatives"][0]
off = json.load(open(sys.argv[2]))["initiatives"][0]
sys.exit(0 if set(on) == set(off) else 1)
KEYS
then ok "a fallback initiative row has the same keys as a verified one"; else bad "a fallback initiative row has the same keys as a verified one"; fi

# A replay carries neither: the past has no present.
K_REPLAY="$TMP/out/live-k-replay.json"
FLEET_DESK_NO_GH=1 python3 "$DESK_LIVE" --once --replay --dispatch-id k-live --events-dir "$K_DIR" --queue-file "$K_Q" --out "$K_REPLAY" >/dev/null 2>&1
assert_py "a replay carries no needs_you and no initiatives" "$K_REPLAY" \
  'd["view"]=="replay" and d["needs_you"]==[] and d["initiatives"]==[]'

for key in 'needs_you\[\]' 'initiatives\[\]' 'queue\[\].blocked' 'never invents'; do
  grep -q "$key" "$REPO_DIR/docs/experience-data.md" \
    && ok "$key is documented in the live schema" || bad "$key is documented in the live schema"
done


# ── Part L: yesterday and the push (Floor v3-C) ──────────────────────────
echo "== Part L: yesterday and the push (Floor v3, wave C) =="

# The day before, read the same way as today. Two runs ended yesterday
# (one landed, one failed), one ended today, one three days ago.
Y_DIR="$TMP/events-yday"
mkdir -p "$Y_DIR"
Y_DATE=$(python3 - "$Y_DIR" <<'YFIX'
import json, os, sys
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
# Local midnight today, then naive UTC. Two and three hours before it are
# 22:00 and 21:00 local yesterday, inside the day whatever the zone does.
midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
midnight_utc = midnight.astimezone(timezone.utc).replace(tzinfo=None)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def write(name, rows):
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        for i, row in enumerate(rows, 1):
            row.update({"schema": "fleet-events/1", "seq": i, "dispatch_id": name[:-6]})
            fh.write(json.dumps(row) + "\n")


t0 = max(now - timedelta(seconds=600), midnight_utc)
write("y-today.jsonl", [
    {"ts": iso(t0), "event": "dispatch_start", "mode": "wave", "repo": "dev-agents", "plan": "alpha.plan"},
    {"ts": iso(t0), "event": "seat_dispatch", "task_id": "0", "agent": "devops",
     "branch": "feat/alpha", "wave": 1, "provider": "provider-a"},
    {"ts": iso(t0 + timedelta(seconds=60)), "event": "seat_exit", "task_id": "0", "agent": "devops",
     "branch": "feat/alpha", "wave": 1, "status": "success", "exit": 0, "duration_s": 60},
    {"ts": iso(t0 + timedelta(seconds=61)), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 1, "failed": 0, "duration_s": 61},
])
y1 = midnight_utc - timedelta(hours=2)
write("y-landed.jsonl", [
    {"ts": iso(y1 - timedelta(seconds=600)), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "beta.plan"},
    {"ts": iso(y1 - timedelta(seconds=590)), "event": "seat_dispatch", "task_id": "0", "agent": "go-backend",
     "branch": "feat/beta", "wave": 1, "provider": "provider-a"},
    {"ts": iso(y1 - timedelta(seconds=5)), "event": "seat_exit", "task_id": "0", "agent": "go-backend",
     "branch": "feat/beta", "wave": 1, "status": "success", "exit": 0, "duration_s": 585},
    {"ts": iso(y1), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 1, "failed": 0, "duration_s": 600},
])
y2 = midnight_utc - timedelta(hours=3)
write("y-failed.jsonl", [
    {"ts": iso(y2 - timedelta(seconds=300)), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "gamma.plan"},
    {"ts": iso(y2 - timedelta(seconds=290)), "event": "seat_dispatch", "task_id": "0", "agent": "web-frontend",
     "branch": "feat/gamma", "wave": 1, "provider": "provider-b"},
    {"ts": iso(y2 - timedelta(seconds=5)), "event": "seat_exit", "task_id": "0", "agent": "web-frontend",
     "branch": "feat/gamma", "wave": 1, "status": "failed", "exit": 1, "duration_s": 285},
    {"ts": iso(y2), "event": "dispatch_end", "status": "completed",
     "total": 1, "succeeded": 0, "failed": 1, "duration_s": 300},
])
old = now - timedelta(days=3)
write("y-old.jsonl", [
    {"ts": iso(old), "event": "dispatch_start", "mode": "wave", "repo": "dev-agents", "plan": "old.plan"},
    {"ts": iso(old), "event": "dispatch_end", "status": "completed", "total": 0, "succeeded": 0, "failed": 0},
])
print((midnight - timedelta(days=1)).date().isoformat())
YFIX
)
printf 'y-today.jsonl\n' > "$Y_DIR/latest"

Y_OUT="$TMP/out/live-yday.json"
python3 "$DESK_LIVE" --once --no-gh --events-dir "$Y_DIR" --queue-file "$TMP/no-queue.json" --out "$Y_OUT" >/dev/null 2>&1 \
  && ok "--once with a yesterday in the streams exits 0" || bad "--once with a yesterday in the streams exits 0"
assert_py "yesterday[] holds the runs that ended on the previous local day, newest first" "$Y_OUT" \
  '[t["dispatch_id"] for t in d["yesterday"]]==["y-landed","y-failed"]'
assert_py "today[] keeps only today; yesterday never leaks into it" "$Y_OUT" \
  '[t["dispatch_id"] for t in d["today"]]==["y-today"]'
assert_py "a run three days old is in neither day (the Almanac owns it)" "$Y_OUT" \
  '"y-old" not in [t["dispatch_id"] for t in d["today"]+d["yesterday"]]'
assert_py "a yesterday row has exactly the shape of a today row" "$Y_OUT" \
  'set(d["yesterday"][0])==set(d["today"][0]) and set(d["yesterday"][1])==set(d["today"][0])'
assert_py "the payload marks the day: today_meta.day and yesterday_meta.day" "$Y_OUT" \
  'd["today_meta"]["day"]=="today" and d["yesterday_meta"]["day"]=="yesterday"'
assert_py "yesterday_meta carries the previous local date and the same keys as today_meta" "$Y_OUT" \
  'd["yesterday_meta"]["date"]=="'"$Y_DATE"'" and set(d["yesterday_meta"])==set(d["today_meta"]) and d["yesterday_meta"]["ended"]==2'
assert_py "yesterday claims nothing live (a run with no close-out belongs to today)" "$Y_OUT" \
  'd["yesterday_meta"]["live"]==[]'
assert_py "yesterday outcomes read the seat exits like today" "$Y_OUT" \
  'd["yesterday"][0]["outcome"]=="landed" and d["yesterday"][1]["outcome"]=="failed"'
assert_py "summary counts both days" "$Y_OUT" \
  'd["summary"]["landed_today"]==1 and d["summary"]["landed_yesterday"]==2'
assert_py "a failure yesterday is history, not a NEEDS YOU item" "$Y_OUT" \
  'all(e["type"]!="failed_dispatch" for e in d["needs_you"])'

Y_REPLAY="$TMP/out/live-yday-replay.json"
python3 "$DESK_LIVE" --once --no-gh --events-dir "$Y_DIR" --dispatch-id y-landed --replay --out "$Y_REPLAY" >/dev/null 2>&1
assert_py "a replay carries no yesterday, like no today" "$Y_REPLAY" \
  'd["view"]=="replay" and d["yesterday"]==[] and d["today"]==[] and d["yesterday_meta"]["day"]=="yesterday"'

Y_EMPTY="$TMP/out/live-yday-empty.json"
mkdir -p "$TMP/events-none"
python3 "$DESK_LIVE" --once --no-gh --events-dir "$TMP/events-none" --queue-file "$TMP/no-queue.json" --out "$Y_EMPTY" >/dev/null 2>&1
assert_py "an idle desk still carries yesterday keys (empty, marked)" "$Y_EMPTY" \
  'd["yesterday"]==[] and d["yesterday_meta"]["day"]=="yesterday" and d["yesterday_meta"]["date"]'

grep -q 'strip-day-yesterday' "$REPO_DIR/templates/experience/floor.js" \
  && ok "the strip offers yesterday (floor.js)" || bad "the strip offers yesterday (floor.js)"
grep -q 'strip-day-yesterday' "$REPO_DIR/scripts/experience_build.py" \
  && ok "the strip markup carries the toggle (builder)" || bad "the strip markup carries the toggle (builder)"

# ── the push: notify.sh needs-you ──────────────────────────────────────────
NOTIFY="$REPO_DIR/scripts/notify.sh"
bash -n "$NOTIFY" && ok "notify.sh parses" || bad "notify.sh parses"
N_DIR="$TMP/notify"
mkdir -p "$N_DIR"
N_LIVE="$N_DIR/live.json"
N_STATE="$N_DIR/seen"
python3 - "$N_LIVE" <<'NFIX'
import json, sys
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc).replace(tzinfo=None)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


d = {"schema": "live/1", "view": "live", "needs_you": [
    # waited 15 min, verified: due at N=10. The text carries quotes and a
    # backslash on purpose: the toast never reads it, so none of it can leak.
    {"type": "critic_block", "text": 'Iris round 2 blocked by backend critic "quoted" \\ 3 findings',
     "action": "open the comment", "verified": True, "at": iso(now - timedelta(minutes=15)),
     "repo": "olympus-platform", "pr": 2829,
     "source": {"kind": "comment", "repo": "olympus-platform", "comment_id": 101, "pr": 2829,
                "stem": "BACKEND CRITIC", "round": 2, "verdict": "BLOCK-FIX"}},
    # waited 2 min: not due at N=10, due at N=1
    {"type": "failed_dispatch", "text": "W2-A security seat failed after 437 s",
     "action": "see the output", "verified": True, "at": iso(now - timedelta(minutes=2)),
     "repo": "olympus-platform",
     "source": {"kind": "stream", "dispatch_id": "d1", "event": "dispatch_end"}},
    # old but unverified: never
    {"type": "ready_to_merge", "text": "PR #2830 ready to merge", "action": "merge",
     "verified": False, "at": iso(now - timedelta(minutes=30)),
     "repo": "olympus-platform", "pr": 2830,
     "source": {"kind": "pr", "repo": "olympus-platform", "pr": 2830}},
    # no time: no proof of how long it waited, never
    {"type": "prd_proposed", "text": "S11 awaits sign-off", "action": "approve or edit",
     "verified": True, "at": None, "repo": "olympus-platform",
     "source": {"kind": "file", "checkout": "olympus-platform", "file": "docs/prd/x.md", "line": 3}},
]}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(d, fh)
NFIX

N_SHIM="$TMP/shim-osascript"
mkdir -p "$N_SHIM"
cat > "$N_SHIM/osascript" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$OSASCRIPT_CALLS"
EOF
chmod +x "$N_SHIM/osascript"
export OSASCRIPT_CALLS="$N_DIR/calls"
: > "$OSASCRIPT_CALLS"
on_mac=0; [ "$(uname)" = "Darwin" ] && on_mac=1
toasts() { wc -l < "$OSASCRIPT_CALLS" | tr -d ' '; }
# run_push [VAR=value ...]: the shim first on PATH, the silent switches unset,
# the seen file in TMP, the minutes var unset unless given.
run_push() {
  PATH="$N_SHIM:$PATH" env -u FLEET_NOTIFY_SILENT -u NOTIFY_SILENT -u FLEET_NOTIFY_NEEDS_YOU_MIN \
    FLEET_NOTIFY_NEEDS_YOU_STATE="$N_STATE" "$@" "$NOTIFY" needs-you "$N_LIVE"
}

# env var unset: nothing sent, nothing written
out=$(run_push 2>/dev/null) && ok "needs-you with the env var unset exits 0" || bad "needs-you with the env var unset exits 0"
[ -z "$out" ] && ok "env var unset: no stdout line" || bad "env var unset: no stdout line ($out)"
[ "$(toasts)" = "0" ] && ok "env var unset: osascript never invoked" || bad "env var unset: osascript never invoked"
[ ! -e "$N_STATE" ] && ok "env var unset: no seen file written" || bad "env var unset: no seen file written"

# N=10: the 15 min item notifies once, as the fixed phrase
out=$(run_push FLEET_NOTIFY_NEEDS_YOU_MIN=10 2>/dev/null)
[ "$(printf '%s\n' "$out" | grep -c '^\[notify\] Needs you: ')" = "1" ] \
  && ok "N=10: exactly one item pushed" || bad "N=10: exactly one item pushed ($out)"
[ "$out" = '[notify] Needs you: olympus-platform blocked by backend critic round 2 PR 2829' ] \
  && ok "the push carries the fixed phrase, never the item text" \
  || bad "the push carries the fixed phrase, never the item text ($out)"
case "$out" in
  *"W2-A"*|*"PR #2830"*|*"S11"*) bad "younger, unverified and undated items are not pushed" ;;
  *) ok "younger, unverified and undated items are not pushed" ;;
esac
[ "$(wc -l < "$N_STATE" | tr -d ' ')" = "1" ] && ok "the seen file records one item" || bad "the seen file records one item"
if [ "$on_mac" = "1" ]; then
  [ "$(toasts)" = "1" ] && ok "macOS: one osascript toast" || bad "macOS: one osascript toast ($(toasts))"
  grep -q 'with title "Needs you"' "$OSASCRIPT_CALLS" \
    && ok "macOS: the toast is titled Needs you" || bad "macOS: the toast is titled Needs you"
  grep -qF 'display notification "olympus-platform blocked by backend critic round 2 PR 2829"' "$OSASCRIPT_CALLS" \
    && ok "macOS: the toast argv is the fixed phrase exactly" \
    || bad "macOS: the toast argv is the fixed phrase exactly ($(cat "$OSASCRIPT_CALLS"))"
  grep -q 'quoted\|\\\\' "$OSASCRIPT_CALLS" \
    && bad "macOS: no quote or backslash from the item text reaches osascript" \
    || ok "macOS: no quote or backslash from the item text reaches osascript"
fi

# the same item again: never twice
out=$(run_push FLEET_NOTIFY_NEEDS_YOU_MIN=10 2>/dev/null)
[ -z "$out" ] && ok "second run: the same item is never pushed twice" || bad "second run: the same item is never pushed twice ($out)"
[ "$(wc -l < "$N_STATE" | tr -d ' ')" = "1" ] && ok "second run: seen file unchanged" || bad "second run: seen file unchanged"
if [ "$on_mac" = "1" ]; then
  [ "$(toasts)" = "1" ] && ok "macOS: still one toast" || bad "macOS: still one toast ($(toasts))"
fi

# N respected: at N=1 the 2 min item becomes due; the first stays seen
out=$(run_push FLEET_NOTIFY_NEEDS_YOU_MIN=1 2>/dev/null)
[ "$out" = '[notify] Needs you: olympus-platform failed dispatch' ] \
  && ok "N=1: the item that waited 2 min is now due, as the fixed phrase" \
  || bad "N=1: the item that waited 2 min is now due ($out)"
[ "$(printf '%s\n' "$out" | grep -c '^\[notify\] Needs you: ')" = "1" ] \
  && ok "N=1: only the newly due item, the seen one stays quiet" || bad "N=1: only the newly due item ($out)"
[ "$(wc -l < "$N_STATE" | tr -d ' ')" = "2" ] && ok "seen file now records two items" || bad "seen file now records two items"

# a bad value is a warning and nothing else
out=$(run_push FLEET_NOTIFY_NEEDS_YOU_MIN=soon 2>&1) && ok "a non-numeric value exits 0" || bad "a non-numeric value exits 0"
case "$out" in
  *"WARNING"*) ok "a non-numeric value warns" ;;
  *) bad "a non-numeric value warns ($out)" ;;
esac
[ "$(wc -l < "$N_STATE" | tr -d ' ')" = "2" ] && ok "a non-numeric value pushes nothing" || bad "a non-numeric value pushes nothing"

# a replay is history: nothing is pushed
rm -f "$N_STATE"
python3 - "$N_LIVE" "$N_DIR/replay.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["view"] = "replay"
json.dump(d, open(sys.argv[2], "w"))
PY
out=$(PATH="$N_SHIM:$PATH" env -u FLEET_NOTIFY_SILENT FLEET_NOTIFY_NEEDS_YOU_STATE="$N_STATE" FLEET_NOTIFY_NEEDS_YOU_MIN=1 \
  "$NOTIFY" needs-you "$N_DIR/replay.json" 2>/dev/null)
[ -z "$out" ] && ok "a replay view pushes nothing" || bad "a replay view pushes nothing ($out)"

# silenced: the stdout line and the seen record, no toast
rm -f "$N_STATE"
before=$(toasts)
out=$(PATH="$N_SHIM:$PATH" FLEET_NOTIFY_SILENT=1 FLEET_NOTIFY_NEEDS_YOU_STATE="$N_STATE" FLEET_NOTIFY_NEEDS_YOU_MIN=10 \
  "$NOTIFY" needs-you "$N_LIVE" 2>/dev/null)
[ "$(printf '%s\n' "$out" | grep -c '^\[notify\] Needs you: ')" = "1" ] \
  && ok "silenced: the stdout line still prints" || bad "silenced: the stdout line still prints ($out)"
[ "$(toasts)" = "$before" ] && ok "silenced: osascript not invoked" || bad "silenced: osascript not invoked"

# ── round 2 (the v3-C critic, two findings, the critic's own fixtures) ──────
echo "== Part L, round 2: a path in a PR title; one PR notified twice =="

# ONE: an operator path reached the toast through a PR title. The projector
# marks every slash token of a PR title (pr_view) and of every NEEDS YOU
# line (add) as it marks a task line; that scrubbed text is the page row.
# The toast no longer reads it at all (round 5): fixed phrases only.
assert_fn "mark_paths marks the critic's PR title like a task line and redacts the token" \
  'mod.scrub_text(mod.mark_paths("fix /Users/arlenrios/.ssh/id_rsa rotate $HOME ghp_abcdefghijklmnopqrstuvwxyz0123456789"), 120)=="fix outside-repo rotate $HOME [redacted]"'
assert_fn "mark_paths marks a home path, a variable path, a file: path and a parent escape" \
  'mod.mark_paths("see ~/.ssh/id_rsa and $HOME/x and file:/etc/passwd, (a/../b)")=="see outside-repo and outside-repo and outside-repo, (outside-repo)"'
assert_fn "mark_paths keeps a branch, a repo-relative path and a URL" \
  'mod.mark_paths("PR 7 ready: feat/x merges scripts/notify.sh https://example.invalid/pr/7")=="PR 7 ready: feat/x merges scripts/notify.sh https://example.invalid/pr/7"'
assert_fn "mark_paths flattens a tab or a newline before a path" \
  'mod.mark_paths("fix\t/Users/x/y\nnow")=="fix outside-repo now"'
# Round 3: a path glued to other characters is still a path. The critic's
# title (a colon before the slash), a markdown backtick wrapper, an equals
# sign, a variable and a parent escape inside the token.
assert_fn "round 3: mark_paths marks the critic's colon-glued title" \
  'mod.mark_paths("fix:/Users/arlenrios/.ssh/id_rsa rotate keys")=="fix:outside-repo rotate keys"'
assert_fn "round 3: mark_paths strips backticks like quotes and marks what they wrap" \
  'mod.mark_paths("fix `/Users/arlenrios/.ssh/id_rsa` and `~/.ssh` now")=="fix `outside-repo` and `outside-repo` now"'
assert_fn "round 3: mark_paths marks a path after an equals sign, a glued variable, a glued parent escape and a glued file:" \
  'mod.mark_paths("path=/Users/arlenrios/.ssh/id_rsa home=$HOME/x up=../y see:file:/etc/passwd")=="path=outside-repo home=outside-repo up=outside-repo see:outside-repo"'
assert_fn "round 3: mark_paths keeps a glued repo-relative path, a branch and a URL" \
  'mod.mark_paths("fix:scripts/notify.sh on feat/x key:value/w https://example.invalid/pr/7")=="fix:scripts/notify.sh on feat/x key:value/w https://example.invalid/pr/7"'
# Round 4: a percent-encoded slash is still a slash. The critic's title
# (%2FUsers%2F...), the lower-case form, the encoded file: URL, a doubly
# encoded slash, an encoded home, variable and parent escape.
assert_fn "round 4: mark_paths marks the critic's percent-encoded title" \
  'mod.mark_paths("fix %2FUsers%2Farlenrios%2F.ssh%2Fid_rsa rotate keys")=="fix outside-repo rotate keys"'
assert_fn "round 4: mark_paths marks the lower-case %2f form and the encoded file: URL" \
  'mod.mark_paths("fix %2fUsers%2farlenrios%2f.ssh%2fid_rsa see file:%2F%2F%2FUsers%2Farlenrios%2F.ssh%2Fid_rsa now")=="fix outside-repo see outside-repo now"'
assert_fn "round 4: mark_paths marks a doubly encoded slash, an encoded home, variable, parent escape and a glued encoded path" \
  'mod.mark_paths("a %252FUsers%252Fx b %7E%2F.ssh c %24HOME%2Fx d %2E%2E%2Fetc fix:%2FUsers%2Fx")=="a outside-repo b outside-repo c outside-repo d outside-repo fix:outside-repo"'
assert_fn "round 4: mark_paths keeps an encoded repo-relative path, branch and URL (decoded) and a percent that is no escape" \
  'mod.mark_paths("fix scripts%2Fnotify.sh on feat%2Fx https:%2F%2Fexample.invalid%2Fpr%2F7 at 50%25 or 100% or %zz")=="fix scripts/notify.sh on feat/x https://example.invalid/pr/7 at 50%25 or 100% or %zz"'
assert_fn "round 4: first_sentence is the same rule on an encoded path" \
  'mod.first_sentence("Fix %2FUsers%2Farlenrios%2F.ssh%2Fid_rsa now. Then the body.", 80)=="Fix outside-repo now."'
assert_fn "first_sentence is the same rule (the failed dispatch line)" \
  'mod.first_sentence("Fix /Users/arlenrios/.ssh/id_rsa and $HOME now. Then sk-abcdefghijklmnopqrstuvwxyz", 80)=="Fix outside-repo and $HOME now."'

# The product path: the Part K fixture, PR 102 titled as the critic wrote it,
# its SAFE comment body carrying a token and a path. gh answers through a
# wrapper that serves that one view and hands everything else to the K shim.
L2_BIN="$TMP/bin-l2"; mkdir -p "$L2_BIN"; L2_LOG="$TMP/gh-l2.log"
cat > "$L2_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr view 102" ]; then
  echo "$*" >> "${GH_SHIM_LOG:?}"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"number":102,"title":"fix /Users/arlenrios/.ssh/id_rsa rotate $HOME ghp_abcdefghijklmnopqrstuvwxyz0123456789","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/102","headRefName":"feat/k-ready","comments":[{"id":"IC_102_1","url":"https://example.invalid/pr/102#c1","createdAt":"%s","body":"CRITIC K READY: SAFE-TO-MERGE\\nsk-abcdefghijklmnopqrstuvwxyz0123456789 in /tmp/secret"}],"reviews":[]}\n' "$NOW"
  exit 0
fi
exec "${L2_INNER_GH:?}" "$@"
SHIM
chmod +x "$L2_BIN/gh"
L2_ON="$TMP/out/live-l2.json"; : > "$L2_LOG"
PATH="$L2_BIN:$PATH" GH_SHIM_LOG="$L2_LOG" L2_INNER_GH="$K_BIN/gh" FLEET_GH_OWNER=testowner FLEET_CHECKOUTS="$K_CO" \
  python3 "$DESK_LIVE" --once --events-dir "$K_DIR" --queue-file "$K_Q" --out "$L2_ON" >/dev/null 2>&1 \
  && ok "round 2: --once exits 0 with the critic's PR title" || bad "round 2: --once exits 0 with the critic's PR title"
grep -q '^pr view 102' "$L2_LOG" && ok "round 2: the wrapper served pr view 102" || bad "round 2: the wrapper served pr view 102"
assert_py "the ready_to_merge line marks the path and redacts the token" "$L2_ON" \
  '[e["text"] for e in d["needs_you"] if e["type"]=="ready_to_merge"]==["PR 102 ready to merge: fix outside-repo rotate $HOME [redacted]"]'
grep -q 'id_rsa\|/Users/\|ghp_abc\|sk-abc\|/tmp/secret' "$L2_ON" \
  && bad "no operator path, token or comment body anywhere in the projection" \
  || ok "no operator path, token or comment body anywhere in the projection"
# The push on that projection, the item aged past N as the critic did. The
# toast never reads the marked line: it is the fixed phrase with the item's
# identifiers, the page row keeps the scrubbed text.
L2_DIR="$N_DIR/round2"; mkdir -p "$L2_DIR"
python3 - "$L2_ON" "$L2_DIR/aged.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
d = json.load(open(sys.argv[1]))
at = (datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
for e in d["needs_you"]:
    e["at"] = at
json.dump(d, open(sys.argv[2], "w"))
PY
before=$(toasts)
out=$(PATH="$N_SHIM:$PATH" env -u FLEET_NOTIFY_SILENT -u NOTIFY_SILENT FLEET_NOTIFY_NEEDS_YOU_STATE="$L2_DIR/seen-product" \
  FLEET_NOTIFY_NEEDS_YOU_MIN=1 "$NOTIFY" needs-you "$L2_DIR/aged.json" 2>"$L2_DIR/aged.err")
case "$out" in
  *'[notify] Needs you: olympus-platform ready to merge PR 102'*) ok "the push carries the fixed phrase" ;;
  *) bad "the push carries the fixed phrase ($out)" ;;
esac
case "$out" in
  *"id_rsa"*|*"/Users/"*|*"ghp_abc"*|*"sk-abc"*|*"/tmp/secret"*|*"outside-repo"*) bad "the push carries no path, token, comment body or page text" ;;
  *) ok "the push carries no path, token, comment body or page text" ;;
esac
[ ! -s "$L2_DIR/aged.err" ] && ok "the fixed phrase needs no refusal" || bad "the fixed phrase needs no refusal ($(cat "$L2_DIR/aged.err"))"
if [ "$on_mac" = "1" ]; then
  [ "$(toasts)" -gt "$before" ] && ok "macOS: the product path toasts" || bad "macOS: the product path toasts"
  grep -q 'id_rsa\|/Users/\|ghp_abc\|sk-abc' "$OSASCRIPT_CALLS" \
    && bad "macOS: no osascript argv carries a path or a token" || ok "macOS: no osascript argv carries a path or a token"
fi

# Round 3, the product path: PR 102 served under the critic's colon-glued
# title through the same wrapper; the projection and the push carry the
# marker, not the path.
cat > "$L2_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr view 102" ]; then
  echo "$*" >> "${GH_SHIM_LOG:?}"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"number":102,"title":"fix:/Users/arlenrios/.ssh/id_rsa rotate keys","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/102","headRefName":"feat/k-ready","comments":[{"id":"IC_102_1","url":"https://example.invalid/pr/102#c1","createdAt":"%s","body":"CRITIC K READY: SAFE-TO-MERGE"}],"reviews":[]}\n' "$NOW"
  exit 0
fi
exec "${L2_INNER_GH:?}" "$@"
SHIM
chmod +x "$L2_BIN/gh"
L3_ON="$TMP/out/live-l3.json"
PATH="$L2_BIN:$PATH" GH_SHIM_LOG="$L2_LOG" L2_INNER_GH="$K_BIN/gh" FLEET_GH_OWNER=testowner FLEET_CHECKOUTS="$K_CO" \
  python3 "$DESK_LIVE" --once --events-dir "$K_DIR" --queue-file "$K_Q" --out "$L3_ON" >/dev/null 2>&1 \
  && ok "round 3: --once exits 0 with the colon-glued title" || bad "round 3: --once exits 0 with the colon-glued title"
assert_py "round 3: the ready_to_merge line marks the colon-glued path" "$L3_ON" \
  '[e["text"] for e in d["needs_you"] if e["type"]=="ready_to_merge"]==["PR 102 ready to merge: fix:outside-repo rotate keys"]'
grep -q 'id_rsa\|/Users/' "$L3_ON" \
  && bad "round 3: no operator path anywhere in the projection" \
  || ok "round 3: no operator path anywhere in the projection"

# Round 4, the product path: PR 102 served under the critic's percent-encoded
# title through the same wrapper; the projection carries the marker, not the
# path, encoded or not. (The push side of rounds 2 to 4 is one test below:
# the toast builder never reads the line.)
cat > "$L2_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr view 102" ]; then
  echo "$*" >> "${GH_SHIM_LOG:?}"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"number":102,"title":"fix %%2FUsers%%2Farlenrios%%2F.ssh%%2Fid_rsa rotate keys","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","url":"https://example.invalid/pr/102","headRefName":"feat/k-ready","comments":[{"id":"IC_102_1","url":"https://example.invalid/pr/102#c1","createdAt":"%s","body":"CRITIC K READY: SAFE-TO-MERGE"}],"reviews":[]}\n' "$NOW"
  exit 0
fi
exec "${L2_INNER_GH:?}" "$@"
SHIM
chmod +x "$L2_BIN/gh"
L4_ON="$TMP/out/live-l4.json"
PATH="$L2_BIN:$PATH" GH_SHIM_LOG="$L2_LOG" L2_INNER_GH="$K_BIN/gh" FLEET_GH_OWNER=testowner FLEET_CHECKOUTS="$K_CO" \
  python3 "$DESK_LIVE" --once --events-dir "$K_DIR" --queue-file "$K_Q" --out "$L4_ON" >/dev/null 2>&1 \
  && ok "round 4: --once exits 0 with the percent-encoded title" || bad "round 4: --once exits 0 with the percent-encoded title"
assert_py "round 4: the ready_to_merge line marks the percent-encoded path" "$L4_ON" \
  '[e["text"] for e in d["needs_you"] if e["type"]=="ready_to_merge"]==["PR 102 ready to merge: fix outside-repo rotate keys"]'
grep -qi 'id_rsa\|/Users/\|%2FUsers' "$L4_ON" \
  && bad "round 4: no operator path, encoded or not, anywhere in the projection" \
  || ok "round 4: no operator path, encoded or not, anywhere in the projection"

# ── round 5: the toast is fixed phrases and identifiers only ────────────────
echo "== Part L, round 5: the toast is fixed phrases and identifiers only =="
# Rounds 1 to 4 each found one more encoding of an operator path inside free
# text (a PR title, a comment body, a task line). Scrubbing free text for the
# toast was the losing game; the toast no longer reads any of it. One test
# stands in for the round 1 to 4 path fixtures: every earlier shape (plain,
# colon-glued, parentheses, percent-encoded, double and triple encoded,
# glued to a word) goes through the toast builder as the item's text, and
# the only acceptable output is the fixed phrase, exactly.
python3 - "$L2_DIR" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone
out = sys.argv[1]
at = (datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
def ready(pr, text):
    return {"type": "ready_to_merge", "text": text, "action": "merge",
            "verified": True, "at": at, "repo": "olympus-platform", "pr": pr,
            "source": {"kind": "pr", "repo": "olympus-platform", "pr": pr}}
shapes = [
    (102, "PR 102 ready to merge: fix /Users/arlenrios/.ssh/id_rsa rotate keys"),         # round 2: plain
    (103, "PR 103 ready to merge: fix:/Users/arlenrios/.ssh/id_rsa rotate keys"),         # round 3: colon-glued
    (104, "PR 104 ready to merge: fix (`~/.ssh/id_rsa`) and (a/../b) now"),               # parentheses and backticks
    (105, "PR 105 ready to merge: fix %2FUsers%2Farlenrios%2F.ssh%2Fid_rsa rotate"),      # round 4: percent-encoded
    (106, "PR 106 ready to merge: fix %252FUsers%252Farlenrios%252F.ssh%252Fid_rsa now"), # double encoded
    (107, "PR 107 ready to merge: fix %25252FUsers%25252Farlenrios%25252F.ssh now"),      # triple encoded
    (108, "PR 108 ready to merge: path=/Users/arlenrios/.ssh/id_rsa rotate keys"),        # round 3: glued to a word
]
items = [ready(pr, text) for pr, text in shapes]
# the critic-block shape: fixed phrase, stem word, round, PR number
items.append({"type": "critic_block", "text": "PR 80 round 2 blocked by FRONTEND CRITIC (BLOCK-FIX), see /Users/x",
              "action": "open the comment", "verified": True, "at": at,
              "repo": "dev-agents", "pr": 80,
              "source": {"kind": "comment", "repo": "dev-agents", "comment_id": 42, "pr": 80,
                         "stem": "FRONTEND CRITIC", "round": 2, "verdict": "BLOCK-FIX"}})
# a stem that is not plain words falls back to "critic", it never leaks
items.append({"type": "critic_block", "text": "blocked", "action": "open the comment",
              "verified": True, "at": at, "repo": "dev-agents", "pr": 81,
              "source": {"kind": "comment", "repo": "dev-agents", "comment_id": 43, "pr": 81,
                         "stem": "CRITIC /Users/arlenrios/.ssh", "round": 3, "verdict": "BLOCK-FIX"}})
# an item whose identifiers cannot carry the fixed shape is refused
items.append({"type": "quiet_seat", "text": "devops on feat/x quiet for 12 min",
              "action": "check the log", "verified": True, "at": at,
              "source": {"kind": "stream", "dispatch_id": "h9", "task_id": "3"}})
json.dump({"schema": "live/1", "view": "live", "needs_you": items}, open(os.path.join(out, "r5.json"), "w"))
PY
before=$(toasts)
out=$(PATH="$N_SHIM:$PATH" env -u FLEET_NOTIFY_SILENT -u NOTIFY_SILENT FLEET_NOTIFY_NEEDS_YOU_STATE="$L2_DIR/seen-r5" \
  FLEET_NOTIFY_NEEDS_YOU_MIN=1 "$NOTIFY" needs-you "$L2_DIR/r5.json" 2>"$L2_DIR/r5.err") \
  && ok "notify.sh exits 0 on a hand-written file full of path shapes" || bad "notify.sh exits 0 on a hand-written file full of path shapes"
expected='[notify] Needs you: olympus-platform ready to merge PR 102
[notify] Needs you: olympus-platform ready to merge PR 103
[notify] Needs you: olympus-platform ready to merge PR 104
[notify] Needs you: olympus-platform ready to merge PR 105
[notify] Needs you: olympus-platform ready to merge PR 106
[notify] Needs you: olympus-platform ready to merge PR 107
[notify] Needs you: olympus-platform ready to merge PR 108
[notify] Needs you: dev-agents blocked by frontend critic round 2 PR 80
[notify] Needs you: dev-agents blocked by critic round 3 PR 81'
[ "$out" = "$expected" ] \
  && ok "every round 1 to 4 shape through the toast builder is exactly the fixed phrase" \
  || bad "every round 1 to 4 shape through the toast builder is exactly the fixed phrase ($out)"
case "$out" in
  *"/Users/"*|*"id_rsa"*|*"~/"*|*"%2F"*|*"%25"*|*"outside-repo"*) bad "no path shape, encoded or not, reaches the push" ;;
  *) ok "no path shape, encoded or not, reaches the push" ;;
esac
[ "$(grep -c 'WARNING: needs-you item .* refused' "$L2_DIR/r5.err")" = "1" ] \
  && ok "the item with no repo identifier is refused, one stderr line" \
  || bad "the item with no repo identifier is refused, one stderr line ($(cat "$L2_DIR/r5.err"))"
[ "$(wc -l < "$L2_DIR/seen-r5" | tr -d ' ')" = "9" ] \
  && ok "nine items seen, the refused one is not recorded" \
  || bad "nine items seen, the refused one is not recorded ($(wc -l < "$L2_DIR/seen-r5"))"
if [ "$on_mac" = "1" ]; then
  [ "$(toasts)" = "$((before + 9))" ] && ok "macOS: nine toasts, one per item, nothing for the refused one" \
    || bad "macOS: nine toasts, one per item ($(( $(toasts) - before )))"
  grep -qi 'id_rsa\|/Users/\|\.ssh\|%2F\|%25' "$OSASCRIPT_CALLS" \
    && bad "macOS: no osascript argv carries a path shape, encoded or not" \
    || ok "macOS: no osascript argv carries a path shape, encoded or not"
fi

# TWO: ready_to_merge notified twice for one PR because the seen key hashed
# the whole source, comments[] included. The key is now the stable identity:
# type, source kind, and the comment id / repo and PR / dispatch and seat /
# checkout, file and line. A later SAFE comment on the same PR, a changed url
# or a fresh heartbeat timestamp is the same item; a new block comment is not.
python3 - "$L2_DIR" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone
out = sys.argv[1]
now = datetime.now(timezone.utc)
def iso(m): return (now - timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
c1 = {"kind": "comment", "id": "IC_1", "verdict": "SAFE-TO-MERGE", "round": 1, "stem": "CRITIC K", "at": iso(30)}
c2 = {"kind": "review", "id": "PRR_2", "verdict": "SAFE-TO-MERGE", "round": 1, "stem": "SECURITY CRITIC K", "at": iso(20)}
def write(name, *items):
    json.dump({"schema": "live/1", "view": "live", "needs_you": list(items)}, open(os.path.join(out, name), "w"))
def ready(comments, at):
    return {"type": "ready_to_merge", "text": "PR 102 ready to merge: the ready PR", "action": "merge",
            "verified": True, "at": at, "source": {"kind": "pr", "repo": "olympus-platform", "pr": 102,
            "url": "https://example.invalid/pr/102", "merge_state": "CLEAN", "comments": comments}}
def block(cid, rnd, url):
    return {"type": "critic_block", "text": "PR 102 round %d blocked by critic k (BLOCK-FIX)" % rnd, "action": "open the comment",
            "verified": True, "at": iso(25), "source": {"kind": "comment", "repo": "olympus-platform", "comment_id": cid,
            "url": url, "pr": 102, "issue": 900, "verdict": "BLOCK-FIX", "round": rnd, "stem": "CRITIC K"}}
def quiet(event, ts):
    return {"type": "quiet_seat", "text": "devops on feat/k-quiet quiet for 12 min", "action": "check the log",
            "verified": True, "at": ts, "repo": "olympus-platform",
            "source": {"kind": "stream", "dispatch_id": "k-live", "event": event, "task_id": "7", "ts": ts}}
write("pr-one.json", ready([c1], iso(30)))
write("pr-two.json", ready([c1, c2], iso(20)))          # a second SAFE verdict landed
write("block-a.json", block("IC_9001", 1, "https://example.invalid/pr/102#c1"))
write("block-a-url.json", block("IC_9001", 1, "https://example.invalid/pr/102#issuecomment-9001"))
write("block-b.json", block("IC_9002", 2, "https://example.invalid/pr/102#c2"))   # a new round, a new item
write("quiet-1.json", quiet("seat_dispatch", iso(40)))
write("quiet-2.json", quiet("seat_heartbeat", iso(15)))  # one heartbeat, quiet again
PY
L2_SEEN="$L2_DIR/seen-identity"; rm -f "$L2_SEEN"
push_l2() {   # push_l2 <file>: N=1, the shim on PATH, the identity seen file
  PATH="$N_SHIM:$PATH" env -u FLEET_NOTIFY_SILENT -u NOTIFY_SILENT FLEET_NOTIFY_NEEDS_YOU_STATE="$L2_SEEN" \
    FLEET_NOTIFY_NEEDS_YOU_MIN=1 "$NOTIFY" needs-you "$L2_DIR/$1" 2>/dev/null
}
lines() { printf '%s\n' "$1" | grep -c '^\[notify\] Needs you: '; }
before=$(toasts)
out=$(push_l2 pr-one.json)
[ "$(lines "$out")" = "1" ] && ok "PR 102 ready: pushed once" || bad "PR 102 ready: pushed once ($out)"
out=$(push_l2 pr-two.json)
[ -z "$out" ] && ok "a second SAFE comment on the same PR is not a second toast" \
  || bad "a second SAFE comment on the same PR is not a second toast ($out)"
[ "$(wc -l < "$L2_SEEN" | tr -d ' ')" = "1" ] && ok "the seen file still holds one line for PR 102" \
  || bad "the seen file still holds one line for PR 102 ($(wc -l < "$L2_SEEN"))"
out=$(push_l2 block-a.json)
[ "$(lines "$out")" = "1" ] && ok "a block on the same PR is its own item (comment id)" || bad "a block on the same PR is its own item ($out)"
out=$(push_l2 block-a-url.json)
[ -z "$out" ] && ok "the same block comment with a changed url is not pushed again" \
  || bad "the same block comment with a changed url is not pushed again ($out)"
out=$(push_l2 block-b.json)
[ "$(lines "$out")" = "1" ] && ok "a new block comment (new id, new round) is a new item" || bad "a new block comment is a new item ($out)"
out=$(push_l2 quiet-1.json)
[ "$(lines "$out")" = "1" ] && ok "a quiet seat is pushed once" || bad "a quiet seat is pushed once ($out)"
out=$(push_l2 quiet-2.json)
[ -z "$out" ] && ok "the same seat quiet again after one heartbeat (new event, new ts) is not pushed again" \
  || bad "the same seat quiet again after one heartbeat is not pushed again ($out)"
[ "$(wc -l < "$L2_SEEN" | tr -d ' ')" = "4" ] && ok "four identities seen: the PR, two blocks, the seat" \
  || bad "four identities seen ($(wc -l < "$L2_SEEN"))"
if [ "$on_mac" = "1" ]; then
  [ "$(toasts)" = "$((before + 4))" ] && ok "macOS: four toasts, never a fifth" || bad "macOS: four toasts, never a fifth ($(( $(toasts) - before )))"
fi
grep -q 'comments\[\]\|comments array\|whole source' "$NOTIFY" \
  && ok "notify.sh states the key rule" || bad "notify.sh states the key rule"

# a missing projection is nothing to push
FLEET_NOTIFY_NEEDS_YOU_MIN=10 FLEET_NOTIFY_NEEDS_YOU_STATE="$N_STATE" "$NOTIFY" needs-you "$N_DIR/absent.json" >/dev/null 2>&1 \
  && ok "a missing live.json exits 0" || bad "a missing live.json exits 0"

# the seat-outcome path is unchanged
out=$(FLEET_NOTIFY_SILENT=1 "$NOTIFY" devops mac-mini-1 feat/x success 2>/dev/null)
case "$out" in
  *"[notify] Agent Succeeded: devops on mac-mini-1 completed (feat/x)"*) ok "seat outcome path unchanged" ;;
  *) bad "seat outcome path unchanged ($out)" ;;
esac

# the wiring: desk_live.py hands every written projection to notify.sh,
# only when the env var is set (the seen file is the trace)
W_STATE="$N_DIR/wired-seen"
env -u FLEET_NOTIFY_NEEDS_YOU_MIN FLEET_NOTIFY_NEEDS_YOU_STATE="$W_STATE" \
  python3 "$DESK_LIVE" --once --no-gh --events-dir "$Y_DIR" --queue-file "$TMP/no-queue.json" --out "$TMP/out/wired.json" >/dev/null 2>&1
[ ! -e "$W_STATE" ] && ok "desk_live.py --once with the env var unset never calls the push" \
  || bad "desk_live.py --once with the env var unset never calls the push"
FLEET_NOTIFY_SILENT=1 FLEET_NOTIFY_NEEDS_YOU_MIN=10 FLEET_NOTIFY_NEEDS_YOU_STATE="$W_STATE" \
  python3 "$DESK_LIVE" --once --no-gh --events-dir "$Y_DIR" --queue-file "$TMP/no-queue.json" --out "$TMP/out/wired.json" >/dev/null 2>&1 \
  && ok "desk_live.py --once with the env var set exits 0" || bad "desk_live.py --once with the env var set exits 0"
[ -e "$W_STATE" ] && ok "desk_live.py --once with the env var set calls the push (seen file created)" \
  || bad "desk_live.py --once with the env var set calls the push (seen file created)"
[ "$(grep -c 'push_needs_you(out_path)' "$REPO_DIR/scripts/desk_live.py")" -ge 3 ] \
  && ok "the push follows every write path (once, watch, serve)" || bad "the push follows every write path (once, watch, serve)"

for key in 'yesterday\[\]' 'yesterday_meta' 'FLEET_NOTIFY_NEEDS_YOU_MIN'; do
  grep -q "$key" "$REPO_DIR/docs/experience-data.md" \
    && ok "$key is documented in the live schema" || bad "$key is documented in the live schema"
done
grep -q 'fixed phrases and identifiers only' "$REPO_DIR/docs/experience-data.md" \
  && ok "the fixed-phrase toast rule is documented in the live schema" \
  || bad "the fixed-phrase toast rule is documented in the live schema"
grep -q 'FLEET_NOTIFY_NEEDS_YOU_MIN' "$REPO_DIR/README.md" \
  && ok "FLEET_NOTIFY_NEEDS_YOU_MIN is in the README" || bad "FLEET_NOTIFY_NEEDS_YOU_MIN is in the README"

echo ""
echo "----------------------------------------"
echo "  passed: $pass   failed: $fail"
echo "----------------------------------------"
[ "$fail" -eq 0 ] || exit 1
