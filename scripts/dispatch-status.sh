#!/usr/bin/env bash
# One dispatch, one look: is it running, how did it end, what did each seat do,
# what did it last print. Reads only what the run itself wrote:
#
#   logs/dispatch-runs/<id>.pid      written by dispatch.sh --detach (pid, repo,
#                                    plan, start time, one per line)
#   logs/dispatch-runs/<id>.exit     the run's exit code, written on its way out
#   logs/dispatch-runs/<id>.log      the run's output (last ten lines shown)
#   logs/fleet-events/<id>.jsonl     the event stream (seat table, final status)
#
# Usage:
#   scripts/dispatch-status.sh <dispatch id>
#
# Exit codes, so a caller can poll:
#   0  the run has ended (completed, aborted, or died without a close-out)
#   3  still running
#   2  no such dispatch (neither a pid file nor an event stream), or bad usage
#
# An attached run (no --detach) has no pid file; it is reported from its event
# stream alone and counts as running until its dispatch_end event appears.
#
# Override the directories with DISPATCH_RUNS_DIR and FLEET_EVENTS_DIR, the
# same variables dispatch.sh and fleet-events.sh honour.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RUNS_DIR="${DISPATCH_RUNS_DIR:-$REPO_DIR/logs/dispatch-runs}"
EVENTS_DIR="${FLEET_EVENTS_DIR:-$REPO_DIR/logs/fleet-events}"

ID="${1:-}"
if [ -z "$ID" ] || [ "$ID" = "-h" ] || [ "$ID" = "--help" ]; then
    echo "Usage: dispatch-status.sh <dispatch id>   (exit 0 ended, 3 running, 2 unknown)" >&2
    exit 2
