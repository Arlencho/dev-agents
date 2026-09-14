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

Floor v3-C adds the day before and the push. ``yesterday[]`` and
``yesterday_meta`` are read the same way as ``today[]``: one row per dispatch
that ended on the previous local day, same shape, marked ``day: yesterday``.
History deeper than that stays in the Almanac. After each write the watcher
calls ``scripts/notify.sh needs-you`` when ``FLEET_NOTIFY_NEEDS_YOU_MIN`` is
set, so a NEEDS YOU item nobody acted on for that many minutes reaches the
owner once as a macOS notification, in a fixed phrase built from the item's
identifiers, never from its text. Off by default, never fatal.

Law: docs/proposals/fleet-desk-v2-SYNTHESIS.md §3 Phases B+C
Schema: docs/experience-data.md § Live event stream

Honesty rules (do not weaken):
  * only facts present in the stream are projected — no invented seats
  * live state never enters ``data/index.json`` (the settled Almanac contract)
  * a stream that stopped updating reads STALE, then OFFLINE — never "live"
  * replay projections never claim LIVE — ``view=replay`` + watermark
  * stdlib only; binds loopback only; the one thing it ever asks the network
    for is the optional gh enrichment (issue milestone, PR for a branch, critic
    verdicts, milestones for the Floor v3 NEEDS YOU and INITIATIVES blocks),
    which is cached, budgeted, never fatal and off with --no-gh / FLEET_DESK_NO_GH=1
  * needs_you never invents an item: every entry cites the comment id, the
    stream event or the file line it came from, and says whether it was verified

Python 3.8+ (stdlib only).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import unquote

SCHEMA = "live/1"
EVENT_SCHEMA_PREFIX = "fleet-events/"
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_EVENTS_DIR = os.path.join(REPO_DIR, "logs", "fleet-events")
DEFAULT_QUEUE_FILE = os.environ.get(
    "FLEET_QUEUE_FILE", os.path.join(REPO_DIR, "logs", "fleet-queue.json"))
# The runner's stops (logs/fleet-stops.jsonl): one line per stop it produced,
# one per clearance. Read here so the Floor can show what needs a person.
DEFAULT_STOPS_FILE = os.environ.get(
    "FLEET_STOPS_FILE", os.path.join(REPO_DIR, "logs", "fleet-stops.jsonl"))
STOPS_SCHEMA = "fleet-stops/1"
# The W1 fleet ledger rollup (logs/ledger.json, written by make ledger):
# per-initiative cost, elapsed and work share. Optional like gh; when it is
# missing the Floor says so instead of painting zero.
DEFAULT_LEDGER_FILE = os.environ.get(
    "FLEET_LEDGER_FILE", os.path.join(REPO_DIR, "logs", "ledger.json"))
DEFAULT_SITE_DIR = os.path.join(REPO_DIR, "site", "experience")
DEFAULT_PORT = 8777
DEFAULT_INTERVAL = 2.0
STALE_AFTER = 120     # seconds without an event → STALE chrome
OFFLINE_AFTER = 900   # seconds without an event → OFFLINE chrome
QUIET_AFTER = 90      # running stream with no new events → waiting_on quiet_stream
RECENT_EVENTS = 50    # tail kept in the projection (already redaction-safe)
QUEUE_SCHEMA = "fleet-queue/1"
DAY_SCAN_WINDOW_S = 50 * 3600   # mtime prefilter when scanning the day streams:
                                # today and yesterday, with slack for a 25 h DST day


def _env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


# Optional gh enrichment (issue milestone, PR for a branch). See GhEnricher.
GH_TIMEOUT_S = _env_float("FLEET_GH_TIMEOUT_S", 8)   # per call; a slow gh skips
GH_CALL_BUDGET = 60        # gh calls one projection may spend; the rest skip
GH_CACHE_TTL_S = 300       # answers reused across builds by the watcher
GH_TITLE_MAX = 120         # milestone and PR titles are capped like the Almanac

ISO = "%Y-%m-%dT%H:%M:%SZ"

# Seat status vocabulary, mapped to the pipeline language of the desk.
# The one event a second writer appends to a dispatch stream.
PROGRESS_EVENT = "seat_progress"
# Phase words a seat_progress event may carry (writer: scripts/seat-progress.py).
PHASES = ("reading", "reviewing", "editing", "testing", "committing")
# What the writer puts in `path` when the tool touched something outside the repo.
OUTSIDE_REPO = "outside-repo"

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


def rel_safe(path):
    """Repo-relative when the path is inside the repo, else the basename only.

    Operator paths never enter the projection: a queue file outside the repo is
    named, not located.
    """
    if not path:
        return None
    relative = rel(path)
    return os.path.basename(path) if relative.startswith("..") else relative


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
        # Declared intent (logs/fleet-queue.json), never observed motion: the
        # Floor labels this block as declared and never calls a queued plan
        # running. Filled by build(); [] here so the key always exists.
        "queue": [],
        "queue_meta": {"source": None, "declared": False, "declared_at": None,
                       "total": 0, "queued": 0, "running": 0, "settled": 0,
                       "hold": None},
        # The runner's open stops (logs/fleet-stops.jsonl): what the queue
        # runner refused to do by itself and why. [] here so the key always
        # exists; filled by build() for a live view, kept [] on a replay.
        "stops": [],
        "stops_meta": {"source": None, "open": 0, "total": 0},
        # Day view: one entry per dispatch that ENDED on this local calendar day.
        "today": [],
        "today_meta": {"day": "today", "date": None, "streams_read": 0, "live": [], "ended": 0},
        # Floor v3-C: the day before, same shape, marked yesterday. Deeper
        # history stays in the Almanac. [] here so the keys always exist.
        "yesterday": [],
        "yesterday_meta": {"day": "yesterday", "date": None, "streams_read": 0,
                           "live": [], "ended": 0},
        # The one line at the top of the Floor, in plain counts. Filled by
        # build(); zeros here so the key always exists (a replay sets it None).
        "summary": {"running": 0, "queued": 0, "landed_today": 0,
                    "last_event_ts": None},
        # Issue 72: one counts object per repo seen today, so the Floor can
        # group NOW by repo. [] here so the key always exists; a replay keeps [].
        "repos": [],
        "gh_enrichment": {"status": "skipped", "reason": "no lookup was needed",
                          "owner": None, "calls": 0, "cached": 0, "skipped": 0},
        # Floor v3: what needs the owner, and where each initiative stands.
        # [] here so the keys always exist; a replay keeps them empty.
        "needs_you": [],
        "needs_you_meta": {"count": 0, "unverified": 0, "checks": [],
                           "comment_lookback_days": COMMENT_LOOKBACK_DAYS,
                           "quiet_after_s": QUIET_AFTER},
        "initiatives": [],
        "initiatives_meta": {"count": 0, "repos": [], "active_days": INITIATIVE_ACTIVE_DAYS,
                             "plans_seen": 0},
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
    # `summary` and `seats[].now` are statements about the present. A
    # historical scrub has no present, so both stay empty rather than
    # borrowing today's counts.
    proj["summary"] = None
    proj["repos"] = []
    for seat in proj.get("seats") or []:
        seat["now"] = None
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
    if not has_seq:
        return events[:cut]
    # `seq` counts per writer. The dispatcher numbers its own spine in process;
    # a seat reader appends progress lines from a separate process, so the two
    # counters share no space. Cut the spine on seq (unchanged), and cut the
    # second writer's lines on time against the newest kept spine event, so a
    # scrub never shows activity from after the point being replayed.
    cut_ts = None
    for event in events:
        if event.get("event") == PROGRESS_EVENT:
            continue
        if isinstance(event.get("seq"), int) and event["seq"] <= cut:
            cut_ts = event.get("ts") or cut_ts
    kept = []
    for event in events:
        if event.get("event") == PROGRESS_EVENT:
            if cut_ts is not None and str(event.get("ts") or "") <= str(cut_ts):
                kept.append(event)
        elif isinstance(event.get("seq"), int) and event["seq"] <= cut:
            kept.append(event)
    return kept


# ── queue (declared) ────────────────────────────────────────────────────────

def read_queue(path):
    """Read logs/fleet-queue.json (fleet-queue/1). Returns (entries, warnings).

    Never raises: a missing file is an empty queue, a malformed one is a warning
    and an empty queue. The desk must never fail because intent was not written.
    """
    if not path or not os.path.isfile(path):
        return [], []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return [], ["queue file %s is unreadable or malformed" % rel_safe(path)]
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        return [], ["queue file %s is not a %s document" % (rel_safe(path), QUEUE_SCHEMA)]
    if data.get("schema") != QUEUE_SCHEMA:
        return [], ["queue file %s carries schema %r, expected %s"
                    % (rel_safe(path), data.get("schema"), QUEUE_SCHEMA)]
    return [e for e in data["entries"] if isinstance(e, dict)], []


def queue_view(entries):
    """Queued entries only, in declared order. A running plan is not 'up next'."""
    out = []
    position = 0
    for entry in entries:
        if (entry.get("status") or "queued") != "queued":
            continue
        position += 1
        plan = str(entry.get("plan") or "")
        out.append({
            "position": position,
            "plan": plan,
            "plan_basename": os.path.basename(plan),
            "repo": entry.get("repo") or None,
            "purpose": entry.get("purpose") or None,
            "added_at": entry.get("added_at") or None,
            "status": "queued",
            # Why the runner is not starting it, in the runner's own words.
            # blocked: set by queue.sh block or by the runner on a failed start,
            # cleared by a person. waiting: the AFTER header, cleared by the
            # runner itself once the named plan has landed.
            "blocked": (entry.get("blocked") or "").strip() or None,
            "waiting": (entry.get("waiting") or "").strip() or None,
        })
    return out


def queue_meta(entries, path):
    """Provenance for the queue block: who declared it and when it last changed."""
    tally = {"queued": 0, "running": 0, "settled": 0}
    newest = None
    for entry in entries:
        status = entry.get("status") or "queued"
        tally[status] = tally.get(status, 0) + 1
        added = entry.get("added_at")
        if isinstance(added, str) and (newest is None or added > newest):
            newest = added
    return {
        "source": rel_safe(path),
        "declared": bool(entries),
        "declared_at": newest,
        "total": len(entries),
        "queued": tally.get("queued", 0),
        "running": tally.get("running", 0),
        "settled": tally.get("settled", 0),
        "hold": None,
    }


def read_queue_hold(path):
    """The queue-wide hold the runner wrote (memory guard), else None."""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    hold = data.get("hold") if isinstance(data, dict) else None
    return scrub_text(hold) or None if isinstance(hold, str) else None


# ── the runner's stops (logs/fleet-stops.jsonl) ─────────────────────────────
#
# scripts/queue-runner.sh appends one JSON line per stop it produces (memory
# guard active, a second BLOCK-FIX, an escalation, red checks, a refused
# merge) and one per clearance, keyed. The Floor folds the file by key, last
# state wins, and shows the open ones with the critic sentence and one action.
# The file never carries a prompt, a task body or an absolute path: plans are
# basenames, the sentence is the first line of the critic comment, scrubbed.

STOP_PUBLIC_KEYS = ("key", "kind", "at", "repo", "plan", "dispatch_id", "pr",
                    "pr_url", "branch", "verdict", "sentence", "action")


def read_stops(path):
    """Open stops from the runner's stops file. Returns (stops, meta, warnings).

    Never raises: a missing file is no stops, a malformed line is skipped and
    counted in a warning. Folded by key: the newest line per key decides, and
    only keys whose newest state is ``open`` are returned, newest first.
    """
    meta = {"source": rel_safe(path), "open": 0, "total": 0}
    if not path or not os.path.isfile(path):
        return [], meta, []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read().splitlines()
    except OSError:
        return [], meta, ["stops file %s is unreadable" % rel_safe(path)]
    latest = {}
    order = []
    malformed = 0
    for line in raw:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        if not isinstance(rec, dict) or not isinstance(rec.get("key"), str):
            malformed += 1
            continue
        key = rec["key"]
        if key not in latest:
            order.append(key)
        latest[key] = rec
    meta["total"] = len(latest)
    out = []
    for key in order:
        rec = latest[key]
        if rec.get("state") != "open":
            continue
        row = {k: rec.get(k) for k in STOP_PUBLIC_KEYS}
        row["at"] = rec.get("ts") if isinstance(rec.get("ts"), str) else None
        for text_key in ("sentence", "action", "plan", "repo", "branch", "kind", "verdict"):
            if isinstance(row.get(text_key), str):
                row[text_key] = scrub_text(row[text_key]) or None
        if isinstance(row.get("plan"), str):
            row["plan"] = os.path.basename(row["plan"])
        out.append(row)
    out.sort(key=lambda r: r.get("at") or "", reverse=True)
    meta["open"] = len(out)
    warnings = []
    if malformed:
        warnings.append("stops file %s: %d malformed line%s skipped"
                        % (rel_safe(path), malformed, "" if malformed == 1 else "s"))
    return out, meta, warnings


def queue_purpose_index(entries):
    """plan basename -> {purpose, repo, plan} so the day view can name a run."""
    index = {}
    for entry in entries:
        plan = str(entry.get("plan") or "")
        base = os.path.basename(plan)
        if base and base not in index:
            index[base] = {"plan": plan,
                           "purpose": entry.get("purpose") or None,
                           "repo": entry.get("repo") or None,
                           "issue": entry.get("issue")}
    return index


# ── day view (every stream of the local calendar day) ───────────────────────

_DAY_CACHE = {}   # path -> (mtime, size, summary); settled streams parse once


def local_date(dt_utc):
    """Local calendar date of a naive-UTC timestamp (the operator's day)."""
    if dt_utc is None:
        return None
    return dt_utc.replace(tzinfo=timezone.utc).astimezone().date()


def run_outcome(end_status, exits, failed):
    """One word for how a finished dispatch ended: landed, failed or aborted.

    The close-out status alone cannot tell the two bad endings apart:
    dispatch.sh writes ``aborted`` from its exit trap whenever it does not reach
    the normal close-out, for an operator's Ctrl-C and for a run that died by
    itself after a seat failed alike. The seat exits can. An operator stop
    leaves a seat without a seat_exit; a run that ended by itself has an exit
    for every seat it dispatched. ``exits`` maps task_id to the status of that
    seat's LAST seat_exit (None while it has none), so a retry overrides.

      landed    close-out ``completed``, every seat's last exit ``success``,
                and the dispatcher counted no failure
      failed    at least one seat's last exit is not ``success`` and every
                dispatched seat has exited (the run ended by itself); or a
                ``completed`` close-out that is not clean
      aborted   anything else: stopped while a seat was still in flight, or
                before the normal close-out with nothing having failed
    """
    unexited = [t for t, st in exits.items() if st is None]
    not_ok = [t for t, st in exits.items() if st is not None and st != "success"]
    if end_status == "completed":
        return "landed" if not not_ok and not unexited and not failed else "failed"
    if not_ok and not unexited:
        return "failed"
    return "aborted"


