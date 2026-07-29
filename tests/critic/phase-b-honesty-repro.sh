#!/usr/bin/env bash
# Fleet Desk v2 Phase B — critic repro (RED on 99e9fee).
#
# Two executable failures against laws this PR states about itself:
#   R1  scripts/desk_live.py:19  "a stream that stopped updating reads STALE,
#       then OFFLINE — never 'live'".  The build-time renderer copies
#       staleness.state out of live.json instead of deriving it, so a run that
#       ended days ago renders a green LED, "last event 4s ago", and an
#       in-flight seat timer.  (experience_build.py:1006,1027,1029,1190)
#   R2  scripts/dispatch.sh:543  "Honest close-out even on Ctrl-C".  Regression
#       guard on the close-out path, which had no executing assertion (deleting
#       the trap left `make test` green).  NOTE (loop 2): the loop-1 form of this
#       test was invalid -- it backgrounded the harness, where SIGINT is SIG_IGN
#       and untrappable, so it reported a defect that does not exist.  Under real
#       Ctrl-C conditions (foreground child) bash DOES run the EXIT trap and the
#       stream is closed -- verified on both 99e9fee and the revision.
#
# Run:  bash tests/critic/phase-b-honesty-repro.sh
# Wire into `make test` once green.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "== R1: a 3-day-old run must not render as live =="

OUT="$TMP/site"
EV="$TMP/events"
mkdir -p "$OUT" "$EV"
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$REPO_DIR" --out "$OUT" --no-gh >/dev/null 2>&1

# live.json exactly as scripts/desk_live.py wrote it during a dispatch 3 days
# ago (state "live", seconds 4) and left behind in site/experience/data/,
# which `make experience` preserves (experience_build.py clean_html keeps data/).
python3 - "$REPO_DIR" "$EV" "$OUT/data/live.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
repo, evdir, out = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, repo + "/scripts")
import desk_live
then = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=3)
def ts(o): return (then + timedelta(seconds=o)).strftime("%Y-%m-%dT%H:%M:%SZ")
did = "20260726-090000-dev-agents"
rows = [
 {"schema":"fleet-events/1","seq":1,"ts":ts(0),"dispatch_id":did,"event":"dispatch_start",
  "mode":"wave","repo":"dev-agents","plan":"phase-b.plan"},
 {"schema":"fleet-events/1","seq":2,"ts":ts(1),"dispatch_id":did,"event":"dispatch_plan",
  "waves":1,"seats":1,"format":"wave"},
 {"schema":"fleet-events/1","seq":3,"ts":ts(2),"dispatch_id":did,"event":"wave_start",
  "wave":1,"seats":1,"mode":"wave"},
 {"schema":"fleet-events/1","seq":4,"ts":ts(3),"dispatch_id":did,"event":"seat_dispatch",
  "task_id":"0","agent":"devops","branch":"feat/x","wave":1,"provider":"claude","worker":"mac-mini-1"},
]
with open(evdir + "/" + did + ".jsonl", "w") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
open(evdir + "/latest", "w").write(did + ".jsonl\n")
# projected at the last poll of that session, i.e. 7s after dispatch start
desk_live.write_projection(desk_live.build(evdir, now=then + timedelta(seconds=7)), out)
PY

python3 "$REPO_DIR/scripts/experience_build.py" --repo "$REPO_DIR" --out "$OUT" >/dev/null 2>&1
FL="$OUT/live/index.html"
HOME_PAGE="$OUT/index.html"

grep -q 'class="led live" id="floor-led"' "$FL" \
  && bad "Ops Floor LED is not green for a 3-day-old stream" \
  || ok  "Ops Floor LED is not green for a 3-day-old stream"

grep -qE 'last event [0-9]{1,2}s ago' "$FL" \
  && bad "ambient row does not claim 'last event <seconds> ago' 3 days later" \
  || ok  "ambient row does not claim 'last event <seconds> ago' 3 days later"

grep -qE 'stream (stale|offline)' "$FL" \
  && ok  "floor labels the dead stream stale/offline" \
  || bad "floor labels the dead stream stale/offline"

# The home teaser carries no poller (floor.js is injected only by live_page),
# so nothing can ever correct it — not even under `make desk-live`.
grep -q 'st st-run">live</span> dispatch' "$HOME_PAGE" \
  && bad "home teaser does not advertise a 3-day-old run as live" \
  || ok  "home teaser does not advertise a 3-day-old run as live"

echo ""
echo "== R2: Ctrl-C on a dispatch must still close the stream =="

# Execute the producer's own trap wiring: every trap line in dispatch.sh that
# references fleet_close_dispatch is replayed in a harness shaped like the
# inter-wave gate (dispatch.sh:1024 `read -r`), then SIGINT'd.
TRAPS="$(grep -E "^trap .*fleet_close_dispatch" "$REPO_DIR/scripts/dispatch.sh" || true)"
[ -n "$TRAPS" ] && ok "dispatch.sh installs a close-out trap" || bad "dispatch.sh installs a close-out trap"

FIFO="$TMP/gate.fifo"; mkfifo "$FIFO"
cat > "$TMP/harness.sh" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
FLEET_DISPATCH_CLOSED=false
fleet_close_dispatch() {
    [ "\$FLEET_DISPATCH_CLOSED" = true ] && return 0
    FLEET_DISPATCH_CLOSED=true
    echo "dispatch_end status=\${1:-aborted}" >> "$TMP/closeout.txt"
}
$TRAPS
echo \$\$ > "$TMP/harness.pid"
read -r answer
HARNESS

# The harness MUST run in the FOREGROUND (loop-2 correction).
# An async (&) command in a non-interactive shell inherits SIGINT/SIGQUIT as
# SIG_IGN (POSIX 2.11), and bash cannot trap a signal that was ignored at
# entry: `trap -p INT` in such a child reports `trap -- '' SIGINT`. Measured:
#
#   bash child started with &   -> trap -p INT => trap -- '' SIGINT   (INT never fires)
#   bash child in foreground    -> SIGINT during `read`/`wait` => EXIT trap RUNS, exit 130
#
# So backgrounding this harness measures the harness, not dispatch.sh, and the
# assertion below can never pass regardless of the producer's trap wiring.
cat > "$TMP/outer.sh" <<OUTER
#!/usr/bin/env bash
( for _ in \$(seq 1 60); do [ -f "$TMP/harness.pid" ] && break; sleep 0.1; done
  sleep 0.3; kill -INT "\$(cat "$TMP/harness.pid")" 2>/dev/null
  sleep 2;   kill -KILL "\$(cat "$TMP/harness.pid")" 2>/dev/null ) &
bash "$TMP/harness.sh" <> "$FIFO" >/dev/null 2>&1
OUTER

rm -f "$TMP/closeout.txt" "$TMP/harness.pid"
bash "$TMP/outer.sh" >/dev/null 2>&1

if grep -q 'dispatch_end' "$TMP/closeout.txt" 2>/dev/null; then
  ok  "SIGINT (Ctrl-C) emits dispatch_end — the Floor stops showing 'running'"
else
  bad "SIGINT (Ctrl-C) emits dispatch_end — the Floor stops showing 'running'"
fi

echo ""
echo "----------------------------------------"
echo "  passed: $pass   failed: $fail"
echo "----------------------------------------"
[ "$fail" -eq 0 ] || exit 1