fi
case "$ID" in
    */*|*..*) echo "dispatch-status.sh: '$ID' is not a dispatch id" >&2; exit 2 ;;
esac

PID_FILE="$RUNS_DIR/$ID.pid"
EXIT_FILE="$RUNS_DIR/$ID.exit"
LOG_FILE="$RUNS_DIR/$ID.log"
EVENTS_FILE="$EVENTS_DIR/$ID.jsonl"

if [ ! -f "$PID_FILE" ] && [ ! -f "$EVENTS_FILE" ]; then
    echo "dispatch $ID: unknown (no $PID_FILE, no $EVENTS_FILE)" >&2
    exit 2
fi

# ---- liveness --------------------------------------------------------------
pid="" repo="" plan="" since=""
if [ -f "$PID_FILE" ]; then
    { read -r pid; read -r repo; read -r plan; read -r since; } < "$PID_FILE"
fi
exit_code=""
[ -f "$EXIT_FILE" ] && exit_code="$(head -n 1 "$EXIT_FILE" 2>/dev/null | tr -d ' ')"

ended_event="$(grep -c '"event":"dispatch_end"' "$EVENTS_FILE" 2>/dev/null || true)"
ended_event="${ended_event:-0}"

alive=""
if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; fi
fi

# state: running | ended
if [ "$alive" = yes ]; then
    state=running
elif [ "$alive" = no ]; then
    state=ended
elif [ "$ended_event" -gt 0 ]; then
    state=ended
else
    state=running   # attached run, no pid on file, no close-out yet
fi

# ---- summary + seat table from the event stream ----------------------------
# Fold seat_dispatch / seat_heartbeat / seat_exit per task_id; the last word
# wins. python3 is already a dependency of queue.sh; awk would have to parse
# JSON. Output: a "final:" line (when dispatch_end exists) and the table.
fold_events() {
    [ -f "$EVENTS_FILE" ] || { echo "  (no event stream yet: the run has not reached its plan)"; return 0; }
    command -v python3 >/dev/null 2>&1 || { echo "  (python3 not found: cannot fold $EVENTS_FILE)"; return 0; }
    python3 - "$EVENTS_FILE" <<'PY'
import json, sys

seats = {}
order = []
final = None
start_ts = None
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    raw = raw.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except ValueError:
        continue
    kind = ev.get("event")
    if kind == "dispatch_start":
        start_ts = ev.get("ts")
    elif kind == "dispatch_end":
        final = ev
    elif kind in ("seat_dispatch", "seat_heartbeat", "seat_exit", "failover", "ratecap"):
        tid = str(ev.get("task_id", "?"))
        if tid not in seats:
            seats[tid] = {"task_id": tid}
            order.append(tid)
        seat = seats[tid]
        for key in ("wave", "agent", "branch", "provider", "worker", "attempt"):
            if ev.get(key) not in (None, ""):
                seat[key] = ev[key]
        if kind == "seat_dispatch":
            seat["status"] = "running"
            seat["elapsed"] = 0
        elif kind == "seat_heartbeat":
            seat["elapsed"] = ev.get("elapsed_s", seat.get("elapsed", 0))
        elif kind == "seat_exit":
            seat["status"] = ev.get("status", "?")
            seat["exit"] = ev.get("exit")
            seat["elapsed"] = ev.get("duration_s", seat.get("elapsed", 0))
        elif kind == "ratecap":
            seat["status"] = "ratecap"

if final is not None:
    print("final: %s  %s/%s succeeded, %s failed, %ss" % (
        final.get("status", "?"), final.get("succeeded", "?"), final.get("total", "?"),
        final.get("failed", "?"), final.get("duration_s", "?")))
elif start_ts:
    print("final: (no dispatch_end yet; stream opened %s)" % start_ts)

if not seats:
    print("  (no seats dispatched yet)")
    sys.exit(0)

def key(tid):
    try:
        return int(tid)
    except ValueError:
        return 1 << 30

rows = [("#", "wave", "agent", "branch", "provider", "worker", "status", "time")]
for tid in sorted(order, key=key):
    s = seats[tid]
    status = str(s.get("status", "?"))
    if s.get("exit") not in (None, "", 0) and status not in ("running", "success"):
        status = "%s(%s)" % (status, s["exit"])
    if int(s.get("attempt", 1) or 1) > 1:
        status = "%s a%s" % (status, s["attempt"])
    rows.append((tid, str(s.get("wave", "")), str(s.get("agent", "")), str(s.get("branch", "")),
                 str(s.get("provider", "")), str(s.get("worker", "")), status,
                 "%ss" % s.get("elapsed", 0)))
widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
for r in rows:
    print("  " + "  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
PY
}

folded="$(fold_events)"
final_line="$(printf '%s\n' "$folded" | sed -n '1{/^final: /p;}' | sed 's/^final: //')"
table="$(printf '%s\n' "$folded" | sed '1{/^final: /d;}')"

# ---- headline --------------------------------------------------------------
if [ "$state" = running ]; then
    if [ -n "$pid" ]; then
        echo "dispatch $ID: running  (pid $pid, ${repo:-repo?}, ${plan:-plan?}, since ${since:-?})"
    else
        echo "dispatch $ID: running  (attached run: no pid file, no dispatch_end yet)"
    fi
else
    if [ -n "$final_line" ] && [ "${final_line#(}" = "$final_line" ]; then
        verdict="$final_line"
    else
        verdict="died without a close-out (no dispatch_end event; killed?)"
    fi
    [ -n "$exit_code" ] && verdict="$verdict, exit $exit_code"
    if [ -n "$pid" ]; then
        echo "dispatch $ID: ended  $verdict  (pid $pid gone, ${repo:-repo?}, ${plan:-plan?})"
    else
        echo "dispatch $ID: ended  $verdict"
    fi
fi

echo "seats:"
printf '%s\n' "$table"

echo "log ($LOG_FILE, last 10 lines):"
if [ -f "$LOG_FILE" ]; then
    tail -n 10 "$LOG_FILE" | sed 's/^/  /'
else
    echo "  (no run log: not a detached run)"
fi

[ "$state" = running ] && exit 3
exit 0
