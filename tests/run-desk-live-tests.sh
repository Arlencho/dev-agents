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
  'any(w.get("kind")=="seat" and w.get("task_id")=="2" for w in W)'
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


def ts(delta_s):
    return (now - timedelta(seconds=delta_s)).strftime("%Y-%m-%dT%H:%M:%SZ")


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
     "branch": "feat/alpha", "wave": 1, "provider": "claude"},
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
     "branch": "feat/beta", "wave": 1, "provider": "claude"},
])
# live now (second, concurrent)
write("day-live-b.jsonl", [
    {"ts": ts(90), "event": "dispatch_start", "mode": "wave",
     "repo": "olympus-platform", "plan": "gamma.plan"},
    {"ts": ts(80), "event": "seat_dispatch", "task_id": "0", "agent": "web-frontend",
     "branch": "feat/gamma", "wave": 1, "provider": "kimi"},
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


def ts(d):
    return (now - timedelta(seconds=d)).strftime("%Y-%m-%dT%H:%M:%SZ")


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
def ts(d):
    return (now - timedelta(seconds=d)).strftime("%Y-%m-%dT%H:%M:%SZ")
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
echo ""
echo "----------------------------------------"
echo "  passed: $pass   failed: $fail"
echo "----------------------------------------"
[ "$fail" -eq 0 ] || exit 1