def summarize_stream(path):
    """One dispatch, folded to the facts the day view needs. Cached by mtime."""
    try:
        stat = os.stat(path)
    except OSError:
        return None
    key = (stat.st_mtime, stat.st_size)
    cached = _DAY_CACHE.get(path)
    if cached and cached[0] == key:
        return cached[1]

    events, _malformed = read_events(path)
    if not events:
        _DAY_CACHE[path] = (key, None)
        return None

    summary = {
        "dispatch_id": os.path.basename(path)[:-6],
        "source": rel(path),
        "repo": None, "plan": None, "mode": "wave",
        "started_at": None, "ended_at": None,
        "status": "running", "end_status": None,
        "duration_s": None, "seats": 0, "succeeded": None, "failed": None,
        "outcome": None, "branches": [],
    }
    seat_ids = set()
    exits = {}          # task_id -> status of its last seat_exit, None until one
    for ev in events:
        if ev.get("dispatch_id"):
            summary["dispatch_id"] = ev["dispatch_id"]
        kind = ev.get("event")
        if kind == "dispatch_start":
            summary["repo"] = ev.get("repo")
            summary["plan"] = ev.get("plan")
            summary["started_at"] = ev.get("ts")
            if ev.get("mode"):
                summary["mode"] = ev["mode"]
        elif kind in ("seat_dispatch", "seat_exit"):
            if ev.get("task_id") is not None:
                task_id = str(ev["task_id"])
                seat_ids.add(task_id)
                if kind == "seat_exit":
                    exits[task_id] = ev.get("status") or "failed"
                else:
                    exits[task_id] = None
            branch = ev.get("branch")
            if branch and branch not in summary["branches"]:
                summary["branches"].append(branch)
        elif kind == "dispatch_end":
            summary["ended_at"] = ev.get("ts")
            summary["end_status"] = ev.get("status")
            summary["status"] = "settled" if ev.get("status") == "completed" else (
                ev.get("status") or "settled")
            if isinstance(ev.get("duration_s"), int):
                summary["duration_s"] = ev["duration_s"]
            for key_name in ("succeeded", "failed"):
                if isinstance(ev.get(key_name), int):
                    summary[key_name] = ev[key_name]
    summary["seats"] = len(seat_ids)
    if summary["ended_at"] is not None:
        summary["outcome"] = run_outcome(summary["end_status"], exits, summary["failed"])
    _DAY_CACHE[path] = (key, summary)
    return summary


def day_streams(events_dir, now):
    """Stream summaries that could belong to the local day (mtime prefiltered)."""
    try:
        names = sorted(n for n in os.listdir(events_dir) if n.endswith(".jsonl"))
    except OSError:
        return []
    cutoff = time.time() - DAY_SCAN_WINDOW_S
    out = []
    for name in names:
        path = os.path.join(events_dir, name)
        try:
            if os.path.getmtime(path) < cutoff:
                continue
        except OSError:
            continue
        summary = summarize_stream(path)
        if summary:
            out.append(summary)
    return out


def day_view(events_dir, now, entries, days_back=0):
    """Every dispatch that ENDED on one local calendar day, plus the live ones.

    ``days_back`` 0 is today, 1 is yesterday (Floor v3-C); nothing deeper,
    that history is the Almanac's. Live means still in motion: no
    ``dispatch_end`` yet and started on this local date or the one before, so
    a run that crossed local midnight is still followed and counted. Only
    today carries live runs: a run with no close-out is in motion now, and
    yesterday's row list claims nothing about the present. Reads every stream
    file of the day, not only the newest, so concurrent dispatches all appear.
    Purpose and plan path come from the queue when the basename matches; the
    stream only ever carries a basename.
    """
    today = local_date(now)
    day = today - timedelta(days=days_back)
    live_dates = (today, today - timedelta(days=1)) if days_back == 0 else ()
    index = queue_purpose_index(entries)
    landed, live = [], []
    summaries = day_streams(events_dir, now)
    for summary in summaries:
        ended = parse_ts(summary.get("ended_at"))
        started = parse_ts(summary.get("started_at"))
        known = index.get(os.path.basename(summary.get("plan") or "")) or {}
        if ended is not None and local_date(ended) == day:
            landed.append({
                "dispatch_id": summary["dispatch_id"],
                "source": summary["source"],
                "plan": known.get("plan") or summary.get("plan"),
                "plan_basename": os.path.basename(summary.get("plan") or ""),
                "repo": summary.get("repo") or known.get("repo"),
                "purpose": known.get("purpose"),
                "purpose_source": "queue" if known.get("purpose") else "none",
                "status": summary.get("status"),
                "outcome": summary.get("outcome"),
                "end_status": summary.get("end_status"),
                "duration_s": summary.get("duration_s"),
                "started_at": summary.get("started_at"),
                "ended_at": summary.get("ended_at"),
                "seats": summary.get("seats"),
                "succeeded": summary.get("succeeded"),
                "failed": summary.get("failed"),
                "branches": summary.get("branches") or [],
            })
        elif ended is None and started is not None and local_date(started) in live_dates:
            live.append(summary)
    landed.sort(key=lambda r: r.get("ended_at") or "", reverse=True)
    live.sort(key=lambda r: r.get("started_at") or "")
    meta = {
        "day": "today" if days_back == 0 else "yesterday",
        "date": day.isoformat(),
        "streams_read": len(summaries),
        "live": [s["dispatch_id"] for s in live],
        "ended": len(landed),
    }
    return landed, live, meta


def today_view(events_dir, now, entries):
    """Today's rows, live runs and meta (``day_view`` with ``days_back=0``)."""
    return day_view(events_dir, now, entries, 0)


def merge_live_seats(proj, events_dir, now, live_summaries):
    """Show the seats of every live dispatch when more than one is running.

    The single-dispatch follow is unchanged: the resolved stream stays the
    subject of the page (status, wave, waiting_on, event tail). This only adds
    the seats of the other dispatches that are live on the same day, each tagged
    with its dispatch_id, so a second run is never invisible.
    """
    primary = proj.get("dispatch_id")
    for seat in proj.get("seats") or []:
        seat.setdefault("dispatch_id", primary)
    others = [s for s in live_summaries if s["dispatch_id"] != primary]
    if not others:
        return proj
    merged = 0
    for summary in others:
        path = os.path.join(events_dir, summary["dispatch_id"] + ".jsonl")
        if not os.path.isfile(path):
            continue
        events, malformed = read_events(path)
        if not events:
            continue
        side = project(events, now=now, source=rel(path), malformed=malformed)
        for seat in side.get("seats") or []:
            seat["dispatch_id"] = side.get("dispatch_id") or summary["dispatch_id"]
            seat["foreign"] = True     # not the followed run: honest label
            seat["plan"] = side.get("plan") or summary.get("plan")
            seat["repo"] = side.get("repo") or summary.get("repo")
            proj["seats"].append(seat)
            merged += 1
    if merged:
        counts = {"queued": 0, "in_flight": 0, "blocked": 0, "settled": 0,
                  "total": len(proj["seats"])}
        for seat in proj["seats"]:
            pipe = seat.get("pipeline") or "queued"
            counts[pipe] = counts.get(pipe, 0) + 1
        proj["counts"] = counts
        proj["multi_dispatch"] = {
            "live": [s["dispatch_id"] for s in live_summaries],
            "followed": primary,
            "merged_seats": merged,
        }
    return proj


# ── plan context (the "now" view) ───────────────────────────────────────────
#
# The event stream carries a plan BASENAME only (redaction law: no task bodies,
# no absolute paths). The now view needs a little more than that: why this run
# exists and what each live seat was actually asked to do. Both come from the
# plan file on disk, read here, never from the stream:
#
#   purpose   the first comment line of the plan (its header)
#   task      the FIRST SENTENCE of that seat's line, cut at 120 chars
#   waves     how many waves the plan declares, so a seat can say "wave 2 of 3"
#
# The whole task body is never published. What is published passes the same
# secret scrub the Almanac uses.

TASK_MAX = 120
_SECRET_PATTERNS = [
    re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{12,}"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._-]{12,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def scrub_text(value, limit=200):
    """One clean line: control chars out, secret shapes redacted, capped."""
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value or ""))
    text = re.sub(r"\s+", " ", text).strip()
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[redacted]", text)
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + "…"
    return text


def activity_path(value):
    """A progress path as the Floor may render it: repo-relative or a marker.

    The writer already strips anything outside the repo. The projector refuses
    to trust that twice: an absolute path or a parent escape becomes the marker
    here too, so no operator path can reach the page through a hand-written
    stream line.
    """
    if not value or not isinstance(value, str):
        return None
    text = scrub_text(value, 120)
    if not text:
        return None
    if os.path.isabs(text) or text.startswith(os.pardir) or "/../" in text:
        return OUTSIDE_REPO
    return text


def program_name(value):
    """A progress program name as the Floor may render it: one bare word.

    The reader already reduced the command to its first token and a path to
    its basename. The projector refuses to trust that twice: anything that is
    not a bare word (a path, an option, an argument) is dropped here too, so a
    hand-written stream line cannot put an operator path on the page.
    """
    if not value or not isinstance(value, str):
        return None
    text = scrub_text(value, 40)
    if "/" in text or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", text):
        return None
    return text


def seat_activity(ev, ts):
    """Newest seat_progress folded into the seat object as `activity`."""
    phase = ev.get("phase")
    tool = ev.get("tool")
    activity = {
        "ts": ts,
        "phase": phase if phase in PHASES else None,
        "tool": scrub_text(tool, 40) if tool else None,
        "path": activity_path(ev.get("path")),
        # Program name of the seat's last shell command (writer-reduced).
        "program": program_name(ev.get("program")),
    }
    for key in ("files_edited", "commands_run", "tests_run", "commits_made"):
        value = ev.get(key)
        activity[key] = value if isinstance(value, int) else 0
    return activity


# Where a path outside the worktree may begin inside one token: a slash, a
# home or a variable, a parent escape, any of them after an optional file:
# scheme, at the start of the token or right after a character that cannot be
# part of a relative path (fix:/Users/x, path=/Users/x, x=$HOME/y, see:../z).
# A slash after a path character (scripts/notify.sh, feat/x) is not a start.
PATH_START = re.compile(r"(?i)(?<![\w.~$/+@%-])(?:file:)?(?:[/~$]|\.\.(?=/|$))")
# A URL is left to the whole-token rule: its :// is not a path start.
URL_SCHEME = re.compile(r"(?i)^(?!file:)[a-z][a-z0-9+.-]*://")
WRAPPERS = "(\"'`"


def percent_decode(token):
    """The token with its percent escapes unfolded, so %2F reads as a slash.

    A percent-encoded slash is still a slash (and %7E a home, %24 a variable,
    %2E%2E a parent escape); the path rule must see it before it decides the
    token has no slash. Decoded again while it changes, bounded, so a doubly
    encoded %252F does not survive one pass. A stray percent is left alone.
    """
    for _ in range(4):
        if "%" not in token:
            break
        decoded = unquote(token)
        if decoded == token:
            break
        token = decoded
    return token


def task_path(token):
    """One slash token of a task line, as the Floor may print it.

    Same law as activity_path: an operator path never reaches the page. A
    path inside this worktree is kept, repo-relative; anything else that
    reads as a path (absolute, home, variable, parent escape) becomes the
    marker, whether the token is the path or the path sits inside it after
    a colon, an equals sign or a backtick, or hides behind percent escapes
    (%2FUsers%2Fx). Punctuation and wrappers around the token stay where
    they were; a token that reads as no path is returned as it came.
    """
    decoded = percent_decode(token)
    core = decoded.rstrip(".,;:!?)'\"`")
    tail = decoded[len(core):]
    lead = ""
    while core and core[0] in WRAPPERS:
        lead, core = lead + core[0], core[1:]
    if not core or "/" not in core:
        return token
    if not URL_SCHEME.match(core):
        start = PATH_START.search(core)
        if start:
            lead, core = lead + core[:start.start()], core[start.start():]
    if core.lower().startswith("file:"):
        core = core[5:]
    if os.path.isabs(core):
        relative = os.path.relpath(core, REPO_DIR)
        if relative.startswith(os.pardir):
            return lead + OUTSIDE_REPO + tail
        core = relative
    elif core.startswith(("~", "$")) or os.pardir in core.split("/"):
        return lead + OUTSIDE_REPO + tail
    return lead + core + tail


def mark_paths(value):
    """One line with every slash token checked against the worktree.

    The rule of task lines (task_path) applied to any text the Floor or the
    push may print: a PR title, a NEEDS YOU line. Control chars and runs of
    whitespace become one space first so a path cannot hide behind a tab.
    """
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value or ""))
    text = re.sub(r"\s+", " ", text).strip()
    return " ".join(task_path(tok) if "/" in tok or "%" in tok else tok
                    for tok in text.split(" "))


def first_sentence(value, limit=TASK_MAX):
    """The one line of a seat task the Floor may print. Never the whole body.

    Scrubbed like now.program and activity.path: control chars out, every
    slash token checked against the worktree (task_path), secret shapes
    redacted. Cut at the first sentence end whatever its length, else at
    ``limit``, so a short opener never lets the rest of the body through.
    """
    text = mark_paths(value)
    match = re.match(r"^(.*?[.!?])(?:\s|$)", text)
    if match:
        text = match.group(1)
    return scrub_text(text, limit)


# The issue a plan serves is named in its header, as "Issue NNNN" (issue 72).
# The same pattern lives in scripts/queue.sh so the queue and the Floor agree.
ISSUE_RE = re.compile(r"\bIssue\s+#?(\d{1,7})\b", re.IGNORECASE)


def parse_issue(text):
    """Issue number a header line names (pattern ``Issue NNNN``), else None."""
    match = ISSUE_RE.search(str(text or ""))
    return int(match.group(1)) if match else None


# A plan header carries machine directives as well as prose. The purpose the
# Floor prints is what a person would read out loud, so a directive line is
# skipped and the first prose comment wins. Same rule as scripts/queue.sh
# (is_machine_header), so the queue and the Floor never disagree about why a
# run exists.
MACHINE_HEADER_RE = re.compile(
    r"^(dispatch|after|fix-round|law|schema|protocol|usage|ref|refs|generated by)\b[: ]",
    re.IGNORECASE)


