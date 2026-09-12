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
import re
import sys
import threading
import time
from datetime import datetime, timezone

SCHEMA = "live/1"
EVENT_SCHEMA_PREFIX = "fleet-events/"
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_EVENTS_DIR = os.path.join(REPO_DIR, "logs", "fleet-events")
DEFAULT_QUEUE_FILE = os.environ.get(
    "FLEET_QUEUE_FILE", os.path.join(REPO_DIR, "logs", "fleet-queue.json"))
DEFAULT_SITE_DIR = os.path.join(REPO_DIR, "site", "experience")
DEFAULT_PORT = 8777
DEFAULT_INTERVAL = 2.0
STALE_AFTER = 120     # seconds without an event → STALE chrome
OFFLINE_AFTER = 900   # seconds without an event → OFFLINE chrome
QUIET_AFTER = 90      # running stream with no new events → waiting_on quiet_stream
RECENT_EVENTS = 50    # tail kept in the projection (already redaction-safe)
QUEUE_SCHEMA = "fleet-queue/1"
DAY_SCAN_WINDOW_S = 48 * 3600   # mtime prefilter when scanning the day streams

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
                       "total": 0, "queued": 0, "running": 0, "settled": 0},
        # Day view: one entry per dispatch that ENDED on this local calendar day.
        "today": [],
        "today_meta": {"date": None, "streams_read": 0, "live": [], "ended": 0},
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
    }


def queue_purpose_index(entries):
    """plan basename -> {purpose, repo, plan} so the day view can name a run."""
    index = {}
    for entry in entries:
        plan = str(entry.get("plan") or "")
        base = os.path.basename(plan)
        if base and base not in index:
            index[base] = {"plan": plan,
                           "purpose": entry.get("purpose") or None,
                           "repo": entry.get("repo") or None}
    return index


# ── day view (every stream of the local calendar day) ───────────────────────

_DAY_CACHE = {}   # path -> (mtime, size, summary); settled streams parse once


def local_date(dt_utc):
    """Local calendar date of a naive-UTC timestamp (the operator's day)."""
    if dt_utc is None:
        return None
    return dt_utc.replace(tzinfo=timezone.utc).astimezone().date()


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
        "branches": [],
    }
    seat_ids = set()
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
                seat_ids.add(str(ev["task_id"]))
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


def today_view(events_dir, now, entries):
    """Every dispatch that ENDED on this local calendar day, plus the live ones.

    Reads every stream file of the day, not only the newest, so concurrent
    dispatches all appear. Purpose and plan path come from the queue when the
    basename matches; the stream only ever carries a basename.
    """
    today = local_date(now)
    index = queue_purpose_index(entries)
    landed, live = [], []
    summaries = day_streams(events_dir, now)
    for summary in summaries:
        ended = parse_ts(summary.get("ended_at"))
        started = parse_ts(summary.get("started_at"))
        known = index.get(os.path.basename(summary.get("plan") or "")) or {}
        if ended is not None and local_date(ended) == today:
            landed.append({
                "dispatch_id": summary["dispatch_id"],
                "source": summary["source"],
                "plan": known.get("plan") or summary.get("plan"),
                "plan_basename": os.path.basename(summary.get("plan") or ""),
                "repo": summary.get("repo") or known.get("repo"),
                "purpose": known.get("purpose"),
                "purpose_source": "queue" if known.get("purpose") else "none",
                "status": summary.get("status"),
                "end_status": summary.get("end_status"),
                "duration_s": summary.get("duration_s"),
                "started_at": summary.get("started_at"),
                "ended_at": summary.get("ended_at"),
                "seats": summary.get("seats"),
                "succeeded": summary.get("succeeded"),
                "failed": summary.get("failed"),
                "branches": summary.get("branches") or [],
            })
        elif ended is None and started is not None and local_date(started) == today:
            live.append(summary)
    landed.sort(key=lambda r: r.get("ended_at") or "", reverse=True)
    live.sort(key=lambda r: r.get("started_at") or "")
    meta = {
        "date": today.isoformat(),
        "streams_read": len(summaries),
        "live": [s["dispatch_id"] for s in live],
        "ended": len(landed),
    }
    return landed, live, meta


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


def first_sentence(value, limit=TASK_MAX):
    """First sentence of a task line, cut at ``limit``. Never the whole body."""
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value or ""))
    text = re.sub(r"\s+", " ", text).strip()
    match = re.match(r"^(.{10,}?[.!?])(?:\s|$)", text)
    if match:
        text = match.group(1)
    return scrub_text(text, limit)


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


