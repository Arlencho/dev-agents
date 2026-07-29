#!/usr/bin/env python3
"""Fleet Desk v2 — Ops Floor live watcher + Phase C replay.

Tails the append-only dispatch event stream (``logs/fleet-events/*.jsonl``,
schema ``fleet-events/1``) and folds it into a small projection at
``site/experience/data/live.json`` (schema ``live/1``) that the Ops Floor
reads. Optionally serves ``site/experience/`` over localhost with an SSE
channel at ``/events`` so the page updates without polling.

Phase C adds settled-run **replay**: truncate the stream at ``as_of_seq``,
mark ``view=replay`` with an honesty watermark so the Floor never looks live
while scrubbing history.

    make desk-live                    serve + watch (http://127.0.0.1:8777/live/)
    python3 scripts/desk_live.py --once     write live.json once and exit
    python3 scripts/desk_live.py --once --dispatch-id ID --as-of-seq N --replay

Law: docs/proposals/fleet-desk-v2-SYNTHESIS.md §3 Phases B+C
Schema: docs/experience-data.md § Live event stream

Honesty rules (do not weaken):
  * only facts present in the stream are projected — no invented seats
  * live state never enters ``data/index.json`` (the settled Almanac contract)
  * a stream that stopped updating reads STALE, then OFFLINE — never "live"
  * replay projections never claim LIVE — ``view=replay`` + watermark
  * stdlib only; no network access; binds loopback only

Python 3.8+ (stdlib only).
"""

import argparse
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone

SCHEMA = "live/1"
EVENT_SCHEMA_PREFIX = "fleet-events/"
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_EVENTS_DIR = os.path.join(REPO_DIR, "logs", "fleet-events")
DEFAULT_SITE_DIR = os.path.join(REPO_DIR, "site", "experience")
DEFAULT_PORT = 8777
DEFAULT_INTERVAL = 2.0
STALE_AFTER = 120     # seconds without an event → STALE chrome
OFFLINE_AFTER = 900   # seconds without an event → OFFLINE chrome
RECENT_EVENTS = 50    # tail kept in the projection (already redaction-safe)

ISO = "%Y-%m-%dT%H:%M:%SZ"

# Seat status vocabulary, mapped to the pipeline language of the desk.
PIPELINE = {
    "queued": "queued",
    "running": "in_flight",
    "success": "settled",
    "failed": "blocked",
    "blocked": "blocked",
    "ratecap": "blocked",
    "unavailable": "blocked",
}


# ── time helpers ────────────────────────────────────────────────────────────

def utcnow():
    """Naive UTC now (event timestamps are naive UTC ISO-8601 with a Z)."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def rel(path):
    """Repo-relative path when possible; absolute paths never enter the JSON."""
    try:
        return os.path.relpath(path, REPO_DIR)
    except ValueError:
        return os.path.basename(path)


def parse_ts(value):
    """Parse an event timestamp; return None when unparseable (never raise)."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, ISO)
    except ValueError:
        return None


def fmt_ts(dt):
    return dt.strftime(ISO) if dt else None


# ── stream discovery ────────────────────────────────────────────────────────

def resolve_stream(events_dir, dispatch_id=None):
    """Return (path, dispatch_id) for the stream to project, or (None, None).

    Order: explicit --dispatch-id, then the ``latest`` pointer file written by
    fleet-events.sh, then the newest ``*.jsonl`` by mtime.
    """
    if dispatch_id:
        name = dispatch_id if dispatch_id.endswith(".jsonl") else dispatch_id + ".jsonl"
        path = os.path.join(events_dir, name)
        return (path, name[:-6]) if os.path.exists(path) else (None, None)

    pointer = os.path.join(events_dir, "latest")
    if os.path.isfile(pointer):
        try:
            with open(pointer, "r", encoding="utf-8") as fh:
                name = fh.read().strip()
        except OSError:
            name = ""
        # Pointer must stay inside the events dir — never follow it elsewhere.
        if name and "/" not in name and name.endswith(".jsonl"):
            path = os.path.join(events_dir, name)
            if os.path.exists(path):
                return path, name[:-6]

    try:
        candidates = [
            os.path.join(events_dir, n)
            for n in os.listdir(events_dir)
            if n.endswith(".jsonl")
        ]
    except OSError:
        return None, None
    if not candidates:
        return None, None
    newest = max(candidates, key=lambda p: os.path.getmtime(p))
    return newest, os.path.basename(newest)[:-6]