def is_machine_header(body):
    """True when this plan comment line is a directive, not a purpose."""
    return bool(MACHINE_HEADER_RE.match(body)) or not re.search(r"[A-Za-z]", body)


def resolve_plan_path(plan_name, queue_entries):
    """Find the plan file a stream names by basename. Repo paths only.

    Order: the queue (it stores the repo-relative path the orchestrator armed),
    then a shallow walk of wave-plans/. Returns None when the plan is not on
    this machine, which is a normal state, not an error.
    """
    base = os.path.basename(str(plan_name or ""))
    if not base:
        return None
    for entry in queue_entries or []:
        candidate = str(entry.get("plan") or "")
        if os.path.basename(candidate) != base:
            continue
        path = candidate if os.path.isabs(candidate) else os.path.join(REPO_DIR, candidate)
        if os.path.isfile(path):
            return path
    root = os.path.join(REPO_DIR, "wave-plans")
    for dirpath, _dirnames, filenames in os.walk(root):
        if base in filenames:
            return os.path.join(dirpath, base)
    return None


def parse_plan(path, full_task=False):
    """Fold a plan file into {purpose, waves, seats[]}. Mirrors dispatch.sh.

    ``purpose`` is the first PROSE comment line of the header (see
    is_machine_header): the same line scripts/queue.sh would have stored.

    ``full_task`` adds ``task_text`` (the whole task field) to every seat. Off
    for the Floor, which publishes the first sentence only; the queue runner
    turns it on in-process to write a fix plan, and nothing publishes it.

    Plan line: ``[wave] | agent | task | [branch]``. The branch is only the last
    field and only when it looks like a branch slug, exactly as dispatch.sh
    decides, so seat index and branch line up with what the stream reports.
    """
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.readlines()
    except OSError:
        return None

    refs = plan_refs("".join(raw), os.path.basename(path))
    purpose = ""
    issue = None
    lines = []
    for line in raw:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            body = stripped.lstrip("#").strip()
            if issue is None:
                issue = parse_issue(body)
            if not purpose and body and not is_machine_header(body):
                purpose = scrub_text(body)
            continue
        lines.append(stripped)
    if not lines:
        return {"plan": rel_safe(path), "purpose": purpose, "issue": issue,
                "waves": 0, "seats": [], "refs": refs}

    # Format detection: a leading integer field means the plan is wave-aware.
    first_field = lines[0].split("|")[0].strip()
    wave_format = first_field.isdigit()

    seats, waves = [], []
    for index, line in enumerate(lines):
        fields = [f.strip() for f in line.split("|")]
        if wave_format:
            wave = int(fields[0]) if fields[0].isdigit() else None
            agent = fields[1] if len(fields) > 1 else None
            start = 2
        else:
            wave = 1
            agent = fields[0] if fields else None
            start = 1
        last = fields[-1] if fields else ""
        is_branch = bool(re.match(r"^[A-Za-z0-9/_.-]+$", last)) and "/" in last
        if is_branch and len(fields) > start + 1:
            branch = last
            desc = " | ".join(fields[start:-1])
        else:
            branch = None
            desc = " | ".join(fields[start:])
        if wave is not None and wave not in waves:
            waves.append(wave)
        seat = {
            "index": str(index),
            "wave": wave,
            "agent": agent,
            "branch": branch,
            "task": first_sentence(desc),
        }
        if full_task:
            seat["task_text"] = desc
        seats.append(seat)
    return {"plan": rel_safe(path), "purpose": purpose, "issue": issue,
            "waves": len(waves) or 1, "seats": seats, "refs": refs}


def cached_plan(cache, name, queue_entries):
    """Parsed plan for a stream's plan basename, parsed once per projection."""
    base = os.path.basename(str(name or ""))
    if base not in cache:
        cache[base] = parse_plan(resolve_plan_path(base, queue_entries))
    return cache[base]


def attach_plan_context(proj, queue_entries, plan_cache=None):
    """Give every seat the purpose of its plan and its one-line task.

    Joined by seat: the stream's task_id (the plan line index, branch must
    agree), then branch and wave together, then branch, then agent. A seat the
    plan cannot explain keeps its stream facts and says nothing more: no
    guessed task ever reaches the page.
    """
    cache = {} if plan_cache is None else plan_cache

    def plan_for(name):
        return cached_plan(cache, name, queue_entries)

    # The followed run's plan explains its own seats; a merged foreign seat is
    # explained by the plan of ITS dispatch, looked up the same way.
    context = plan_for(proj.get("plan"))
    if context:
        proj["plan_context"] = {"plan": context["plan"], "purpose": context["purpose"],
                                "waves": context["waves"], "seats": len(context["seats"])}
    for seat in proj.get("seats") or []:
        plan = plan_for(seat.get("plan") or proj.get("plan"))
        if not plan:
            continue
        # Keyed by seat, never by branch alone: the stream's task_id is the
        # plan line index at dispatch time (usable when the branch agrees, so
        # a plan edited after dispatch cannot mis-point it); then branch and
        # wave together, because a critic seat shares its producer's branch
        # but sits in a later wave (branch alone would hand it the wave 1
        # line, issue 86); then branch; then agent.
        match = None
        by_index = next((s for s in plan["seats"] if s["index"] == str(seat.get("task_id"))), None)
        if by_index is not None and (not seat.get("branch") or not by_index.get("branch")
                                     or by_index["branch"] == seat["branch"]):
            match = by_index
        if match is None and seat.get("branch"):
            same_branch = [s for s in plan["seats"] if s["branch"] == seat["branch"]]
            if isinstance(seat.get("wave"), int):
                match = next((s for s in same_branch if s["wave"] == seat["wave"]), None)
            if match is None and same_branch:
                match = same_branch[0]
        if match is None and seat.get("agent"):
            match = next((s for s in plan["seats"] if s["agent"] == seat["agent"]), None)
        seat["plan_purpose"] = plan["purpose"] or None
        seat["wave_total"] = plan["waves"]
        if match:
            seat["task"] = match["task"] or None
            # Issue 72 names it task_line: the first sentence of the seat's
            # plan line, cut at TASK_MAX and scrubbed (first_sentence above).
            seat["task_line"] = seat["task"]
    return proj


# ── gh enrichment (issue milestone, PR for a branch): optional, never fatal ──
#
# The only thing the projector ever asks the network for, and only through the
# gh CLI, under the Almanac's rules (docs/experience-data.md § gh enrichment):
# a missing binary, missing auth, a timeout, a non-zero exit or a bad payload
# all degrade to a lookup marked ``skipped`` with a reason. Nothing here raises
# and nothing waits past the per-call timeout, so the projection is written
# with or without answers. Titles only: no issue or PR bodies, no comments.
# Answers (and failures) are cached per projection and for GH_CACHE_TTL_S
# across projections, so the watcher does not ask the same question every two
# seconds, and one projection spends at most GH_CALL_BUDGET calls.
#
# A repo name in the stream is a directory name, not a slug. The slug is
# <owner>/<repo> with the owner from FLEET_GH_OWNER, else the owner of this
# repo's origin remote. A lookup is only ``verified`` when gh answered for
# that slug, so a wrong owner reads as skipped, never as a guess.

_GH_CACHE = {}   # (kind, slug, key) -> (expires_at, answer, reason)
_REPO_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9/_.+-]{0,200}$")


def run_gh(args, timeout=None):
    """Run gh, never raise. (rc, stdout, stderr); 127 missing, 124 timed out."""
    timeout = GH_TIMEOUT_S if timeout is None else timeout
    try:
        proc = subprocess.run(["gh"] + list(args), capture_output=True, text=True,
                              timeout=timeout, cwd=REPO_DIR)
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "gh not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout
    except OSError as exc:
        return 1, "", str(exc)


def github_owner():
    """FLEET_GH_OWNER, else the owner of this repo's origin remote, else None."""
    owner = os.environ.get("FLEET_GH_OWNER", "").strip()
    if owner:
        return owner if _REPO_NAME_RE.match(owner) else None
    try:
        proc = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True,
                              text=True, timeout=5, cwd=REPO_DIR)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.search(r"github\.com[:/]([A-Za-z0-9_.-]+)/", proc.stdout or "")
    return match.group(1) if match else None


def _gh_fail(what, rc):
    if rc == 124:
        return "%s timed out after %ss" % (what, GH_TIMEOUT_S)
    if rc == 127:
        return "%s: gh not found" % what
    return "%s failed (exit %d)" % (what, rc)