def parse_plan(path):
    """Fold a plan file into {purpose, waves, seats[]}. Mirrors dispatch.sh.

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

    purpose = ""
    lines = []
    for line in raw:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            if not purpose:
                body = stripped.lstrip("#").strip()
                if body:
                    purpose = scrub_text(body)
            continue
        lines.append(stripped)
    if not lines:
        return {"plan": rel_safe(path), "purpose": purpose, "waves": 0, "seats": []}

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
        seats.append({
            "index": str(index),
            "wave": wave,
            "agent": agent,
            "branch": branch,
            "task": first_sentence(desc),
        })
    return {"plan": rel_safe(path), "purpose": purpose,
            "waves": len(waves) or 1, "seats": seats}


def attach_plan_context(proj, queue_entries, plan_cache=None):
    """Give every seat the purpose of its plan and its one-line task.

    Joined by branch first (the stream and the plan agree on it), then by seat
    index, then by agent. A seat the plan cannot explain keeps its stream facts
    and says nothing more: no guessed task ever reaches the page.
    """
    cache = {} if plan_cache is None else plan_cache

    def plan_for(name):
        base = os.path.basename(str(name or ""))
        if base not in cache:
            cache[base] = parse_plan(resolve_plan_path(base, queue_entries))
        return cache[base]

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
        match = None
        if seat.get("branch"):
            match = next((s for s in plan["seats"] if s["branch"] == seat["branch"]), None)
        if match is None:
            match = next((s for s in plan["seats"] if s["index"] == str(seat.get("task_id"))), None)
        if match is None and seat.get("agent"):
            match = next((s for s in plan["seats"] if s["agent"] == seat["agent"]), None)
        seat["plan_purpose"] = plan["purpose"] or None
        seat["wave_total"] = plan["waves"]
        if match:
            seat["task"] = match["task"] or None
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
            "quiet": False,
            "plan_purpose": None,
            "task": None,
            "wave_total": None,
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
                        "stale_after_s": STALE_AFTER, "offline_after_s": OFFLINE_AFTER,
                        "quiet_after_s": QUIET_AFTER}

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


def attach_queue_and_day(proj, events_dir, queue_file, now):
    """Fold declared intent (queue) and the local day into a projection.

    Both are independent of which stream is followed: an idle desk with armed
    plans still shows them, and a desk following one run still lists every
    dispatch that ended today. Replay projections get neither, because a
    historical scrub must not carry today's queue.
    """
    entries, warnings = read_queue(queue_file)
    proj["queue"] = queue_view(entries)
    proj["queue_meta"] = queue_meta(entries, queue_file)
    landed, live, meta = today_view(events_dir, now, entries)
    proj["today"] = landed
    proj["today_meta"] = meta
    for warning in warnings:
        proj.setdefault("warnings", []).append(warning)
    merge_live_seats(proj, events_dir, now, live)
    attach_plan_context(proj, entries)
    return proj


def build(events_dir, dispatch_id=None, now=None, as_of_seq=None, replay=False,
          queue_file=None):
    """Resolve the current stream and project it (never raises on missing data).

    Phase C: pass ``as_of_seq`` and/or ``replay=True`` to get a historical
    projection. Replay always sets ``view=replay`` so the Floor cannot paint a
    green LIVE LED for the past.
    """
    now = now or utcnow()
    queue_file = DEFAULT_QUEUE_FILE if queue_file is None else queue_file
    path, resolved_id = resolve_stream(events_dir, dispatch_id)
    if not path:
        proj = empty_projection(
            now, reason="no event stream in %s — run a dispatch (FLEET_EVENTS=1)" % rel(events_dir))
        return attach_queue_and_day(proj, events_dir, queue_file, now)
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
    return attach_queue_and_day(proj, events_dir, queue_file, now)


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
        proj = build(args.events_dir, args.dispatch_id, queue_file=args.queue_file)
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
    args = parser.parse_args(argv)

    out_path = args.out or os.path.join(args.site_dir, "data", "live.json")

    if args.list_runs:
        print(json.dumps({"schema": "fleet-runs/1", "runs": list_runs(args.events_dir)}, indent=2))
        return 0

    if args.once or args.watch:
        proj = build(args.events_dir, args.dispatch_id,
                     as_of_seq=args.as_of_seq, replay=args.replay,
                     queue_file=args.queue_file)
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
                          as_of_seq=args.as_of_seq, replay=args.replay,
                          queue_file=args.queue_file),
                    out_path)
        except KeyboardInterrupt:
            print("\ndesk-live: stopped")
        return 0

    return serve(args, out_path)


if __name__ == "__main__":
    sys.exit(main())