def read_events(path):
    """Read a JSONL stream. Returns (events, malformed_line_count)."""
    events, malformed = [], 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    malformed += 1
                    continue
                if isinstance(obj, dict) and isinstance(obj.get("event"), str):
                    events.append(obj)
                else:
                    malformed += 1
    except OSError:
        return [], 0
    return events, malformed


# ── projection ──────────────────────────────────────────────────────────────

def empty_projection(now=None, reason="no dispatch has emitted events yet"):
    now = now or utcnow()
    return {
        "schema": SCHEMA,
        "generated_at": fmt_ts(now),
        "generator": "scripts/desk_live.py",
        "dispatch_id": None,
        "source": None,
        "repo": None,
        "plan": None,
        "mode": "wave",
        "status": "idle",
        "reason": reason,
        "started_at": None,
        "ended_at": None,
        "wave": {"current": None, "total": None},
        "seats": [],
        "counts": {"queued": 0, "in_flight": 0, "blocked": 0, "settled": 0, "total": 0},
        "waiting_on": [],
        "last_event_ts": None,
        "staleness": {"seconds": None, "state": "none",
                      "stale_after_s": STALE_AFTER, "offline_after_s": OFFLINE_AFTER},
        "events_seen": 0,
        "recent_events": [],
        "warnings": [],
        "view": "live",  # "live" | "replay" — replay never paints a green LIVE LED
        "replay": None,
    }


TERMINAL_STATUSES = frozenset(("settled", "aborted", "completed", "failed"))


def mark_replay(proj, as_of_seq, total_events):
    """Stamp a projection as historical replay — never LIVE, always watermarked."""
    proj["view"] = "replay"
    # Force non-live chrome: age is still useful for "how far into the past",
    # but state is always "replay" so Floor honesty watermark fires.
    age = (proj.get("staleness") or {}).get("seconds")
    proj["staleness"] = {
        "seconds": age,
        "state": "replay",
        "stale_after_s": STALE_AFTER,
        "offline_after_s": OFFLINE_AFTER,
    }
    max_seq = total_events
    # Prefer explicit event seq numbers when present.
    seqs = [e.get("seq") for e in (proj.get("recent_events") or []) if isinstance(e.get("seq"), int)]
    if as_of_seq is not None and isinstance(as_of_seq, int):
        max_seq = max(max_seq, as_of_seq)
    proj["replay"] = {
        "as_of_seq": as_of_seq,
        "total_events": total_events,
        "max_seq": max(seqs) if seqs else total_events,
        "watermark": "REPLAY",
        "settled_run": proj.get("status") in TERMINAL_STATUSES,
    }
    return proj


def truncate_events(events, as_of_seq=None):
    """Keep events with seq <= as_of_seq. If events lack seq, keep first N by order."""
    if as_of_seq is None:
        return events
    try:
        cut = int(as_of_seq)
    except (TypeError, ValueError):
        return events
    if cut < 1:
        return []
    has_seq = any(isinstance(e.get("seq"), int) for e in events)
    if has_seq:
        return [e for e in events if isinstance(e.get("seq"), int) and e["seq"] <= cut]
    return events[:cut]


def list_runs(events_dir):
    """Catalog every *.jsonl stream — metadata only, no invented motion."""
    runs = []
    try:
        names = sorted(n for n in os.listdir(events_dir) if n.endswith(".jsonl"))
    except OSError:
        return runs
    for name in names:
        path = os.path.join(events_dir, name)
        events, _mal = read_events(path)
        if not events:
            continue
        did = name[:-6]
        first = events[0]
        last = events[-1]
        status = "running"
        ended_at = None
        for ev in events:
            if ev.get("event") == "dispatch_end":
                st = ev.get("status")
                status = "settled" if st == "completed" else (st or "settled")
                ended_at = ev.get("ts")
        # Prefer dispatch_id from stream envelope when present.
        for ev in events:
            if ev.get("dispatch_id"):
                did = ev["dispatch_id"]
                break
        mode = "wave"
        repo = plan = None
        started_at = None
        for ev in events:
            if ev.get("event") == "dispatch_start":
                if ev.get("mode") in ("wave", "conductor"):
                    mode = ev["mode"]
                repo = ev.get("repo")
                plan = ev.get("plan")
                started_at = ev.get("ts")
                break
        max_seq = 0
        for ev in events:
            if isinstance(ev.get("seq"), int):
                max_seq = max(max_seq, ev["seq"])
        if max_seq == 0:
            max_seq = len(events)
        runs.append({
            "dispatch_id": did,
            "source": rel(path),
            "status": status,
            "settled": status in TERMINAL_STATUSES,
            "mode": mode,
            "repo": repo,
            "plan": plan,
            "started_at": started_at,
            "ended_at": ended_at,
            "events": len(events),
            "max_seq": max_seq,
            "last_event_ts": last.get("ts") if isinstance(last, dict) else None,
            "first_event_ts": first.get("ts") if isinstance(first, dict) else None,
        })
    runs.sort(key=lambda r: r.get("last_event_ts") or "", reverse=True)
    return runs