class GhEnricher:
    """Per-projection gh lookups behind a call budget and a shared TTL cache."""

    def __init__(self, enabled=True, budget=GH_CALL_BUDGET):
        self.enabled = enabled
        self.budget = budget
        self.calls = 0
        self.cached = 0
        self.skipped = 0
        self.status = None      # resolved on first use, never before
        self.reason = None
        self.owner = None

    def _call(self, key, fetch):
        """(answer, reason). answer None means skipped, and reason says why."""
        now = time.time()
        hit = _GH_CACHE.get(key)
        if hit and hit[0] > now:
            self.cached += 1
            return hit[1], hit[2]
        if self.calls >= self.budget:
            self.skipped += 1
            return None, "gh call budget (%d) spent for this projection" % self.budget
        self.calls += 1
        answer, reason = fetch()
        _GH_CACHE[key] = (now + GH_CACHE_TTL_S, answer, reason)
        return answer, reason

    def probe(self):
        """True when gh can answer. Decided once per projection, cached across."""
        if self.status is not None:
            return self.status == "ok"
        if not self.enabled:
            self.status, self.reason = "disabled", "disabled (--no-gh or FLEET_DESK_NO_GH=1)"
        elif shutil.which("gh") is None:
            self.status, self.reason = "unavailable", "gh not on PATH"
        else:
            def auth():
                rc, _out, _err = run_gh(["auth", "status"])
                return (True, None) if rc == 0 else (None, _gh_fail("gh auth status", rc))
            ok, reason = self._call(("auth",), auth)
            if not ok:
                self.status, self.reason = "unauthenticated", reason
            else:
                self.owner = github_owner()
                if self.owner:
                    self.status, self.reason = "ok", None
                else:
                    self.status, self.reason = "error", "no GitHub owner (set FLEET_GH_OWNER)"
        return self.status == "ok"

    def slug(self, repo):
        if not self.probe():
            return None, self.reason
        name = str(repo or "").strip()
        if not name or not _REPO_NAME_RE.match(name):
            return None, "no repo name to look up"
        return "%s/%s" % (self.owner, name), None

    def issue(self, repo, number):
        """Milestone title of one issue. Adds nothing but the milestone."""
        out = {"number": number if isinstance(number, int) else None,
               "milestone": None, "lookup": "skipped", "reason": None}
        if out["number"] is None:
            out["reason"] = "no plan header names an issue"
            return out
        slug, reason = self.slug(repo)
        if not slug:
            out["reason"] = reason
            return out

        def fetch():
            rc, text, _err = run_gh(["issue", "view", str(number), "-R", slug,
                                     "--json", "number,milestone"])
            if rc != 0:
                return None, _gh_fail("gh issue view %s/%d" % (slug, number), rc)
            try:
                data = json.loads(text or "")
            except ValueError:
                return None, "gh issue view returned no JSON"
            if not isinstance(data, dict) or data.get("number") != number:
                return None, "gh issue view returned an unexpected payload"
            milestone = data.get("milestone")
            title = milestone.get("title") if isinstance(milestone, dict) else None
            return {"milestone": scrub_text(title, GH_TITLE_MAX) if title else None}, None

        answer, reason = self._call(("issue", slug, number), fetch)
        if answer is None:
            out["reason"] = reason
            return out
        out["milestone"] = answer["milestone"]
        out["lookup"] = "verified"
        return out

    def pr(self, repo, branch):
        """The open, else merged, PR for a branch: number, title, state, url."""
        out = {"branch": branch or None, "number": None, "title": None,
               "state": None, "url": None, "lookup": "skipped", "reason": None}
        if not branch:
            out["reason"] = "no branch"
            return out
        if not isinstance(branch, str) or not _BRANCH_RE.match(branch):
            out["reason"] = "branch is not a plain slug"
            return out
        slug, reason = self.slug(repo)
        if not slug:
            out["reason"] = reason
            return out

        def fetch():
            rc, text, _err = run_gh(["pr", "list", "-R", slug, "--head", branch,
                                     "--state", "all", "--limit", "10",
                                     "--json", "number,title,state,url"])
            if rc != 0:
                return None, _gh_fail("gh pr list %s %s" % (slug, branch), rc)
            try:
                rows = json.loads(text or "")
            except ValueError:
                return None, "gh pr list returned no JSON"
            if not isinstance(rows, list):
                return None, "gh pr list returned an unexpected payload"
            pick = None
            for want in ("OPEN", "MERGED"):
                pick = next((r for r in rows if isinstance(r, dict)
                             and r.get("state") == want), None)
                if pick:
                    break
            if not pick:
                return {}, None
            return {"number": pick.get("number") if isinstance(pick.get("number"), int) else None,
                    "title": scrub_text(mark_paths(pick.get("title")), GH_TITLE_MAX) or None,
                    "state": str(pick.get("state") or "").lower() or None,
                    "url": scrub_text(pick.get("url"), 200) or None}, None

        answer, reason = self._call(("pr", slug, branch), fetch)
        if answer is None:
            out["reason"] = reason
            return out
        out.update(answer)
        out["lookup"] = "verified"
        if not answer:
            out["reason"] = "no open or merged PR for this branch"
        return out

    # ── Floor v3 lookups: comments reduced to verdicts, milestones, names ──

    def _skipped(self, out, reason):
        out["lookup"] = "skipped"
        out["reason"] = reason
        return out

    def pr_view(self, repo, number):
        """One open PR: merge state, draft flag, and its critic comments reduced
        to verdicts (critic_record). Bodies are read here and dropped here."""
        out = {"number": number, "title": None, "state": None, "is_draft": None,
               "merge_state": None, "url": None, "branch": None, "comments": [],
               "lookup": "skipped", "reason": None}
        if not isinstance(number, int):
            return self._skipped(out, "no PR number")
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(
                ["pr", "view", str(number), "-R", slug, "--json",
                 "number,title,state,isDraft,mergeStateStatus,url,headRefName,comments,reviews"],
                "gh pr view %s#%d" % (slug, number), dict)
            if data is None:
                return None, why
            records = []
            for c in data.get("comments") or []:
                if isinstance(c, dict):
                    rec = critic_record(c.get("id"), c.get("url"), c.get("createdAt"), c.get("body"))
                    if rec:
                        records.append(rec)
            for r in data.get("reviews") or []:
                if isinstance(r, dict):
                    rec = critic_record(r.get("id"), r.get("url"), r.get("submittedAt"),
                                        r.get("body"), kind="review")
                    if rec:
                        records.append(rec)
            # The title is text an author wrote: slash tokens are checked
            # against the worktree (mark_paths) like a task line, so an
            # operator path in a PR title never reaches the page or the push.
            return {"title": scrub_text(mark_paths(data.get("title")), GH_TITLE_MAX) or None,
                    "state": str(data.get("state") or "").lower() or None,
                    "is_draft": bool(data.get("isDraft")),
                    "merge_state": str(data.get("mergeStateStatus") or "").upper() or None,
                    "url": scrub_text(data.get("url"), 200) or None,
                    "branch": data.get("headRefName") if isinstance(data.get("headRefName"), str) else None,
                    "comments": records}, None

        answer, reason = self._call(("pr_view", slug, number), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out.update({k: (list(v) if k == "comments" else v) for k, v in answer.items()})
        out["lookup"] = "verified"
        return out

    def _json_fetch(self, args, what, want):
        rc, text, _err = run_gh(args)
        if rc != 0:
            return None, _gh_fail(what, rc)
        try:
            data = json.loads(text or "")
        except ValueError:
            return None, "%s returned no JSON" % what
        if not isinstance(data, want):
            return None, "%s returned an unexpected payload" % what
        return data, None

    def issue_comments(self, repo, number, since):
        """Critic comments on a findings issue since a time, reduced to verdicts."""
        out = {"issue": number, "comments": [], "lookup": "skipped", "reason": None}
        if not isinstance(number, int):
            return self._skipped(out, "no issue number")
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(
                ["api", "repos/%s/issues/%d/comments?since=%s&per_page=100" % (slug, number, since)],
                "gh api issues/%d/comments" % number, list)
            if data is None:
                return None, why
            records = []
            for c in data:
                if isinstance(c, dict):
                    rec = critic_record(c.get("id"), c.get("html_url"), c.get("created_at"), c.get("body"))
                    if rec:
                        records.append(rec)
            return records, None

        answer, reason = self._call(("issue_comments", slug, number, since), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["comments"] = list(answer)
        out["lookup"] = "verified"
        return out

    def names(self, repo, kind):
        """Names of the repository variables or secrets (never their values)."""
        out = {"kind": kind, "names": [], "lookup": "skipped", "reason": None}
        if kind not in ("variable", "secret"):
            return self._skipped(out, "unknown kind")
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch([kind, "list", "-R", slug, "--json", "name"],
                                         "gh %s list %s" % (kind, slug), list)
            if data is None:
                return None, why
            return sorted({str(d.get("name")) for d in data if isinstance(d, dict) and d.get("name")}), None

        answer, reason = self._call(("names", slug, kind), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["names"] = list(answer)
        out["lookup"] = "verified"
        return out

    def milestones(self, repo):
        """Open milestones of a repo: title, number, url, counts, updated_at."""
        out = {"milestones": [], "lookup": "skipped", "reason": None}
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(
                ["api", "repos/%s/milestones?state=open&per_page=100" % slug],
                "gh api %s/milestones" % slug, list)
            if data is None:
                return None, why
            rows = []
            for m in data:
                if not isinstance(m, dict) or not m.get("title"):
                    continue
                rows.append({"title": scrub_text(m.get("title"), GH_TITLE_MAX),
                             "number": m.get("number") if isinstance(m.get("number"), int) else None,
                             "url": scrub_text(m.get("html_url"), 200) or None,
                             "open_issues": m.get("open_issues") if isinstance(m.get("open_issues"), int) else None,
                             "closed_issues": m.get("closed_issues") if isinstance(m.get("closed_issues"), int) else None,
                             "updated_at": m.get("updated_at") if isinstance(m.get("updated_at"), str) else None})
            return rows, None

        answer, reason = self._call(("milestones", slug), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["milestones"] = list(answer)
        out["lookup"] = "verified"
        return out

    def milestone_issues(self, repo, title):
        """Issues of one milestone: number, title, state. Titles only."""
        out = {"issues": [], "lookup": "skipped", "reason": None}
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(
                ["issue", "list", "-R", slug, "--milestone", title, "--state", "all",
                 "--limit", "100", "--json", "number,title,state"],
                "gh issue list %s milestone" % slug, list)
            if data is None:
                return None, why
            return [{"number": i["number"], "title": scrub_text(i.get("title"), GH_TITLE_MAX),
                     "state": str(i.get("state") or "").lower()}
                    for i in data if isinstance(i, dict) and isinstance(i.get("number"), int)], None

        answer, reason = self._call(("milestone_issues", slug, title), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["issues"] = list(answer)
        out["lookup"] = "verified"
        return out

    def issue_exit(self, repo, number):
        """The exit criterion sentence an epic body carries, else None.

        The body is read here and dropped here: one sentence, scrubbed and
        capped, is all that leaves. A verified body with no such sentence is
        ``verified`` with ``exit: null``."""
        out = {"issue": number, "exit": None, "lookup": "skipped", "reason": None}
        if not isinstance(number, int):
            return self._skipped(out, "no issue number")
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(["issue", "view", str(number), "-R", slug, "--json", "body"],
                                         "gh issue view %s#%d body" % (slug, number), dict)
            if data is None:
                return None, why
            for line in str(data.get("body") or "").splitlines():
                match = EXIT_LINE_RE.match(line.strip())
                if match:
                    sentence = re.sub(r"^[\s*_`]+", "", match.group(1))
                    return {"exit": first_sentence(sentence, 200) or None}, None
            return {"exit": None}, None

        answer, reason = self._call(("issue_exit", slug, number), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["exit"] = answer["exit"]
        out["lookup"] = "verified"
        return out

    def merged_prs(self, repo):
        """The newest merged PRs of a repo: number, title, branch, merged_at, milestone."""
        out = {"prs": [], "lookup": "skipped", "reason": None}
        slug, reason = self.slug(repo)
        if not slug:
            return self._skipped(out, reason)

        def fetch():
            data, why = self._json_fetch(
                ["pr", "list", "-R", slug, "--state", "merged", "--limit", "100",
                 "--json", "number,title,headRefName,mergedAt,milestone"],
                "gh pr list %s merged" % slug, list)
            if data is None:
                return None, why
            rows = []
            for p in data:
                if not isinstance(p, dict) or not isinstance(p.get("number"), int):
                    continue
                milestone = p.get("milestone")
                rows.append({"number": p["number"],
                             "title": scrub_text(p.get("title"), GH_TITLE_MAX) or None,
                             "branch": p.get("headRefName") if isinstance(p.get("headRefName"), str) else None,
                             "merged_at": p.get("mergedAt") if isinstance(p.get("mergedAt"), str) else None,
                             "milestone": scrub_text(milestone.get("title"), GH_TITLE_MAX)
                             if isinstance(milestone, dict) and milestone.get("title") else None})
            return rows, None

        answer, reason = self._call(("merged_prs", slug), fetch)
        if answer is None:
            return self._skipped(out, reason)
        out["prs"] = list(answer)
        out["lookup"] = "verified"
        return out

    def meta(self):
        """What the enrichment did for this projection, for the page and tests."""
        status = self.status or "skipped"
        reason = self.reason if self.status else "no lookup was needed"
        return {"status": status, "reason": reason, "owner": self.owner,
                "calls": self.calls, "cached": self.cached, "skipped": self.skipped}


# ── repo, issue, task line and PR on every seat, queue entry and landing ─────
#
# Issue 72: with two repos live at once the Floor must say which repo a seat
# belongs to and which requirement it serves. Repo is a first-class field
# everywhere; the issue is the number the plan header names; the milestone
# and the PR come from gh under the rules above. Every lookup object carries
# ``lookup`` (verified or skipped) and a reason, so the page never has to
# guess why a field is empty.

def issue_context(repo, plan, known, gh):
    """Issue object for one seat or queue entry: number, source, milestone."""
    number, source = None, "none"
    if plan and isinstance(plan.get("issue"), int):
        number, source = plan["issue"], "plan"
    elif known:
        candidate = known.get("issue")
        if not isinstance(candidate, int):
            candidate = parse_issue(known.get("purpose"))
        if candidate is not None:
            number, source = candidate, "queue"
    out = gh.issue(repo, number)
    out["source"] = source
    return out


def repo_summaries(proj, live_summaries):
    """One counts object per repo seen today: seats and dispatches live first."""
    repos = {}

    def bucket(name):
        key = str(name) if name else "unknown"
        if key not in repos:
            repos[key] = {"repo": key, "seats_live": 0, "dispatches_live": 0,
                          "queued": 0, "landed_today": 0, "dispatch_ids": []}
        return repos[key]

    for summary in live_summaries or []:
        entry = bucket(summary.get("repo"))
        entry["dispatches_live"] += 1
        entry["dispatch_ids"].append(summary.get("dispatch_id"))
    seen = {d for r in repos.values() for d in r["dispatch_ids"]}
    if proj.get("status") == "running" and proj.get("dispatch_id") not in seen:
        entry = bucket(proj.get("repo"))
        entry["dispatches_live"] += 1
        entry["dispatch_ids"].append(proj.get("dispatch_id"))
    for seat in proj.get("seats") or []:
        if seat.get("status") == "running":
            bucket(seat.get("repo"))["seats_live"] += 1
    for entry in proj.get("queue") or []:
        bucket(entry.get("repo"))["queued"] += 1
    for row in proj.get("today") or []:
        bucket(row.get("repo"))["landed_today"] += 1
    return sorted(repos.values(),
                  key=lambda r: (-r["seats_live"], -r["dispatches_live"], r["repo"]))


def attach_seat_context(proj, queue_entries, plan_cache, gh):
    """Repo, issue, task_line and PR on every seat (live and replay alike)."""
    index = queue_purpose_index(queue_entries)
    for seat in proj.get("seats") or []:
        seat["repo"] = seat.get("repo") or proj.get("repo")
        plan_name = seat.get("plan") or proj.get("plan")
        plan = cached_plan(plan_cache, plan_name, queue_entries)
        known = index.get(os.path.basename(str(plan_name or "")))
        seat["issue"] = issue_context(seat["repo"], plan, known, gh)
        seat["task_line"] = seat.get("task") or None
        seat["pr"] = gh.pr(seat["repo"], seat.get("branch"))
    return proj


def attach_replay_context(proj, queue_file, gh):
    """What a replay seat may still carry: repo, issue, task_line and PR.

    The plan on disk explains a historical seat as well as a live one, and
    the gh rules are the same (optional, never fatal). The queue is read only
    to locate plan files; a replay publishes no queue, no day, no repos and
    no summary, because the past has no present.
    """
    entries, _warnings = read_queue(queue_file)
    plan_cache = {}
    attach_plan_context(proj, entries, plan_cache)
    attach_seat_context(proj, entries, plan_cache, gh)
    proj["gh_enrichment"] = gh.meta()
    return proj


def attach_context(proj, queue_entries, live_summaries, plan_cache, gh):
    """Repo, issue, task_line and PR on seats, queue entries and landings."""
    index = queue_purpose_index(queue_entries)
    attach_seat_context(proj, queue_entries, plan_cache, gh)
    for entry in proj.get("queue") or []:
        plan = cached_plan(plan_cache, entry.get("plan"), queue_entries)
        known = index.get(entry.get("plan_basename"))
        entry["issue"] = issue_context(entry.get("repo"), plan, known, gh)
    # Floor v3-C: a landing yesterday gets the same PR join as one today.
    for row in list(proj.get("today") or []) + list(proj.get("yesterday") or []):
        row["prs"] = [gh.pr(row.get("repo"), b) for b in row.get("branches") or []]
        found = next((p for p in row["prs"] if p.get("number") is not None), None)
        row["pr"] = found or (row["prs"][0] if row["prs"] else gh.pr(row.get("repo"), None))
    proj["repos"] = repo_summaries(proj, live_summaries)
    proj["gh_enrichment"] = gh.meta()
    return proj


# ── NEEDS YOU and INITIATIVES (Floor v3, wave A) ─────────────────────────────
#
# docs/proposals/floor-v3-purpose.md § 4.2 and § 4.5. The Floor exists so the
# owner never has to ask "is anything waiting on me": needs_you[] is one row
# per item, newest first, each with one action, and initiatives[] is one row
# per open milestone with activity in the last 30 days.
#
# Honesty rule: needs_you never invents an item. Every entry cites where it
# came from (a comment id, a stream event, or a file and line) and says
# whether the fact was verified at its source. The gh lookups follow the
# rules above (optional, cached, budgeted, never fatal); a check that could
# not run is listed in needs_you_meta.checks as skipped with its reason, so
# the page can say "critic verdicts unverified" instead of "nothing needs
# you". Comment bodies are read in-process only, to find the verdict and the
# PR a findings-issue comment belongs to; what is published is the comment
# id, its url, its time, the verdict, the round and the heading of its first
# line. Never the body.

NEEDS_YOU_ACTIONS = {
    "critic_block": "open the comment",
    "ready_to_merge": "merge",
    "quiet_seat": "check the log",
    "failed_dispatch": "see the output",
    "prd_proposed": "approve or edit",
    "missing_variable": "set it",
}
NEEDS_YOU_CHECKS = ("critic_block", "ready_to_merge", "quiet_seat",
                    "failed_dispatch", "prd_proposed", "missing_variable",
                    "merged_branch")
INITIATIVE_ACTIVE_DAYS = 30
COMMENT_LOOKBACK_DAYS = 7
STEM_MAX = 80

# The critic first-line convention: the first line of the comment carries the
# word CRITIC, the verdict opens the text after a colon on that line or closes
# it, and a re-review says ROUND n. A body line counts only when it opens with
# the explicit Verdict: label; a bare verdict word on a body line is not one
# (the landing rule reads first lines only).
# "CRITIC TILE CONNECT GUIDE ROUND 2: SAFE-TO-MERGE". See first_line_verdict.
CRITIC_LINE_RE = re.compile(r"\bCRITIC\b")
VERDICT_WORDS = "BLOCK-ESCALATE|BLOCK-FIX|BLOCK-CLOSE|SAFE-TO-MERGE|APPROVE-MERGE|BLOCK|SAFE"
VERDICT_RE = re.compile(r"\b(%s)\b" % VERDICT_WORDS)
# A verdict that closes the first line ("CRITIC FLOOR V3A BLOCK-FIX").
VERDICT_TAIL_RE = re.compile(r"(?:^|\s)(%s)$" % VERDICT_WORDS)
# A verdict standing as a token of its own, markdown and closing punctuation
# allowed around it ("**BLOCK-FIX**", "(BLOCK-FIX)"). A heading word followed
# by a colon ("BLOCK:") is not one. See first_line_verdict.
VERDICT_TOKEN_RE = re.compile(r"(?<!\S)[*_`(]*(%s)[*_`).!,]*(?!\S)" % VERDICT_WORDS)
ROUND_RE = re.compile(r"\bROUND\s+(\d{1,3})\b", re.IGNORECASE)
BLOCK_VERDICTS = frozenset(("BLOCK-ESCALATE", "BLOCK-FIX", "BLOCK-CLOSE", "BLOCK"))
SAFE_VERDICTS = frozenset(("SAFE-TO-MERGE", "APPROVE-MERGE", "SAFE"))

# What a plan file names, read in-process and published as numbers and names
# only: PRD rows (S11), repository variables (IRIS_PUBLIC_URL), the findings
# issue its critics post on, the PRs it fixes, its epic and its wave id.
S_NUMBER_RE = re.compile(r"\bS(\d{1,3})\b")
VARIABLE_RE = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b")
FINDINGS_ISSUE_RE = re.compile(r"\bcomment on (?:the )?issue #?(\d{1,7})\b", re.IGNORECASE)
PR_REF_RE = re.compile(r"\bPR #?(\d{1,7})\b", re.IGNORECASE)
HASH_REF_RE = re.compile(r"#(\d{1,7})\b")
EPIC_RE = re.compile(r"\bepic #?(\d{1,7})\b", re.IGNORECASE)
WAVE_ID_RE = re.compile(r"\bW(\d{1,2})(?:-([A-Z]))?\b")
WAVE_FILE_RE = re.compile(r"(?:^|-)w(\d{1,2})([a-z])?(?:-|\.plan$)")
DISPATCH_LINE_RE = re.compile(r"^DISPATCH:\s*\S+\s+(\S+)", re.IGNORECASE)
PRD_ROW_RE = re.compile(r"^\|\s*S(\d{1,3})\s*\|")
CONTRACT_ROW_RE = re.compile(r"^\|\s*`([A-Z][A-Z0-9_]+)`\s*\|")
EXIT_LINE_RE = re.compile(
    r"^\W*(?:exit(?:\s+criteri(?:on|a))?|done when|definition of done)\b[^:]*:\s*(.+)$",
    re.IGNORECASE)


def plan_refs(text, basename):
    """Numbers and names a plan file carries, for the checks above.

    Read from the whole file in-process; nothing here is task text. The repo
    is the basename of the DISPATCH line's repo url, the wave id the plan
    naming convention (W2-A in the header, else -w2a- in the file name).
    """
    refs = {"s_numbers": [], "variables": [], "findings_issues": [], "prs": [],
            "epic": None, "wave_id": None, "repo": None}
    refs["s_numbers"] = sorted({int(m) for m in S_NUMBER_RE.findall(text)})
    refs["variables"] = sorted(set(VARIABLE_RE.findall(text)))
    refs["findings_issues"] = sorted({int(m) for m in FINDINGS_ISSUE_RE.findall(text)})
    refs["prs"] = sorted({int(m) for m in PR_REF_RE.findall(text)})
    epic = EPIC_RE.search(text)
    refs["epic"] = int(epic.group(1)) if epic else None
    for line in text.splitlines():
        body = line.strip().lstrip("#").strip()
        match = DISPATCH_LINE_RE.match(body)
        if match:
            url = match.group(1).rstrip("/")
            name = url.split("/")[-1].split(":")[-1]
            name = re.sub(r"\.git$", "", name)
            if _REPO_NAME_RE.match(name):
                refs["repo"] = name
            break
    return refs


def wave_id(purpose, basename):
    """W2-A from the header, else from the file name, else None."""
    match = WAVE_ID_RE.search(str(purpose or ""))
    if match:
        return "W%s%s" % (match.group(1), "-" + match.group(2) if match.group(2) else "")
    match = WAVE_FILE_RE.search(str(basename or "").lower())
    if match:
        return "W%s%s" % (match.group(1), "-" + match.group(2).upper() if match.group(2) else "")
    return None


def track_name(purpose):
    """The initiative a plan header names before its wave id, else None.

    "Assistant Channel W2-A: the Iris service" reads as "Assistant Channel".
    Used only for the fallback rows when gh cannot list milestones.
    """
    match = re.match(r"^(.*?)[\s:,]+W\d{1,2}(?:-[A-Z])?\b", str(purpose or ""))
    if not match:
        return None
    name = match.group(1).strip(" :,")
    return scrub_text(name, 80) or None


def first_line_verdict(first_line):
    """The verdict the first line of a critic comment carries, else None.

    Start-of-token rule: the verdict opens the text after
    a colon ("CRITIC K ROUND 2: BLOCK-FIX on two items") or closes the line
    ("CRITIC FLOOR V3A BLOCK-FIX"). A verdict quoted mid-sentence ("the last
    review said BLOCK-FIX but this is not a verdict") never counts, and a
    heading word BLOCK or SAFE before the colon never steals BLOCK-FIX or
    SAFE-TO-MERGE after it ("CRITIC V3A BLOCK: BLOCK-FIX" reads BLOCK-FIX).

    Two different verdict words standing as tokens of their own where the
    verdict is read (after the first colon, else anywhere on a line with no
    colon) make the line ambiguous, and it carries no verdict: "CRITIC FLOOR
    V3A BLOCK-FIX SAFE-TO-MERGE", with or without a colon, in either order,
    invents neither a block nor a ready item. The same word twice ("BLOCK-FIX
    (round 1 BLOCK-FIX stands)") is one verdict. A heading that itself holds
    a verdict word wants the colon form: only what follows the colon is read.
    """
    text = str(first_line or "")
    scope = text.split(":", 1)[1] if ":" in text else text
    if len(set(VERDICT_TOKEN_RE.findall(scope))) > 1:
        return None
    for segment in text.split(":")[1:]:
        match = VERDICT_RE.match(segment.strip(" \t*_`"))
        if match:
            return match.group(1)
    tail = text.rstrip(" \t.!*_`)")
    match = VERDICT_TAIL_RE.search(tail)
    if match:
        return match.group(1)
    return None


def critic_verdict(first_line, body):
    """The verdict a critic comment carries: its first line, else a body line
    that opens with the explicit Verdict: label ("Verdict: SAFE-TO-MERGE").
    A bare verdict word on a body line ("SAFE-TO-MERGE" on a line of its own)
    counts for nothing, and a verdict quoted mid-sentence ("SAFE-TO-MERGE or
    BLOCK-FIX") never counts."""
    verdict = first_line_verdict(first_line)
    if verdict:
        return verdict
    for line in str(body or "").splitlines()[1:]:
        clean = re.sub(r"^[\s*#>_`-]+", "", line).strip()
        label = re.match(r"^verdict\s*[:.]\s*", clean, flags=re.IGNORECASE)
        if label:
            match = VERDICT_RE.match(clean[label.end():])
            if match:
                return match.group(1)
    return None


def critic_record(comment_id, url, created_at, body, kind="comment"):
    """A critic comment reduced to what the Floor may know, else None.

    Kept: id, url, time, verdict, round, the heading of the first line (its
    verdict and round token removed, capped). Dropped: the body. The PR
    numbers ("PR 2829") and slash tokens (branch names) the body mentions are
    kept as numbers and slugs only, in-process, so a findings-issue comment
    can be attributed to the PR it grades. A bare "#N" is an issue reference
    by convention and is not used for attribution.
    """
    text = str(body or "")
    lines = text.strip().splitlines()
    first = lines[0].strip() if lines else ""
    if not CRITIC_LINE_RE.search(first):
        return None
    verdict = critic_verdict(first, text)
    if verdict is None:
        return None
    round_match = ROUND_RE.search(first)
    return {
        "id": comment_id,
        "url": scrub_text(url, 200) or None,
        "at": created_at if isinstance(created_at, str) else None,
        "kind": kind,
        "verdict": verdict,
        "round": int(round_match.group(1)) if round_match else 1,
        "stem": critic_stem(first),
        "_prs": {int(n) for n in PR_REF_RE.findall(text)},
        "_slugs": {tok.strip(".,;:()'\"`") for tok in text.split() if "/" in tok},
    }


def critic_stem(first_line):
    """The heading of a critic first line: the thread key, the words the Floor
    and the runner may print. Verdict words and the ROUND token are removed,
    punctuation becomes space, and the heading is the leading run of upper-case
    words: a critic who wrote a sentence on the first line still keys one
    thread, not one per round, and nothing after the heading (a path, a prompt,
    a token) survives. Never empty: "CRITIC" when nothing else is left.
    """
    stem = ROUND_RE.sub(" ", VERDICT_RE.sub(" ", str(first_line or "")))
    stem = re.sub(r"[^A-Za-z0-9 ]+", " ", stem)
    words = []
    for token in stem.split():
        if token.upper() != token:
            break
        words.append(token)
    return scrub_text(" ".join(words), STEM_MAX) or "CRITIC"


def latest_round(records):
    """The newest comment of every critic thread (thread = first-line heading).

    Newest by time of posting: a critic who takes a SAFE back with a later
    BLOCK is heard, whatever ROUND token either line carries (a ROUND 2 SAFE
    followed by a plain BLOCK-FIX reads BLOCK-FIX). The round only breaks a
    tie between comments with the same timestamp or none. A re-review
    replaces its own earlier verdict, never another critic's, so a PR is only
    clean when every thread's newest verdict is safe.
    """
    threads = {}
    for rec in records:
        key = rec["stem"].upper()
        current = threads.get(key)
        if current is None or (rec["at"] or "", rec["round"]) > (current["at"] or "", current["round"]):
            threads[key] = rec
    return sorted(threads.values(), key=lambda r: r["at"] or "", reverse=True)


def public_comment(rec):
    """The published shape of a critic comment: no body, no names from it."""
    return {k: v for k, v in rec.items() if not k.startswith("_")}


# ── the target repo on disk (PRD rows, env contract) ─────────────────────────
#
# A queued plan dispatches into another repo. Its PRD and its env contract
# live in that repo's checkout: FLEET_CHECKOUTS (colon-separated roots), else
# the fetch point scripts/run-remote.sh keeps at ~/dev/<repo>, else a sibling
# of this repo. What is published is the repo name and a path relative to it,
# never where the checkout is.

def target_checkout(repo):
    name = str(repo or "").strip()
    if not name or not _REPO_NAME_RE.match(name):
        return None
    roots = [r for r in os.environ.get("FLEET_CHECKOUTS", "").split(":") if r]
    roots += [os.path.join(os.path.expanduser("~"), "dev"), os.path.dirname(REPO_DIR)]
    for root in roots:
        candidate = os.path.join(root, name)
        if os.path.isdir(candidate):
            return candidate
    return None


def _walk_md(root, subdir):
    base = os.path.join(root, subdir)
    for dirpath, _dirnames, filenames in os.walk(base):
        for name in sorted(filenames):
            if name.endswith(".md"):
                yield os.path.join(dirpath, name)


def _read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


def prd_proposed_rows(checkout):
    """PRD table rows still PROPOSED: {S number: {file, line}}.

    A row is a table line whose first cell is S<n>; it is proposed when it
    carries the word PROPOSED and not ACCEPTED. Best effort from
    docs/prd/**/*.md of the checkout; a missing tree is an empty answer.
    """
    rows = {}
    if not checkout:
        return rows
    for path in _walk_md(checkout, os.path.join("docs", "prd")):
        for number, line in enumerate(_read_lines(path), 1):
            match = PRD_ROW_RE.match(line)
            if not match:
                continue
            if "PROPOSED" in line and "ACCEPTED" not in line:
                rows.setdefault(int(match.group(1)), {
                    "file": os.path.relpath(path, checkout).replace(os.sep, "/"),
                    "line": number})
    return rows


def contract_rows(checkout):
    """Env vars the deploy contract says come from a repository variable or
    secret: {NAME: {kind, file, line}}. Best effort from
    docs/operations/env-vars-*.md of the checkout."""
    rows = {}
    if not checkout:
        return rows
    ops = os.path.join(checkout, "docs", "operations")
    try:
        names = sorted(n for n in os.listdir(ops) if n.startswith("env-vars") and n.endswith(".md"))
    except OSError:
        return rows
    for name in names:
        path = os.path.join(ops, name)
        for number, line in enumerate(_read_lines(path), 1):
            match = CONTRACT_ROW_RE.match(line)
            if not match:
                continue
            lowered = line.lower()
            if "repository variable" in lowered:
                kind = "variable"
            elif "repository secret" in lowered:
                kind = "secret"
            else:
                continue
            rows.setdefault(match.group(1), {
                "kind": kind,
                "file": os.path.relpath(path, checkout).replace(os.sep, "/"),
                "line": number})
    return rows


def _plan_branches(plan):
    return [s["branch"] for s in (plan or {}).get("seats") or [] if s.get("branch")]


def _minutes(seconds):
    if not isinstance(seconds, int):
        return "a while"
    if seconds < 90:
        return "%d s" % seconds
    return "%d min" % (seconds // 60)


# ── superseded failed dispatches (issue 86) ─────────────────────────────────
#
# A failed or aborted dispatch that a later round replaced is history, not an
# ask: NEEDS YOU holds only what is still open. A row leaves the list (and
# lands in needs_you_meta.superseded, so nothing is hidden) when, same repo
# and later than the row, one of the four rules below fires. The two guards
# are applied to the later set once, before any rule: a candidate in another
# repo never folds the row, and a live re-dispatch that only got as far as
# dispatch_start never folds it either (no seat exists yet to take its place,
# so NOW has nothing for the row while the re-dispatch is starting).
#
#   1. another dispatch of the same plan file exists today (any outcome: a
#      later failure is itself the open row, the older one is replaced), or
#   2. a dispatch ran a fix round for it: the plan file is the same stem with
#      a fix suffix (x.plan -> x-fix.plan, x-fix2.plan), or the plan header
#      carries fix-round wording ("fix round", "fix wave") and names the row
#      by its stem or its branch as a whole token (never a substring:
#      "feat/track" does not match inside "feat/track-c" or "feat/track+c"),
#      never by a subset of the row's title words (one-letter track tokens
#      keep "Floor v3-B" and "Floor v3-C" apart), or
#   3. a dispatch on one of its branches ended landed, or
#   4. gh says the branch has merged, merged later than the row (optional:
#      when gh cannot answer the rule does not fire and the merged_branch
#      check reads skipped).
#
# "Later" is ended_at for settled dispatches, started_at for live ones (a
# re-dispatch already running replaces the failure it answers).

FIX_ROUND_RE = re.compile(r"\bfix[\s-]*(?:round|wave)\b", re.IGNORECASE)
FIX_SUFFIX_RE = re.compile(r"^(?:fix|critic|rebase|resume)\d*$")


def whole_token(token, text):
    """The token appears in the text whole, bounded by characters that cannot
    be part of a git branch name (letters, digits, dot, slash, dash,
    underscore, plus): "feat/track" never matches inside "feat/track-c" or
    "feat/track+c"."""
    return bool(re.search(r"(?<![\w./+-])" + re.escape(token) + r"(?![\w./+-])", text))


def superseded_dispatch(row, today, live, plan_cache, queue_entries, gh, skip):
    """The later dispatch or merge that supersedes a failed today-row, else None.

    The answer is what the fold prints: {kind, plan, dispatch_id, branch, pr}.
    """
    r_plan = row.get("plan_basename")
    r_stem = r_plan[:-5] if r_plan and r_plan.endswith(".plan") else r_plan
    r_repo = row.get("repo")
    r_end = row.get("ended_at") or ""
    r_start = row.get("started_at") or ""
    r_branches = row.get("branches") or []

    def base_of(d):
        return os.path.basename(str(d.get("plan_basename") or d.get("plan") or ""))

    def same_repo(d):
        return not (r_repo and d.get("repo") and d.get("repo") != r_repo)

    def live_without_seat(d):
        """A re-dispatch that only got as far as dispatch_start: no seat
        exists yet, so NOW has nothing to take the failure's place and the
        row stays open while the re-dispatch is starting."""
        return not d.get("ended_at") and not d.get("seats")

    # Settled dispatches that ended after this one, live ones started after
    # this one started. The row itself never supersedes itself. Nearest first:
    # the fold names the immediate next round, not the last one of the day.
    later = [d for d in today
             if d.get("dispatch_id") != row.get("dispatch_id")
             and (d.get("ended_at") or "") > r_end]
    later += [s for s in live or []
              if s.get("dispatch_id") != row.get("dispatch_id")
              and (s.get("started_at") or "") > r_start]
    later.sort(key=lambda d: d.get("ended_at") or d.get("started_at") or "")
    # The two guards apply to every rule, so they filter the later set once,
    # here, before any of the four loops below ask a question of it.
    later = [d for d in later if same_repo(d) and not live_without_seat(d)]

    def plan_of(d):
        return cached_plan(plan_cache, base_of(d), queue_entries)

    def names_row(d, purpose, d_stem):
        """The candidate names this row by its stem or its branch, never by a
        subset of the row's title words: a row branch appears as a whole token
        in its fix-round header ("feat/track" does not match inside
        "feat/track-c" or "feat/track+c") or among its own branches, or its stem grows out of
        the row's stem. Track letters stay whole in stems and branches ("v3b"
        vs "v3c"), so one track's fix round cannot fold another track's
        failure."""
        if any(b and whole_token(b, purpose) for b in r_branches):
            return True
        if any(b and b in (d.get("branches") or []) for b in r_branches):
            return True
        return bool(r_stem) and d_stem.startswith(r_stem + "-")

    for d in later:
        if r_plan and base_of(d) == r_plan:
            return {"kind": "plan", "plan": r_plan, "dispatch_id": d.get("dispatch_id"),
                    "branch": None, "pr": None}
    for d in later:
        d_base = base_of(d)
        if not d_base or d_base == r_plan:
            continue
        d_stem = d_base[:-5] if d_base.endswith(".plan") else d_base
        purpose = str((plan_of(d) or {}).get("purpose") or "")
        if r_stem and d_stem.startswith(r_stem + "-") \
                and FIX_SUFFIX_RE.match(d_stem[len(r_stem) + 1:]):
            return {"kind": "plan", "plan": d_base, "dispatch_id": d.get("dispatch_id"),
                    "branch": None, "pr": None}
        if FIX_ROUND_RE.search(purpose) and names_row(d, purpose, d_stem):
            return {"kind": "plan", "plan": d_base, "dispatch_id": d.get("dispatch_id"),
                    "branch": None, "pr": None}
    for d in later:
        if d.get("outcome") != "landed":
            continue
        shared = [b for b in r_branches if b in (d.get("branches") or [])]
        if shared:
            return {"kind": "landed", "plan": base_of(d) or None,
                    "dispatch_id": d.get("dispatch_id"), "branch": shared[0], "pr": None}
    if r_branches and r_repo:
        merged = gh.merged_prs(r_repo)
        if merged.get("lookup") != "verified":
            skip("merged_branch", merged.get("reason"))
        else:
            row_at = r_end or r_start
            heads = {p.get("branch"): p for p in merged.get("prs") or [] if p.get("branch")}
            for branch in r_branches:
                pr = heads.get(branch)
                merged_at = str((pr or {}).get("merged_at") or "")
                if pr and row_at and merged_at > row_at:
                    return {"kind": "merge", "plan": None, "dispatch_id": None,
                            "branch": branch, "pr": pr.get("number")}
    return None


def needs_you_view(proj, queue_entries, plan_cache, gh, now, live_summaries=None):
    """needs_you[] and needs_you_meta for a live projection. Never raises past
    a gh failure: every check reports ok or skipped with a reason."""
    entries = []
    checks = {name: {"check": name, "status": "ok", "reason": None, "looked_at": 0}
              for name in NEEDS_YOU_CHECKS}

    def skip(check, reason):
        checks[check]["status"] = "skipped"
        checks[check]["reason"] = reason

    def add(kind, text, source, verified=True, at=None, **extra):
        # The one line goes to the page: every slash token is checked
        # against the worktree here, whatever the check that made it, so an
        # operator path never reaches it. The macOS toast (notify.sh) never
        # reads this line: it is built from fixed phrases and the item's
        # identifiers (repo, PR number, critic stem, round) only.
        entry = {"type": kind, "text": scrub_text(mark_paths(text), 160), "action": NEEDS_YOU_ACTIONS[kind],
                 "source": source, "verified": bool(verified), "at": at,
                 "repo": extra.get("repo"), "branch": extra.get("branch"),
                 "pr": extra.get("pr"), "plan": extra.get("plan")}
        entries.append(entry)
        return entry

    seats = proj.get("seats") or []
    today = proj.get("today") or []
    index = queue_purpose_index(queue_entries)

    # 4: a dispatch that ended failed or aborted today (from the stream). A
    # row a later round replaced leaves the list for needs_you_meta.superseded
    # (issue 86): the strip still counts it (it happened), NEEDS YOU counts
    # only what is still open. The text starts at the plan purpose; the repo
    # is the row's chip, rendered once by the page.
    superseded = []
    for row in today:
        checks["failed_dispatch"]["looked_at"] += 1
        if row.get("outcome") not in ("failed", "aborted"):
            continue
        what = row.get("purpose") or row.get("plan_basename") or row.get("dispatch_id")
        text = "%s %s after %s" % (first_sentence(what, 80),
                                   row["outcome"], _minutes(row.get("duration_s")))
        entry = add("failed_dispatch", text,
                    {"kind": "stream", "dispatch_id": row.get("dispatch_id"),
                     "stream": os.path.basename(str(row.get("source") or "")) or None,
                     "event": "dispatch_end", "ts": row.get("ended_at")},
                    at=row.get("ended_at"), repo=row.get("repo"), plan=row.get("plan_basename"),
                    branch=(row.get("branches") or [None])[0])
        if row.get("branches"):
            checks["merged_branch"]["looked_at"] += 1
        by = superseded_dispatch(row, today, live_summaries, plan_cache, queue_entries, gh, skip)
        if by:
            entry["superseded_by"] = by
            entries.remove(entry)
            superseded.append(entry)

    # 3: a live seat quiet past the threshold (from the stream). A stream
    # whose own age is at or past offline_after_s has no quiet seat: it has
    # stopped, and project() already reads its seats as unknown. The guard
    # here keeps the rule visible where the item is made.
    stream_age = (proj.get("staleness") or {}).get("seconds")
    stream_offline = isinstance(stream_age, int) and stream_age >= OFFLINE_AFTER
    for seat in seats:
        if seat.get("status") != "running":
            continue
        if stream_offline and seat.get("dispatch_id") in (None, proj.get("dispatch_id")):
            continue
        checks["quiet_seat"]["looked_at"] += 1
        if not seat.get("quiet"):
            continue
        last = seat.get("last_heartbeat_ts") or seat.get("started_at")
        text = "%s on %s quiet for %s" % (seat.get("agent") or "seat", seat.get("branch") or "its branch",
                                          _minutes(seat.get("heartbeat_age_s")))
        add("quiet_seat", text,
            {"kind": "stream", "dispatch_id": seat.get("dispatch_id"),
             "event": "seat_heartbeat" if seat.get("last_heartbeat_ts") else "seat_dispatch",
             "task_id": seat.get("task_id"), "ts": last},
            at=last, repo=seat.get("repo"), branch=seat.get("branch"),
            plan=os.path.basename(str(seat.get("plan") or proj.get("plan") or "")) or None)

    # 5 and 6: what a queued plan names, checked against the target checkout.
    queued = [e for e in queue_entries if (e.get("status") or "queued") == "queued"]
    checkouts, prd_cache, contract_cache = {}, {}, {}
    wanted_names = {}   # (repo, NAME) -> (contract row, queue entry, plan basename)
    for entry in queued:
        plan = cached_plan(plan_cache, entry.get("plan"), queue_entries)
        refs = (plan or {}).get("refs") or {}
        repo = entry.get("repo")
        base = os.path.basename(str(entry.get("plan") or ""))
        if repo not in checkouts:
            checkouts[repo] = target_checkout(repo)
        checkout = checkouts[repo]
        if refs.get("s_numbers"):
            checks["prd_proposed"]["looked_at"] += 1
            if checkout is None:
                skip("prd_proposed", "no checkout of %s on this machine" % repo)
            else:
                if repo not in prd_cache:
                    prd_cache[repo] = prd_proposed_rows(checkout)
                for number in refs["s_numbers"]:
                    row = prd_cache[repo].get(number)
                    if not row:
                        continue
                    add("prd_proposed", "S%d awaits sign-off, named by %s" % (number, base),
                        {"kind": "file", "checkout": repo, "file": row["file"], "line": row["line"],
                         "named_by": base},
                        at=entry.get("added_at"), repo=repo, plan=base)
        if refs.get("variables"):
            if checkout is None:
                checks["missing_variable"]["looked_at"] += 1
                skip("missing_variable", "no checkout of %s on this machine" % repo)
            else:
                if repo not in contract_cache:
                    contract_cache[repo] = contract_rows(checkout)
                for name in refs["variables"]:
                    row = contract_cache[repo].get(name)
                    if row and (repo, name) not in wanted_names:
                        wanted_names[(repo, name)] = (row, entry, base)
    for (repo, name), (row, entry, base) in sorted(wanted_names.items()):
        checks["missing_variable"]["looked_at"] += 1
        present = gh.names(repo, row["kind"])
        source = {"kind": "file", "checkout": repo, "file": row["file"], "line": row["line"],
                  "named_by": base, "lookup": present["lookup"], "reason": present["reason"]}
        if present["lookup"] != "verified":
            # No item: "set it" would be a guess. The check row in
            # needs_you_meta.checks carries the skip and its reason.
            skip("missing_variable", present["reason"])
        elif name not in present["names"]:
            add("missing_variable", "%s unset in %s, needed by %s" % (name, repo, base),
                source, at=entry.get("added_at"), repo=repo, plan=base)

    # 1 and 2: critic verdicts on the PRs in play (through gh).
    candidates = {}    # (repo, branch) -> plan basename or None
    for seat in seats:
        if seat.get("branch"):
            candidates.setdefault((seat.get("repo"), seat["branch"]),
                                  os.path.basename(str(seat.get("plan") or proj.get("plan") or "")) or None)
    for row in today:
        for branch in row.get("branches") or []:
            candidates.setdefault((row.get("repo"), branch), row.get("plan_basename"))
    active_plans = []   # (entry, plan) for queued and running plans on disk
    for entry in queue_entries:
        if (entry.get("status") or "queued") not in ("queued", "running"):
            continue
        plan = cached_plan(plan_cache, entry.get("plan"), queue_entries)
        active_plans.append((entry, plan))
        for branch in _plan_branches(plan):
            candidates.setdefault((entry.get("repo"), branch), os.path.basename(str(entry.get("plan"))))

    def fix_wave(repo, branch, pr_number):
        """A fix wave is running or queued for this branch or PR."""
        for seat in seats:
            if seat.get("status") == "running" and seat.get("branch") == branch and seat.get("repo") == repo:
                return True
        for entry, plan in active_plans:
            if entry.get("repo") != repo:
                continue
            if branch in _plan_branches(plan):
                return True
            refs = (plan or {}).get("refs") or {}
            if pr_number and (pr_number in refs.get("prs", []) or pr_number in
                              {int(n) for n in PR_REF_RE.findall(str(entry.get("purpose") or ""))}):
                return True
        return False

    prs = {}   # (repo, number) -> view
    if not candidates:
        skip("critic_block", "no branch in play today")
        skip("ready_to_merge", "no branch in play today")
    for (repo, branch), plan_base in sorted(candidates.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        pr = gh.pr(repo, branch)
        if pr.get("lookup") != "verified":
            skip("critic_block", pr.get("reason"))
            skip("ready_to_merge", pr.get("reason"))
            continue
        if pr.get("state") != "open" or not isinstance(pr.get("number"), int):
            continue
        view = gh.pr_view(repo, pr["number"])
        if view.get("lookup") != "verified":
            skip("critic_block", view.get("reason"))
            skip("ready_to_merge", view.get("reason"))
            continue
        view["_plan"] = plan_base
        prs[(repo, pr["number"])] = view
    # Findings-issue comments, attributed to a PR by the number or branch they name.
    since = fmt_ts(now - timedelta(days=COMMENT_LOOKBACK_DAYS))
    findings = {}
    for entry, plan in active_plans:
        for number in ((plan or {}).get("refs") or {}).get("findings_issues", []):
            findings.setdefault((entry.get("repo"), number), True)
    for seat in seats:
        plan = cached_plan(plan_cache, seat.get("plan") or proj.get("plan"), queue_entries)
        for number in ((plan or {}).get("refs") or {}).get("findings_issues", []):
            findings.setdefault((seat.get("repo"), number), True)
    for row in today:
        plan = cached_plan(plan_cache, row.get("plan_basename"), queue_entries)
        for number in ((plan or {}).get("refs") or {}).get("findings_issues", []):
            findings.setdefault((row.get("repo"), number), True)
    for (repo, number) in sorted(findings, key=lambda k: (str(k[0]), k[1])):
        if not prs:
            break
        answer = gh.issue_comments(repo, number, since)
        if answer.get("lookup") != "verified":
            skip("critic_block", answer.get("reason"))
            skip("ready_to_merge", answer.get("reason"))
            continue
        for rec in answer["comments"]:
            for (pr_repo, pr_number), view in prs.items():
                if pr_repo != repo:
                    continue
                if pr_number in rec["_prs"] or view.get("branch") in rec["_slugs"]:
                    view["comments"].append(dict(rec, issue=number))
    for (repo, number), view in sorted(prs.items(), key=lambda kv: (str(kv[0][0]), kv[0][1])):
        checks["critic_block"]["looked_at"] += 1
        checks["ready_to_merge"]["looked_at"] += 1
        newest = latest_round(view["comments"])
        if not newest:
            continue
        blocks = [r for r in newest if r["verdict"] in BLOCK_VERDICTS]
        if blocks:
            rec = blocks[0]
            if fix_wave(repo, view.get("branch"), number):
                continue
            text = "PR %d round %d blocked by %s (%s)" % (number, rec["round"], rec["stem"].lower(), rec["verdict"])
            add("critic_block", text,
                {"kind": "comment", "repo": repo, "comment_id": rec["id"], "url": rec["url"],
                 "pr": number, "issue": rec.get("issue"), "verdict": rec["verdict"],
                 "round": rec["round"], "stem": rec["stem"]},
                at=rec["at"], repo=repo, branch=view.get("branch"), pr=number, plan=view.get("_plan"))
            continue
        if all(r["verdict"] in SAFE_VERDICTS for r in newest) and view.get("merge_state") == "CLEAN" \
                and not view.get("is_draft"):
            text = "PR %d ready to merge: %s" % (number, view.get("title") or view.get("branch"))
            add("ready_to_merge", text,
                {"kind": "pr", "repo": repo, "pr": number, "url": view.get("url"),
                 "merge_state": view.get("merge_state"),
                 "comments": [public_comment(r) for r in newest]},
                at=max(r["at"] or "" for r in newest) or None,
                repo=repo, branch=view.get("branch"), pr=number, plan=view.get("_plan"))

    entries.sort(key=lambda e: e.get("at") or "", reverse=True)
    superseded.sort(key=lambda e: e.get("at") or "", reverse=True)
    meta = {"count": len(entries),
            "unverified": sum(1 for e in entries if not e["verified"]),
            "checks": [checks[name] for name in NEEDS_YOU_CHECKS],
            "superseded": superseded,
            "comment_lookback_days": COMMENT_LOOKBACK_DAYS,
            "quiet_after_s": QUIET_AFTER}
    return entries, meta


def block_queue(proj, queue_entries, plan_cache):
    """A queued plan that a NEEDS YOU item names shows the reason in place.

    The reason the queue file already carries (scripts/queue.sh block) wins;
    else a PRD row awaiting sign-off, a variable unset, or a PR on one of the
    plan's branches awaiting merge. ``blocked`` is null when nothing names it.
    """
    stored = {os.path.basename(str(e.get("plan") or "")): (e.get("blocked") or "").strip()
              for e in queue_entries}
    items = proj.get("needs_you") or []
    for entry in proj.get("queue") or []:
        base = entry.get("plan_basename")
        entry["blocked"] = None
        entry["blocked_by"] = None
        if stored.get(base):
            entry["blocked"] = scrub_text(stored[base], 160)
            entry["blocked_by"] = {"type": "queue", "source": {"kind": "queue", "field": "blocked"}}
            continue
        plan = cached_plan(plan_cache, entry.get("plan"), queue_entries)
        branches = set(_plan_branches(plan))
        for item in items:
            if item["type"] in ("prd_proposed", "missing_variable") and item.get("plan") == base:
                reason = item["text"]
            elif item["type"] == "ready_to_merge" and item.get("branch") in branches \
                    and item.get("repo") == entry.get("repo"):
                reason = "PR %d awaits merge" % item["pr"]
            else:
                continue
            entry["blocked"] = reason
            entry["blocked_by"] = {"type": item["type"], "source": item["source"]}
            break
    return proj


def plans_on_disk(plan_cache, queue_entries):
    """Every plan under wave-plans/ plus the queue, parsed once: basename -> plan."""
    root = os.path.join(REPO_DIR, "wave-plans")
    out = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".plan") or name in out:
                continue
            if name not in plan_cache:
                plan_cache[name] = parse_plan(os.path.join(dirpath, name))
            if plan_cache[name]:
                out[name] = plan_cache[name]
    for entry in queue_entries:
        base = os.path.basename(str(entry.get("plan") or ""))
        if base and base not in out:
            plan = cached_plan(plan_cache, entry.get("plan"), queue_entries)
            out[base] = plan or {"plan": base, "purpose": entry.get("purpose") or "",
                                 "issue": entry.get("issue"), "waves": 0, "seats": [],
                                 "refs": plan_refs(str(entry.get("purpose") or ""), base)}
        if entry.get("repo") and not (out[base].get("refs") or {}).get("repo"):
            out[base].setdefault("refs", {})["repo"] = entry.get("repo")
    return out


def initiatives_view(proj, queue_entries, plan_cache, gh, now):
    """initiatives[] and initiatives_meta: one row per open milestone with
    activity in the last 30 days, in each repo the queue or the day names.
    Falls back to what the streams and the queue alone can prove."""
    repos = []
    for entry in queue_entries:
        if entry.get("repo") and entry["repo"] not in repos:
            repos.append(entry["repo"])
    for row in list(proj.get("today") or []) + list(proj.get("seats") or []):
        if row.get("repo") and row["repo"] not in repos:
            repos.append(row["repo"])
    plans = plans_on_disk(plan_cache, queue_entries)
    landed_today = {row.get("plan_basename") for row in proj.get("today") or []
                    if row.get("outcome") == "landed"}
    queued = {os.path.basename(str(e.get("plan") or "")) for e in queue_entries
              if (e.get("status") or "queued") == "queued"}
    rows, meta_repos = [], []
    cutoff = fmt_ts(now - timedelta(days=INITIATIVE_ACTIVE_DAYS))

    def plan_repo(base, plan):
        return (plan.get("refs") or {}).get("repo")

    def wave_facts(members, merged_heads):
        planned, landed = [], []
        for base in members:
            plan = plans[base]
            wid = wave_id(plan.get("purpose"), base)
            if not wid:
                continue
            if wid not in planned:
                planned.append(wid)
            if base in landed_today or any(b in merged_heads for b in _plan_branches(plan)):
                if wid not in landed:
                    landed.append(wid)
        key = lambda w: (int(WAVE_ID_RE.match(w).group(1)), w)
        return {"planned": len(planned), "landed": len(landed),
                "planned_ids": sorted(planned, key=key), "landed_ids": sorted(landed, key=key)}

    for repo in repos:
        members_by_repo = [b for b, p in plans.items() if plan_repo(b, p) == repo]
        answer = gh.milestones(repo)
        if answer.get("lookup") != "verified":
            meta_repos.append({"repo": repo, "lookup": "skipped", "reason": answer.get("reason")})
            # Fallback: the track a plan header names, from streams and queue alone.
            tracks = {}
            for base in members_by_repo:
                if base not in landed_today and base not in queued and base not in {
                        os.path.basename(str(s.get("plan") or proj.get("plan") or ""))
                        for s in proj.get("seats") or []}:
                    continue
                name = track_name(plans[base].get("purpose")) or repo
                tracks.setdefault(name, []).append(base)
            for name, members in sorted(tracks.items()):
                waves = wave_facts(members, set())
                rows.append({
                    "repo": repo, "title": name, "number": None, "url": None,
                    "lookup": "skipped", "reason": answer.get("reason"),
                    "epic": None, "epic_title": None, "exit": None, "exit_lookup": "skipped",
                    "waves": waves,
                    "open_issues": None, "last_landed": None, "updated_at": None,
                    "plans": sorted(members),
                    "source": {"milestone": None, "plans": "wave-plans and queue",
                               "landed": "streams of the day"}})
            continue
        meta_repos.append({"repo": repo, "lookup": "verified", "reason": None})
        merged = gh.merged_prs(repo)
        merged_rows = merged.get("prs") or [] if merged.get("lookup") == "verified" else []
        merged_heads = {p.get("branch") for p in merged_rows if p.get("branch")}
        for milestone in answer["milestones"]:
            if (milestone.get("updated_at") or "") < cutoff:
                continue
            issues = gh.milestone_issues(repo, milestone["title"])
            numbers, epic, epic_title = set(), None, None
            if issues.get("lookup") == "verified":
                for issue in issues["issues"]:
                    numbers.add(issue["number"])
                    if epic is None and re.search(r"\bepic\b", issue.get("title") or "", re.IGNORECASE):
                        epic, epic_title = issue["number"], issue.get("title")
            title_lower = milestone["title"].lower()
            members = []
            for base in members_by_repo:
                plan = plans[base]
                refs = plan.get("refs") or {}
                if (plan.get("issue") in numbers or (refs.get("epic") and refs["epic"] in numbers)
                        or (epic and refs.get("epic") == epic)
                        or title_lower in str(plan.get("purpose") or "").lower()):
                    members.append(base)
            member_heads = {b for base in members for b in _plan_branches(plans[base])}
            last = None
            for pr in merged_rows:
                names = {int(n) for n in HASH_REF_RE.findall(pr.get("title") or "")}
                if (pr.get("branch") in member_heads or pr.get("milestone") == milestone["title"]
                        or (numbers and names & numbers)):
                    if last is None or (pr.get("merged_at") or "") > (last.get("merged_at") or ""):
                        last = pr
            exit_text, exit_lookup = None, "skipped"
            if epic:
                found = gh.issue_exit(repo, epic)
                exit_lookup = found.get("lookup")
                exit_text = found.get("exit")
            rows.append({
                "repo": repo, "title": milestone["title"], "number": milestone.get("number"),
                "url": milestone.get("url"), "lookup": "verified", "reason": None,
                "epic": epic, "epic_title": epic_title, "exit": exit_text, "exit_lookup": exit_lookup,
                "waves": wave_facts(members, merged_heads),
                "open_issues": milestone.get("open_issues"),
                "last_landed": last, "updated_at": milestone.get("updated_at"),
                "plans": sorted(members),
                "source": {"milestone": milestone.get("url"),
                           "issues": issues.get("lookup"), "issues_reason": issues.get("reason"),
                           "merged_prs": merged.get("lookup"), "merged_reason": merged.get("reason"),
                           "plans": "wave-plans and queue",
                           "landed": "streams of the day and merged PRs"}})
    rows.sort(key=lambda r: (r.get("updated_at") or "", r["title"]), reverse=True)
    meta = {"count": len(rows), "repos": meta_repos, "active_days": INITIATIVE_ACTIVE_DAYS,
            "plans_seen": len(plans)}
    return rows, meta


def attach_v3(proj, queue_entries, plan_cache, gh, now, live_summaries=None):
    """NEEDS YOU, INITIATIVES and the blocked reasons on queue entries."""
    proj["needs_you"], proj["needs_you_meta"] = needs_you_view(
        proj, queue_entries, plan_cache, gh, now, live_summaries)
    block_queue(proj, queue_entries, plan_cache)
    proj["initiatives"], proj["initiatives_meta"] = initiatives_view(proj, queue_entries, plan_cache, gh, now)
    proj["gh_enrichment"] = gh.meta()
    return proj


def read_ledger(path):
    """The W1 fleet ledger rollup (logs/ledger.json), optional like gh.

    Returns (data, meta); meta says ok or skipped with the reason, so the
    Floor can say cost unknown instead of painting zero.
    """
    try:
        with open(path, errors="replace") as fh:
            data = json.load(fh)
    except OSError:
        return None, {"lookup": "skipped", "reason": "no ledger.json (run make ledger)"}
    except ValueError:
        return None, {"lookup": "skipped", "reason": "ledger.json is not valid JSON"}
    if not isinstance(data, dict) or not str(data.get("schema") or "").startswith("fleet-ledger-rollup/"):
        return None, {"lookup": "skipped", "reason": "ledger.json is not a fleet ledger rollup"}
    return data, {"lookup": "ok", "reason": None}


def attach_ledger(proj, ledger_file=None):
    """One ledger line per initiative (fleet optimization W1): cost, elapsed
    and work share from logs/ledger.json, joined on the plan basenames the
    initiative row already names. Never fatal: a missing or unreadable
    ledger leaves every row with ledger=None and initiatives_meta.ledger
    says why. The manual orchestrator readings in the ledger are not shown
    here: they are their own rollup lines and nothing reads them to cap,
    warn or throttle."""
    path = DEFAULT_LEDGER_FILE if ledger_file is None else ledger_file
    if proj.get("view") == "replay":
        meta_out = dict(proj.get("initiatives_meta") or {})
        meta_out["ledger"] = {"lookup": "skipped", "reason": "replay carries no ledger"}
        proj["initiatives_meta"] = meta_out
        return
    data, meta = read_ledger(path)
    by_plan = {}
    if data:
        for entry in data.get("initiatives") or []:
            for plan in entry.get("plans") or []:
                by_plan.setdefault(plan, []).append(entry)
    for row in proj.get("initiatives") or []:
        matched = []
        for plan in row.get("plans") or []:
            for entry in by_plan.get(plan, []):
                if entry not in matched:
                    matched.append(entry)
        if not matched:
            row["ledger"] = None
            continue
        cost = sum(e.get("cost_usd") or 0 for e in matched)
        unknown = sum(e.get("cost_unknown_seats") or 0 for e in matched)
        active = sum(e.get("active_s") or 0 for e in matched)
        elapsed = sum(e.get("elapsed_s") or 0 for e in matched)
        row["ledger"] = {
            "cost_usd": round(cost, 2),
            "cost_known": unknown == 0,
            "cost_unknown_seats": unknown,
            "active_s": active,
            "elapsed_s": elapsed,
            "work_share": round(active / elapsed, 4) if elapsed else None,
            "source": "logs/ledger.json",
        }
    meta_out = dict(proj.get("initiatives_meta") or {})
    meta_out["ledger"] = meta
    proj["initiatives_meta"] = meta_out


# ── the plain sentence (one per live seat) + the top line ────────────────────
#
# Issue 69: the Floor must read like sentences, not like a schema. The page
# should never have to join three objects to say
#
#   "devops is testing (make), wave 2 of 3 of 'the queue and the day view',
#    14 min in, last sign of life 20 s ago"
#
# so every fact that sentence needs is projected in ONE place per live seat,
# and the four numbers of the header in ONE object. Nothing here is new truth:
# it is the stream, the queue and the plan file, already folded above.

def seat_now(seat, proj, purpose_index):
    """Everything the page needs for one sentence about one live seat.

    Purpose comes from the queue entry the orchestrator declared, else the
    plan header, and says which of the two it was. A missing fact is None, so
    the page drops that clause instead of printing a guess.
    """
    activity = seat.get("activity") or {}
    plan = os.path.basename(str(seat.get("plan") or proj.get("plan") or ""))
    declared = (purpose_index.get(plan) or {}).get("purpose")
    purpose, source = None, "none"
    if declared:
        purpose, source = declared, "queue"
    elif seat.get("plan_purpose"):
        purpose, source = seat["plan_purpose"], "plan"
    return {
        "role": seat.get("agent"),
        "phase": activity.get("phase"),
        "program": activity.get("program"),
        "purpose": first_sentence(purpose) if purpose else None,
        "purpose_source": source,
        "wave": seat.get("wave"),
        "wave_total": seat.get("wave_total"),
        "elapsed_s": seat.get("elapsed_s"),
        "heartbeat_age_s": seat.get("heartbeat_age_s"),
    }


def attach_now(proj, queue_entries):
    """Give every RUNNING seat its sentence, and the page its top line.

    A seat that is not running gets ``now: null``: the sentence is present
    tense, and a settled or unknown seat has no present.

    ``last_event_ts`` is a timestamp, never a precomputed age: the page
    computes the age live from it, so the header ticks with the rest of the
    chrome and cannot disagree with the state note when the watcher is gone.
    """
    purpose_index = queue_purpose_index(queue_entries)
    running = 0
    for seat in proj.get("seats") or []:
        if seat.get("status") != "running":
            seat["now"] = None
            continue
        running += 1
        seat["now"] = seat_now(seat, proj, purpose_index)
    proj["summary"] = {
        "running": running,
        "queued": (proj.get("queue_meta") or {}).get("queued") or 0,
        "landed_today": len(proj.get("today") or []),
        "landed_yesterday": len(proj.get("yesterday") or []),
        "needs_you": sum(1 for e in proj.get("needs_you") or [] if e.get("verified")),
        "last_event_ts": proj.get("last_event_ts"),
    }
    return proj


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
            "last_heartbeat_ts": None,
            "heartbeat_age_s": None,
            "activity": None,
            "quiet": False,
            # One sentence worth of facts, filled for RUNNING seats only.
            "now": None,
            "plan_purpose": None,
            "task": None,
            "wave_total": None,
            # Issue 72: repo first-class, the issue the plan names, the seat's
            # one-line task, the PR for its branch. Filled by attach_context.
            "repo": None,
            "issue": None,
            "task_line": None,
            "pr": None,
        }
        state[task_id] = seat
    return seat


def project(events, now=None, source=None, malformed=0, replay=False):
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
            # session = orchestrator/autopilot bridge (same Floor lanes as wave)
            if ev.get("mode") in ("wave", "conductor", "session"):
                out["mode"] = "wave" if ev["mode"] == "session" else ev["mode"]
                if ev.get("mode") == "session":
                    out["session"] = True
        elif kind == "dispatch_plan":
            if isinstance(ev.get("waves"), int):
                out["wave"]["total"] = ev["waves"]
            if isinstance(ev.get("seats"), int):
                out["seats_planned"] = ev["seats"]
        elif kind == "wave_start":
            wave_current = ev.get("wave")
            waves_seen.add(wave_current)
            if ev.get("mode") in ("wave", "conductor", "session"):
                out["mode"] = "wave" if ev["mode"] == "session" else ev["mode"]
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
        elif kind == "seat_heartbeat":
            # Heartbeats prove a seat is alive between dispatch and exit. They
            # never CREATE a seat: no fabricated lanes, only liveness on one the
            # stream already reported.
            task_id = str(ev.get("task_id"))
            if task_id in seats:
                seats[task_id]["last_heartbeat_ts"] = ts
                if isinstance(ev.get("elapsed_s"), int):
                    seats[task_id]["heartbeat_elapsed_s"] = ev["elapsed_s"]
        elif kind == PROGRESS_EVENT:
            # What the seat is doing right now. Like heartbeats, progress never
            # CREATES a seat, and it carries no prompt, argument or command
            # line: a tool name, one repo-relative path, four counts, a phase.
            task_id = str(ev.get("task_id"))
            if task_id in seats:
                seats[task_id]["activity"] = seat_activity(ev, ts)
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

    # ── staleness (before the seats: an offline stream has no running seat) ──
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
                        "stale_after_s": STALE_AFTER, "offline_after_s": OFFLINE_AFTER,
                        "quiet_after_s": QUIET_AFTER}

    # ── seats + pipeline counts ──
    seat_list = [seats[t] for t in order]
    for seat in seat_list:
        seat["repo"] = out["repo"]
        seat["pipeline"] = PIPELINE.get(seat["status"], "queued")
        if seat["status"] == "running" and (out["status"] != "running"
                                            or (state == "offline" and not replay)):
            # Dispatcher is gone but the seat never reported, or the whole
            # stream stopped updating past OFFLINE_AFTER with no close-out:
            # say unknown, not "running". Honesty beats a spinner that never
            # stops, and a crashed wave is not a quiet seat. A replay is the
            # past and has no "now", so only the close-out rule applies there.
            seat["status"] = "unknown"
            seat["pipeline"] = "blocked"
        if seat["status"] == "running" and seat["started_at"]:
            started = parse_ts(seat["started_at"])
            if started:
                seat["elapsed_s"] = max(0, int((now - started).total_seconds()))
        if seat["status"] == "running":
            # Quiet is measured from the last sign of life: a heartbeat when the
            # dispatcher sends them, else the seat_dispatch itself.
            last_sign = parse_ts(seat.get("last_heartbeat_ts")) or parse_ts(seat.get("started_at"))
            if last_sign:
                age = max(0, int((now - last_sign).total_seconds()))
                seat["heartbeat_age_s"] = age
                seat["quiet"] = age >= QUIET_AFTER
            else:
                seat["heartbeat_age_s"] = None
                seat["quiet"] = False
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

    # Hang honesty: a still-running dispatch with no new events for QUIET_AFTER
    # surfaces first-class on waiting_on so the Floor does not look "fine".
    if (
        out["status"] == "running"
        and isinstance(age, int)
        and age >= QUIET_AFTER
        and state in ("stale", "offline", "live")
    ):
        # Prefer stale/offline; still flag quiet when just past QUIET_AFTER but
        # under STALE_AFTER so the operator sees "maybe stuck" early.
        quiet_label = (
            "no new events for %ds — stream may be stuck (check agent log growth)"
            % age
        )
        if not any(w.get("kind") == "quiet_stream" for w in waiting):
            # Append (do not steal W[0]): human gates and active seats stay first.
            waiting.append({
                "kind": "quiet_stream",
                "label": quiet_label,
                "since": out["last_event_ts"],
                "seconds": age,
            })
            out["waiting_on"] = waiting

    out["events_seen"] = len(events)
    out["recent_events"] = events[-RECENT_EVENTS:]
    return out


def attach_queue_and_day(proj, events_dir, queue_file, now, gh=None):
    """Fold declared intent (queue) and the local day into a projection.

    Both are independent of which stream is followed: an idle desk with armed
    plans still shows them, and a desk following one run still lists every
    dispatch that ended today. Replay projections get neither, because a
    historical scrub must not carry today's queue.
    """
    entries, warnings = read_queue(queue_file)
    proj["queue"] = queue_view(entries)
    proj["queue_meta"] = queue_meta(entries, queue_file)
    proj["queue_meta"]["hold"] = read_queue_hold(queue_file)
    stops, stops_meta, stop_warnings = read_stops(DEFAULT_STOPS_FILE)
    proj["stops"] = stops
    proj["stops_meta"] = stops_meta
    warnings = list(warnings) + stop_warnings
    landed, live, meta = today_view(events_dir, now, entries)
    proj["today"] = landed
    proj["today_meta"] = meta
    # Floor v3-C: the day before, read the same way, marked yesterday.
    proj["yesterday"], _, proj["yesterday_meta"] = day_view(events_dir, now, entries, 1)
    for warning in warnings:
        proj.setdefault("warnings", []).append(warning)
    merge_live_seats(proj, events_dir, now, live)
    plan_cache = {}
    attach_plan_context(proj, entries, plan_cache)
    gh = gh or GhEnricher(enabled=False)
    attach_context(proj, entries, live, plan_cache, gh)
    # Floor v3: NEEDS YOU, the blocked reasons on the queue, INITIATIVES.
    attach_v3(proj, entries, plan_cache, gh, now, live)
    # Fleet optimization W1: the ledger line on each initiative row.
    attach_ledger(proj)
    # Last: the sentence needs the queue, the plan context and every live seat.
    attach_now(proj, entries)
    return proj


def gh_enabled_default():
    """gh enrichment is on unless FLEET_DESK_NO_GH=1 (same switch as the Almanac)."""
    return os.environ.get("FLEET_DESK_NO_GH") != "1"


def build(events_dir, dispatch_id=None, now=None, as_of_seq=None, replay=False,
          queue_file=None, gh_enabled=None):
    """Resolve the current stream and project it (never raises on missing data).

    Phase C: pass ``as_of_seq`` and/or ``replay=True`` to get a historical
    projection. Replay always sets ``view=replay`` so the Floor cannot paint a
    green LIVE LED for the past.
    """
    now = now or utcnow()
    queue_file = DEFAULT_QUEUE_FILE if queue_file is None else queue_file
    gh = GhEnricher(enabled=gh_enabled_default() if gh_enabled is None else gh_enabled)
    path, resolved_id = resolve_stream(events_dir, dispatch_id)
    if not path:
        proj = empty_projection(
            now, reason="no event stream in %s — run a dispatch (FLEET_EVENTS=1)" % rel(events_dir))
        return attach_queue_and_day(proj, events_dir, queue_file, now, gh)
    events, malformed = read_events(path)
    total = len(events)
    if as_of_seq is not None:
        events = truncate_events(events, as_of_seq)
    # Replay when asked, or when the caller is scrubbing (as_of_seq set).
    force_replay = replay or as_of_seq is not None
    proj = project(events, now=now, source=rel(path), malformed=malformed, replay=force_replay)
    if not proj.get("dispatch_id"):
        proj["dispatch_id"] = resolved_id
    if force_replay:
        # Use the cut seq (or full length when replaying the whole settled run).
        cut = as_of_seq if as_of_seq is not None else total
        mark_replay(proj, cut, total)
        return attach_replay_context(proj, queue_file, gh)
    return attach_queue_and_day(proj, events_dir, queue_file, now, gh)


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


NOTIFY_SCRIPT = os.path.join(REPO_DIR, "scripts", "notify.sh")
NOTIFY_TIMEOUT_S = 20


def push_needs_you(out_path):
    """The push (Floor v3-C): hand the written projection to notify.sh.

    Off by default: nothing runs unless ``FLEET_NOTIFY_NEEDS_YOU_MIN`` is set.
    notify.sh owns the rule (one macOS notification per NEEDS YOU item that
    has had no action for that many minutes, never twice); this only calls
    it. Never fatal: a missing or failing script is one stderr line.
    """
    if not os.environ.get("FLEET_NOTIFY_NEEDS_YOU_MIN"):
        return False
    try:
        subprocess.run([NOTIFY_SCRIPT, "needs-you", out_path], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=NOTIFY_TIMEOUT_S)
        return True
    except (OSError, subprocess.SubprocessError) as exc:
        print("desk-live: needs-you push failed: %s" % exc, file=sys.stderr)
        return False


# ── server ──────────────────────────────────────────────────────────────────

def serve(args, out_path):
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    site_dir = args.site_dir
    state = {"json": "{}", "version": 0}
    stop = threading.Event()

    def refresh():
        proj = build(args.events_dir, args.dispatch_id, queue_file=args.queue_file,
                     gh_enabled=False if args.no_gh else None)
        payload = json.dumps(proj)
        if payload != state["json"]:
            state["json"] = payload
            state["version"] += 1
        write_projection(proj, out_path)
        push_needs_you(out_path)
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
    if getattr(args, "open_browser", False):
        try:
            import webbrowser
            webbrowser.open(url)
            print("  browser   opened")
        except Exception as exc:
            print("  browser   open failed: %s" % exc, file=sys.stderr)
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
    parser.add_argument("--queue-file", default=DEFAULT_QUEUE_FILE,
                        help="declared queue to fold in (default: logs/fleet-queue.json)")
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
    parser.add_argument("--open", dest="open_browser", action="store_true",
                        help="open the Ops Floor URL in the default browser (follow live)")
    parser.add_argument("--no-gh", action="store_true",
                        help="skip the optional gh enrichment (issue milestone, PR per branch); "
                             "also FLEET_DESK_NO_GH=1. gh failures never fail the projection.")
    args = parser.parse_args(argv)

    out_path = args.out or os.path.join(args.site_dir, "data", "live.json")

    if args.list_runs:
        print(json.dumps({"schema": "fleet-runs/1", "runs": list_runs(args.events_dir)}, indent=2))
        return 0

    if args.once or args.watch:
        proj = build(args.events_dir, args.dispatch_id,
                     as_of_seq=args.as_of_seq, replay=args.replay,
                     queue_file=args.queue_file,
                     gh_enabled=False if args.no_gh else None)
        write_projection(proj, out_path)
        push_needs_you(out_path)
        if args.print_json:
            print(json.dumps(proj, indent=2))
        if args.once:
            gh_meta = proj.get("gh_enrichment") or {}
            print("live.json written: %s (status=%s, seats=%d, repos=%d, view=%s, "
                  "staleness=%s, needs_you=%d, initiatives=%d, yesterday=%d, gh=%s calls=%s)"
                  % (out_path, proj["status"], len(proj["seats"]),
                     len(proj.get("repos") or []), proj.get("view"),
                     proj["staleness"]["state"], len(proj.get("needs_you") or []),
                     len(proj.get("initiatives") or []), len(proj.get("yesterday") or []),
                     gh_meta.get("status"), gh_meta.get("calls")),
                  file=sys.stderr)
            return 0
        print("desk-live: watching %s → %s (Ctrl-C to stop)" % (args.events_dir, out_path))
        try:
            while True:
                time.sleep(args.interval)
                write_projection(
                    build(args.events_dir, args.dispatch_id,
                          as_of_seq=args.as_of_seq, replay=args.replay,
                          queue_file=args.queue_file,
                          gh_enabled=False if args.no_gh else None),
                    out_path)
                push_needs_you(out_path)
        except KeyboardInterrupt:
            print("\ndesk-live: stopped")
        return 0

    return serve(args, out_path)


if __name__ == "__main__":
    sys.exit(main())