def _seat(state, task_id):
    seat = state.get(task_id)
    if seat is None:
        seat = {
            "task_id": task_id,
            "agent": None,
            "branch": None,
            "wave": None,
            "provider": None,
            "worker": None,
            "model": None,
            "status": "queued",
            "pipeline": "queued",
            "exit": None,
            "attempt": 1,
            "started_at": None,
            "ended_at": None,
            "duration_s": None,
            "providers_tried": [],
            "failovers": [],
            "ratecapped": False,
            "log": None,
        }
        state[task_id] = seat
    return seat


def project(events, now=None, source=None, malformed=0):
    """Fold an event list into the live/1 projection. Pure function."""
    now = now or utcnow()
    out = empty_projection(now)
    out["source"] = source
    if malformed:
        out["warnings"].append("%d malformed event line(s) skipped" % malformed)
    if not events:
        return out

    seats = {}
    order = []
    waves_seen = set()
    open_gates = {}
    last_ts = None
    wave_current = None

    for ev in events:
        kind = ev.get("event")
        ts = ev.get("ts")
        parsed = parse_ts(ts)
        if parsed and (last_ts is None or parsed >= last_ts):
            last_ts = parsed
        if ev.get("dispatch_id"):
            out["dispatch_id"] = ev["dispatch_id"]
        schema = ev.get("schema")
        if isinstance(schema, str) and not schema.startswith(EVENT_SCHEMA_PREFIX):
            out["warnings"].append("unknown event schema: %s" % schema)

        if kind == "dispatch_start":
            out["status"] = "running"
            out["started_at"] = ts
            out["repo"] = ev.get("repo")
            out["plan"] = ev.get("plan")
            if ev.get("mode") in ("wave", "conductor"):
                out["mode"] = ev["mode"]
        elif kind == "dispatch_plan":
            if isinstance(ev.get("waves"), int):
                out["wave"]["total"] = ev["waves"]
            if isinstance(ev.get("seats"), int):
                out["seats_planned"] = ev["seats"]
        elif kind == "wave_start":
            wave_current = ev.get("wave")
            waves_seen.add(wave_current)
            if ev.get("mode") in ("wave", "conductor"):
                out["mode"] = ev["mode"]
        elif kind == "wave_end":
            waves_seen.add(ev.get("wave"))
        elif kind == "seat_dispatch":
            task_id = str(ev.get("task_id"))
            if task_id not in seats:
                order.append(task_id)
            seat = _seat(seats, task_id)
            for key in ("agent", "branch", "provider", "worker", "model", "wave"):
                if ev.get(key) is not None:
                    seat[key] = ev[key]
            if ev.get("attempt") is not None:
                seat["attempt"] = ev["attempt"]
            if seat["provider"] and seat["provider"] not in seat["providers_tried"]:
                seat["providers_tried"].append(seat["provider"])
            seat["status"] = "running"
            seat["started_at"] = ts
            seat["ended_at"] = None
            seat["exit"] = None
            seat["duration_s"] = None
        elif kind == "seat_exit":
            task_id = str(ev.get("task_id"))
            if task_id not in seats:
                order.append(task_id)
            seat = _seat(seats, task_id)
            for key in ("agent", "branch", "provider", "worker", "wave"):
                if ev.get(key) is not None:
                    seat[key] = ev[key]
            seat["status"] = ev.get("status") or "failed"
            seat["exit"] = ev.get("exit")
            seat["ended_at"] = ts
            seat["duration_s"] = ev.get("duration_s")
            if ev.get("reason"):
                seat["reason"] = ev["reason"]
        elif kind == "ratecap":
            task_id = str(ev.get("task_id"))
            if task_id not in seats:
                order.append(task_id)
            seat = _seat(seats, task_id)
            seat["ratecapped"] = True
            if ev.get("provider"):
                seat["ratecap_provider"] = ev["provider"]
        elif kind == "failover":
            task_id = str(ev.get("task_id"))
            if task_id not in seats:
                order.append(task_id)
            seat = _seat(seats, task_id)
            seat["failovers"].append({
                "from": ev.get("from_provider"),
                "to": ev.get("to_provider"),
                "ts": ts,
            })
            for provider in (ev.get("from_provider"), ev.get("to_provider")):
                if provider and provider not in seat["providers_tried"]:
                    seat["providers_tried"].append(provider)
        elif kind == "seat_log":
            task_id = str(ev.get("task_id"))
            if task_id in seats and ev.get("log"):
                # Filenames only — the Floor never renders transcript bodies.
                seats[task_id]["log"] = os.path.basename(str(ev["log"]))
        elif kind == "human_wait":
            key = "%s:%s" % (ev.get("kind"), ev.get("wave"))
            open_gates[key] = {
                "kind": "human_gate",
                "gate": ev.get("kind"),
                "wave": ev.get("wave"),
                "next_wave": ev.get("next_wave"),
                "label": ev.get("waiting_on") or "operator input",
                "since": ts,
            }
        elif kind == "human_resume":
            open_gates.pop("%s:%s" % (ev.get("kind"), ev.get("wave")), None)
        elif kind == "dispatch_end":
            status = ev.get("status")
            out["status"] = "settled" if status == "completed" else (status or "settled")
            out["ended_at"] = ts
            for key in ("succeeded", "failed", "total"):
                if ev.get(key) is not None:
                    out.setdefault("totals", {})[key] = ev[key]

    # ── seats + pipeline counts ──
    seat_list = [seats[t] for t in order]
    for seat in seat_list:
        seat["pipeline"] = PIPELINE.get(seat["status"], "queued")
        if seat["status"] == "running" and out["status"] != "running":
            # Dispatcher is gone but the seat never reported — say unknown, not
            # "running". Honesty beats a spinner that never stops.
            seat["status"] = "unknown"
            seat["pipeline"] = "blocked"
        if seat["status"] == "running" and seat["started_at"]:
            started = parse_ts(seat["started_at"])
            if started:
                seat["elapsed_s"] = max(0, int((now - started).total_seconds()))
    seat_list.sort(key=lambda s: (s.get("wave") if isinstance(s.get("wave"), int) else 0,
                                  str(s.get("task_id"))))
    out["seats"] = seat_list

    counts = {"queued": 0, "in_flight": 0, "blocked": 0, "settled": 0, "total": len(seat_list)}
    for seat in seat_list:
        counts[seat["pipeline"]] = counts.get(seat["pipeline"], 0) + 1
    out["counts"] = counts

    # ── wave position ──
    numeric_waves = sorted(w for w in waves_seen if isinstance(w, int))
    out["wave"]["current"] = wave_current
    if out["wave"]["total"] is None and numeric_waves:
        out["wave"]["total"] = numeric_waves[-1]

    # ── waiting_on (first-class strip, in priority order) ──
    waiting = list(open_gates.values())
    for seat in seat_list:
        if seat["status"] == "ratecap" or seat.get("ratecapped"):
            if seat["status"] not in ("success",):
                waiting.append({
                    "kind": "ratecap",
                    "task_id": seat["task_id"],
                    "agent": seat["agent"],
                    "provider": seat.get("ratecap_provider") or seat["provider"],
                    "label": "%s rate-capped on %s" % (seat.get("agent") or "seat",
                                                       seat.get("provider") or "provider"),
                    "since": seat.get("ended_at") or seat.get("started_at"),
                })
    if not waiting:
        running = [s for s in seat_list if s["status"] == "running"]
        if running:
            slowest = max(running, key=lambda s: s.get("elapsed_s") or 0)
            waiting.append({
                "kind": "seat",
                "task_id": slowest["task_id"],
                "agent": slowest["agent"],
                "provider": slowest["provider"],
                "label": "%s working on %s" % (slowest.get("agent") or "seat",
                                               slowest.get("branch") or "its branch"),
                "since": slowest.get("started_at"),
                "seconds": slowest.get("elapsed_s"),
            })
    out["waiting_on"] = waiting

    # ── staleness ──
    out["last_event_ts"] = fmt_ts(last_ts)
    if last_ts is None:
        state, age = "none", None
    else:
        age = max(0, int((now - last_ts).total_seconds()))
        if age >= OFFLINE_AFTER:
            state = "offline"
        elif age >= STALE_AFTER:
            state = "stale"
        else:
            state = "live"
    out["staleness"] = {"seconds": age, "state": state,
                        "stale_after_s": STALE_AFTER, "offline_after_s": OFFLINE_AFTER}

    out["events_seen"] = len(events)
    out["recent_events"] = events[-RECENT_EVENTS:]
    return out


def build(events_dir, dispatch_id=None, now=None, as_of_seq=None, replay=False):
    """Resolve the current stream and project it (never raises on missing data).

    Phase C: pass ``as_of_seq`` and/or ``replay=True`` to get a historical
    projection. Replay always sets ``view=replay`` so the Floor cannot paint a
    green LIVE LED for the past.
    """
    path, resolved_id = resolve_stream(events_dir, dispatch_id)
    if not path:
        return empty_projection(
            now, reason="no event stream in %s — run a dispatch (FLEET_EVENTS=1)" % rel(events_dir))
    events, malformed = read_events(path)
    total = len(events)
    if as_of_seq is not None:
        events = truncate_events(events, as_of_seq)
    proj = project(events, now=now, source=rel(path), malformed=malformed)
    if not proj.get("dispatch_id"):
        proj["dispatch_id"] = resolved_id
    # Replay when asked, or when the caller is scrubbing (as_of_seq set).
    force_replay = replay or as_of_seq is not None
    if force_replay:
        # Use the cut seq (or full length when replaying the whole settled run).
        cut = as_of_seq if as_of_seq is not None else total
        mark_replay(proj, cut, total)
    return proj


def write_projection(proj, out_path):
    directory = os.path.dirname(out_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(proj, fh, indent=2, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, out_path)  # atomic — a reader never sees a half file
    return out_path


# ── server ──────────────────────────────────────────────────────────────────

def serve(args, out_path):
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    site_dir = args.site_dir
    state = {"json": "{}", "version": 0}
    stop = threading.Event()

    def refresh():
        proj = build(args.events_dir, args.dispatch_id)
        payload = json.dumps(proj)
        if payload != state["json"]:
            state["json"] = payload
            state["version"] += 1
        write_projection(proj, out_path)
        return proj

    def watcher():
        while not stop.is_set():
            try:
                refresh()
            except Exception as exc:              # never kill the watcher thread
                print("desk-live: refresh failed: %s" % exc, file=sys.stderr)
            stop.wait(args.interval)

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            SimpleHTTPRequestHandler.__init__(self, *a, directory=site_dir, **kw)

        def log_message(self, fmt, *a):
            if args.verbose:
                SimpleHTTPRequestHandler.log_message(self, fmt, *a)

        def _no_cache(self):
            self.send_header("Cache-Control", "no-store, max-age=0")

        def _query(self):
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(self.path).query)
            return {k: (v[0] if v else None) for k, v in q.items()}

        def _json_response(self, obj, code=200):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self._no_cache()
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/events":
                return self.sse()
            if path in ("/live.json", "/data/live.json"):
                body = state["json"].encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self._no_cache()
                self.end_headers()
                self.wfile.write(body)
                return None
            # Phase C — catalog + scrubber projections (never invent seats).
            if path in ("/api/runs", "/runs.json"):
                self._json_response({
                    "schema": "fleet-runs/1",
                    "generated_at": fmt_ts(utcnow()),
                    "runs": list_runs(args.events_dir),
                })
                return None
            if path in ("/api/replay", "/replay.json"):
                q = self._query()
                did = q.get("dispatch_id") or args.dispatch_id
                as_of = q.get("as_of_seq")
                try:
                    as_of_i = int(as_of) if as_of is not None and as_of != "" else None
                except ValueError:
                    as_of_i = None
                proj = build(args.events_dir, did, as_of_seq=as_of_i, replay=True)
                self._json_response(proj)
                return None
            return SimpleHTTPRequestHandler.do_GET(self)

        def sse(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            seen = -1
            try:
                while not stop.is_set():
                    if state["version"] != seen:
                        seen = state["version"]
                        self.wfile.write(b"event: live\ndata: " +
                                         state["json"].encode("utf-8") + b"\n\n")
                    else:
                        self.wfile.write(b": keep-alive\n\n")   # proxies/browsers
                    self.wfile.flush()
                    time.sleep(max(0.5, args.interval))
            except (BrokenPipeError, ConnectionResetError):
                pass
            return None

    proj = refresh()
    if not os.path.isdir(site_dir):
        print("desk-live: %s does not exist yet — run `make experience` to build the desk"
              % rel(site_dir), file=sys.stderr)

    thread = threading.Thread(target=watcher, daemon=True)
    thread.start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = "http://%s:%d/live/" % (args.host, args.port)
    print("Fleet Desk — Ops Floor watcher")
    print("  serving   %s" % rel(site_dir))
    print("  events    %s" % (proj.get("source") or "none yet"))
    print("  live.json %s" % rel(out_path))
    print("  SSE       http://%s:%d/events" % (args.host, args.port))
    print("  open      %s" % url)
    print("  (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\ndesk-live: stopped")
    finally:
        stop.set()
        server.server_close()
    return 0


# ── cli ─────────────────────────────────────────────────────────────────────

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Fleet Desk Ops Floor: tail dispatch events → live.json (+ optional local server)")
    parser.add_argument("--events-dir", default=DEFAULT_EVENTS_DIR,
                        help="directory of *.jsonl event streams (default: logs/fleet-events)")
    parser.add_argument("--site-dir", default=DEFAULT_SITE_DIR,
                        help="static site root to serve (default: site/experience)")
    parser.add_argument("--out", default=None,
                        help="projection output path (default: <site-dir>/data/live.json)")
    parser.add_argument("--dispatch-id", default=None,
                        help="project a specific run instead of the latest pointer")
    parser.add_argument("--as-of-seq", type=int, default=None,
                        help="Phase C: project only events with seq <= N (implies replay view)")
    parser.add_argument("--replay", action="store_true",
                        help="Phase C: force view=replay + REPLAY watermark (never LIVE LED)")
    parser.add_argument("--list-runs", action="store_true",
                        help="Phase C: print settled/running run catalog as JSON and exit")
    parser.add_argument("--once", action="store_true",
                        help="write the projection once and exit (no server, no network)")
    parser.add_argument("--watch", action="store_true",
                        help="poll and rewrite live.json without serving (for file:// desks)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="server port (default: 8777)")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default: loopback only)")
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL,
                        help="seconds between stream reads (default: 2)")
    parser.add_argument("--print", dest="print_json", action="store_true",
                        help="also print the projection to stdout")
    parser.add_argument("--verbose", action="store_true", help="log every HTTP request")
    args = parser.parse_args(argv)

    out_path = args.out or os.path.join(args.site_dir, "data", "live.json")

    if args.list_runs:
        print(json.dumps({"schema": "fleet-runs/1", "runs": list_runs(args.events_dir)}, indent=2))
        return 0

    if args.once or args.watch:
        proj = build(args.events_dir, args.dispatch_id,
                     as_of_seq=args.as_of_seq, replay=args.replay)
        write_projection(proj, out_path)
        if args.print_json:
            print(json.dumps(proj, indent=2))
        if args.once:
            print("live.json written: %s (status=%s, seats=%d, view=%s, staleness=%s)"
                  % (out_path, proj["status"], len(proj["seats"]),
                     proj.get("view"), proj["staleness"]["state"]),
                  file=sys.stderr)
            return 0
        print("desk-live: watching %s → %s (Ctrl-C to stop)" % (args.events_dir, out_path))
        try:
            while True:
                time.sleep(args.interval)
                write_projection(
                    build(args.events_dir, args.dispatch_id,
                          as_of_seq=args.as_of_seq, replay=args.replay),
                    out_path)
        except KeyboardInterrupt:
            print("\ndesk-live: stopped")
        return 0

    return serve(args, out_path)


if __name__ == "__main__":
    sys.exit(main())
