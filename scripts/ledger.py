#!/usr/bin/env python3
"""The fleet ledger (fleet optimization W1, docs/proposals/fleet-optimization.md).

One record per seat run in logs/fleet-ledger.jsonl, built from the event
streams (logs/fleet-events/*.jsonl), the dispatch run logs
(logs/dispatch-runs/*.log) and the plan headers (wave-plans/). Cost and
tokens come only from the first-party result line; kimi and grok seats, and
first-party seats that died mid-stream, are marked cost unknown and never
counted as zero. Manual orchestrator readings (make ledger-orchestrator)
live in the same file marked source "manual", survive rebuilds, and are
shown as their own rollup lines; nothing reads them to cap, warn or throttle.

Standard library only. Usage:

  ledger.py build   [--logs-dir logs] [--wave-plans-dir wave-plans] [--no-gh]
  ledger.py rollup  [--logs-dir logs]
  ledger.py orchestrator --date YYYY-MM-DD --usd N [--note text] [--logs-dir logs]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA = "fleet-ledger/1"
RESULT_MARKER = '"type":"result"'
ISSUE_RE = re.compile(r"\bissue #?(\d{1,7})\b", re.IGNORECASE)
TIER_RE = re.compile(r"^#*\s*TIER:\s*([A-Za-z0-9_-]+)", re.IGNORECASE | re.MULTILINE)
FIX_ROUND_RE = re.compile(r"^#*\s*FIX-ROUND:\s*(\d+)\s+of\s+", re.IGNORECASE | re.MULTILINE)
FIX_ROUND_ANY_RE = re.compile(r"^#*\s*FIX-ROUND:", re.IGNORECASE | re.MULTILINE)
ROUND_RE = re.compile(r"\bROUND\s+(\d{1,3})\b", re.IGNORECASE)
FIX_NAME_RE = re.compile(r"-fix(\d*)\.plan$")
R_NAME_RE = re.compile(r"-r(\d+)\.plan$")
REPO_URL_RE = re.compile(r"github\.com[:/]([^/:\s]+)/([^/\s]+?)(?:\.git)?$")
SECTION_RE = re.compile(r"^Starting (\w+) launcher for agent (\S+) \(model: ([^)]+)\)")
LOGGING_RE = re.compile(r"^Logging to: (\S+)")
DETACHED_RE = re.compile(r"^Detached dispatch (\S+): pid \d+, .*started (\S+)")
REPO_LINE_RE = re.compile(r"^Repo: (\S+)")
SEAT_DONE_RE = re.compile(r"^\s*(✓|✗)\s+(\S+) (?:completed|failed) in (\d+)s")


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def fmt_ts(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def read_jsonl(path):
    rows = []
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return rows


# ── sources ──────────────────────────────────────────────────────────────────


def load_streams(events_dir):
    """Events grouped by dispatch id, sorted by ts then seq."""
    dispatches = {}
    try:
        names = sorted(os.listdir(events_dir))
    except OSError:
        return dispatches
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        for ev in read_jsonl(os.path.join(events_dir, name)):
            did = ev.get("dispatch_id")
            if not did:
                continue
            dispatches.setdefault(did, []).append(ev)
    for events in dispatches.values():
        events.sort(key=lambda e: (e.get("ts") or "", e.get("seq") or 0))
    return dispatches


def parse_run_log(path):
    """One dispatch run log: header facts and per-seat sections.

    A section opens at 'Starting <vendor> launcher for agent <role>' and
    closes at the next section, the next seat's execution block or the end of
    the wave summary. Result lines inside a section belong to that seat.
    """
    info = {"dispatch_id": None, "started": None, "repo_url": None, "sections": []}
    try:
        fh = open(path, errors="replace")
    except OSError:
        return info
    current = None
    with fh:
        for line in fh:
            line = line.rstrip("\n")
            m = DETACHED_RE.match(line)
            if m:
                info["dispatch_id"] = m.group(1)
                info["started"] = m.group(2)
                continue
            m = REPO_LINE_RE.match(line)
            if m and info["repo_url"] is None:
                info["repo_url"] = m.group(1)
                continue
            m = SECTION_RE.match(line)
            if m:
                current = {"provider": m.group(1), "role": m.group(2),
                           "model": m.group(3), "log_path": None, "results": []}
                info["sections"].append(current)
                continue
            if line.startswith("=== Agent completed") or line.startswith("=== Remote Agent Execution"):
                current = None
                continue
            if current is None:
                continue
            m = LOGGING_RE.match(line)
            if m:
                current["log_path"] = m.group(1)
                continue
            if RESULT_MARKER in line:
                # Only a first-party seat emits stream-json; a kimi or grok
                # seat that quotes a result line is narrating, not recording.
                if (current["provider"] or "").lower() != "claude":
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if ev.get("type") == "result":
                    current["results"].append(ev)
    return info


def read_pid_file(path):
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return {}
    out = {}
    if len(lines) > 1:
        out["repo"] = lines[1].strip()
    if len(lines) > 2:
        out["plan"] = lines[2].strip()
    if len(lines) > 3:
        out["started"] = lines[3].strip()
    return out


def find_plan(wave_plans_dir, basename, pid_plan):
    """Repo-relative path of the plan file, or None."""
    candidates = []
    if pid_plan and os.path.isfile(pid_plan):
        candidates.append(pid_plan)
    if pid_plan and os.path.isfile(os.path.join(os.path.dirname(wave_plans_dir) or ".", pid_plan)):
        candidates.append(pid_plan)
    for root, _dirs, files in os.walk(wave_plans_dir):
        if basename in files:
            candidates.append(os.path.join(root, basename))
    return candidates[0] if candidates else None


def plan_facts(path):
    """Issue, tier and round from the plan header and name (docs/ledger.md)."""
    facts = {"issue": None, "tier": None, "round": None, "round_source": None,
             "initiative": None}
    if not path:
        facts["round"] = 1
        facts["round_source"] = "default"
        return facts
    basename = os.path.basename(path)
    parent = os.path.basename(os.path.dirname(path.rstrip("/")))
    facts["initiative"] = parent or None
    try:
        text = open(path, errors="replace").read()
    except OSError:
        text = ""
    header = "\n".join(l for l in text.splitlines() if l.lstrip().startswith("#"))
    m = ISSUE_RE.search(header)
    if m:
        facts["issue"] = int(m.group(1))
    m = TIER_RE.search(header)
    if m:
        facts["tier"] = m.group(1)
    m = FIX_ROUND_RE.search(header)
    if m:
        facts["round"] = int(m.group(1)) + 1
        facts["round_source"] = "fix-round header"
    if facts["round"] is None and FIX_ROUND_ANY_RE.search(header):
        facts["round"] = 2
        facts["round_source"] = "fix-round header"
    if facts["round"] is None:
        m = ROUND_RE.search(header)
        if m:
            facts["round"] = int(m.group(1))
            facts["round_source"] = "plan header"
    if facts["round"] is None:
        m = FIX_NAME_RE.search(basename)
        if m:
            facts["round"] = 2 + (int(m.group(1)) - 1 if m.group(1) else 0)
            facts["round_source"] = "plan name"
    if facts["round"] is None:
        m = R_NAME_RE.search(basename)
        if m:
            facts["round"] = int(m.group(1))
            facts["round_source"] = "plan name"
    if facts["round"] is None:
        facts["round"] = 1
        facts["round_source"] = "default"
    return facts


# ── gh (optional, cached, never fatal) ───────────────────────────────────────


def repo_full_name(slug, repo_url):
    if repo_url:
        m = REPO_URL_RE.search(repo_url)
        if m:
            return "%s/%s" % (m.group(1), m.group(2))
    return None


def gh_pr_for_branch(full_name, branch, cache):
    key = "%s|%s" % (full_name, branch)
    if key in cache:
        return cache[key]
    answer = {"pr": None, "pr_url": None, "lookup": "skipped", "reason": "gh lookup failed"}
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "-R", full_name, "--head", branch,
             "--state", "all", "--json", "number,url", "--limit", "1"],
            capture_output=True, text=True, timeout=20)
        if out.returncode == 0:
            rows = json.loads(out.stdout or "[]")
            if rows:
                answer = {"pr": rows[0].get("number"), "pr_url": rows[0].get("url"),
                          "lookup": "verified", "reason": None}
            else:
                answer = {"pr": None, "pr_url": None, "lookup": "verified",
                          "reason": "no PR on this branch"}
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        answer["reason"] = str(exc)[:80]
    cache[key] = answer
    return answer


# ── build ────────────────────────────────────────────────────────────────────


def result_facts(result):
    usage = result.get("usage") or {}
    models = sorted((result.get("modelUsage") or {}).keys())
    return {
        "cost_usd": result.get("total_cost_usd"),
        "session_id": result.get("session_id"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "cache_read_tokens": usage.get("cache_read_input_tokens"),
        "cache_write_tokens": usage.get("cache_creation_input_tokens"),
        "num_turns": result.get("num_turns"),
        "api_time_s": round((result.get("duration_api_ms") or 0) / 1000.0, 1) or None,
        "models": models,
        "subtype": result.get("subtype"),
        "is_error": bool(result.get("is_error")),
    }


def log_results(path):
    """All result lines in one log file."""
    results = []
    try:
        fh = open(path, errors="replace")
    except OSError:
        return results
    with fh:
        for line in fh:
            if RESULT_MARKER not in line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") == "result":
                results.append(ev)
    return results


def branch_slug(repo, branch):
    if not repo or not branch:
        return None
    slug = re.sub(r"[^A-Za-z0-9]+", "-", branch).strip("-")
    return "%s-%s-" % (repo, slug) if slug else None


def seat_log_result(logs_dir, seat_logs_dir, log_path, repo, branch, duration_s):
    """Fallback: read the seat's result line from wherever it was written.

    Candidates are the log the dispatch named for the seat and every seat log
    filed under the seat's repo and branch (the collected copies in logs/ and
    the seat log directory the launchers write to). A dispatch can name the
    wrong file (for example the later critic seat's log, stamped onto every
    task), so the named file is only one candidate. One result line across
    all candidates is used directly; with several, the line whose duration_ms
    matches the seat's recorded duration wins. Anything ambiguous stays cost
    unknown: the ledger never guesses.
    """
    candidates = []
    if log_path:
        candidates.append(os.path.join(logs_dir, os.path.basename(log_path)))
        candidates.append(log_path)
    prefix = branch_slug(repo, branch)
    for directory in (logs_dir, seat_logs_dir):
        if not prefix or not directory:
            continue
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            if name.startswith(prefix) and name.endswith(".log"):
                candidates.append(os.path.join(directory, name))
    results = []
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        results.extend(log_results(path))
    if len(results) == 1:
        return results[0]
    if duration_s is None:
        return None
    tolerance = max(15.0, duration_s * 0.05)
    matches = [ev for ev in results
               if isinstance(ev.get("duration_ms"), (int, float))
               and abs(ev["duration_ms"] / 1000.0 - duration_s) <= tolerance]
    return matches[0] if len(matches) == 1 else None


def build_records(logs_dir, wave_plans_dir, use_gh, seat_logs_dir=None):
    events_dir = os.path.join(logs_dir, "fleet-events")
    runs_dir = os.path.join(logs_dir, "dispatch-runs")
    streams = load_streams(events_dir)

    run_logs = {}
    pids = {}
    try:
        names = sorted(os.listdir(runs_dir))
    except OSError:
        names = []
    for name in names:
        path = os.path.join(runs_dir, name)
        if name.endswith(".log"):
            run_logs[name[:-4]] = parse_run_log(path)
        elif name.endswith(".pid"):
            pids[name[:-4]] = read_pid_file(path)

    dispatch_ids = sorted(set(streams) | set(run_logs))
    pr_cache_path = os.path.join(logs_dir, "ledger-pr-cache.json")
    try:
        pr_cache = json.load(open(pr_cache_path))
    except (OSError, ValueError):
        pr_cache = {}

    records = []
    for did in dispatch_ids:
        events = streams.get(did, [])
        run = run_logs.get(did) or {}
        pid = pids.get(did) or {}
        by_event = {e.get("event"): e for e in events}
        start_ev = by_event.get("dispatch_start") or {}
        end_ev = by_event.get("dispatch_end") or {}
        repo = start_ev.get("repo") or pid.get("repo")
        if not repo:
            parts = did.split("-")
            repo = parts[2] if len(parts) > 2 else None
        plan_basename = start_ev.get("plan")
        pid_plan = pid.get("plan")
        if not plan_basename and pid_plan:
            plan_basename = os.path.basename(pid_plan)
        dispatch_start = parse_ts(start_ev.get("ts")) or parse_ts(run.get("started")) \
            or parse_ts(pid.get("started"))
        wave_ends = {}
        for e in events:
            if e.get("event") == "wave_end" and isinstance(e.get("wave"), int):
                wave_ends[e["wave"]] = parse_ts(e.get("ts"))

        plan_path = find_plan(wave_plans_dir, plan_basename, pid_plan) if plan_basename or pid_plan else None
        facts = plan_facts(plan_path)
        full_name = repo_full_name(repo, run.get("repo_url")) if repo else None

        seat_dispatches = [e for e in events if e.get("event") == "seat_dispatch"]
        seat_exits = {}
        for e in events:
            if e.get("event") == "seat_exit":
                seat_exits[(str(e.get("task_id")), e.get("attempt") or 1)] = e
        last_seat_ts = {}
        seat_log_names = {}
        for e in events:
            tid = e.get("task_id")
            if tid is not None and e.get("ts"):
                last_seat_ts[str(tid)] = e["ts"]
            if e.get("event") == "seat_log" and e.get("log"):
                seat_log_names[str(tid)] = e["log"]

        sections = run.get("sections") or []
        sections_by_role = {}
        for sec in sections:
            sections_by_role.setdefault(sec["role"], []).append(sec)
        role_seen = {}

        for sd in seat_dispatches:
            tid = str(sd.get("task_id"))
            attempt = sd.get("attempt") or 1
            role = sd.get("agent")
            provider = sd.get("provider")
            section = None
            idx = role_seen.get(role, 0)
            role_seen[role] = idx + 1
            pool = sections_by_role.get(role) or []
            if idx < len(pool):
                section = pool[idx]

            start = parse_ts(sd.get("ts"))
            exit_ev = seat_exits.get((tid, attempt))
            end = parse_ts(exit_ev.get("ts")) if exit_ev else None
            if end is None:
                end = parse_ts(last_seat_ts.get(tid)) or parse_ts(end_ev.get("ts"))
            active_s = exit_ev.get("duration_s") if exit_ev else None
            if active_s is None and start and end:
                active_s = max(0, int((end - start).total_seconds()))
            outcome = exit_ev.get("status") if exit_ev else "unknown"

            anchor = dispatch_start
            wave = sd.get("wave")
            if isinstance(wave, int) and wave > 1 and (wave - 1) in wave_ends:
                anchor = wave_ends[wave - 1] or anchor
            waiting_s = max(0, int((start - anchor).total_seconds())) if start and anchor else None

            record = {
                "schema": SCHEMA,
                "source": "logs",
                "kind": "seat",
                "dispatch_id": did,
                "task_id": tid,
                "attempt": attempt,
                "repository": repo,
                "initiative": facts["initiative"],
                "issue": facts["issue"],
                "plan": plan_basename,
                "branch": sd.get("branch"),
                "pr": None, "pr_url": None, "pr_lookup": "skipped",
                "round": facts["round"], "round_source": facts["round_source"],
                "role": role,
                "provider": provider or (section or {}).get("provider"),
                "model": sd.get("model") or (section or {}).get("model"),
                "tier": facts["tier"] or "unknown",
                "wave": wave,
                "start": fmt_ts(start), "end": fmt_ts(end),
                "active_s": active_s,
                "waiting_s": waiting_s,
                "outcome": outcome,
                "cost_usd": None, "cost_known": False,
                "input_tokens": None, "output_tokens": None,
                "cache_read_tokens": None, "cache_write_tokens": None,
                "num_turns": None, "api_time_s": None, "models": [],
                "session_id": None,
            }

            result = None
            if section and section["results"]:
                result = section["results"][-1]
            elif provider == "claude" or (section or {}).get("provider") == "claude":
                log_path = (section or {}).get("log_path") or seat_log_names.get(tid)
                result = seat_log_result(logs_dir, seat_logs_dir, log_path,
                                         repo, sd.get("branch"), active_s)
            if result is not None:
                record.update(result_facts(result))
                record["cost_known"] = record["cost_usd"] is not None

            if use_gh and full_name and record["branch"]:
                answer = gh_pr_for_branch(full_name, record["branch"], pr_cache)
                record["pr"] = answer["pr"]
                record["pr_url"] = answer["pr_url"]
                record["pr_lookup"] = answer["lookup"]
            records.append(record)

    records.sort(key=lambda r: (r.get("start") or "", r["dispatch_id"],
                                r["task_id"], r["attempt"]))
    seen_sessions = {}
    for r in records:
        sid = r.get("session_id")
        if not sid:
            continue
        if sid in seen_sessions:
            r["cost_usd"] = None
            r["cost_known"] = False
            r["cost_note"] = "cost recorded on seat %s" % seen_sessions[sid]
        else:
            seen_sessions[sid] = "%s/%s" % (r["dispatch_id"], r["task_id"])
    try:
        with open(pr_cache_path, "w") as fh:
            json.dump(pr_cache, fh, indent=1, sort_keys=True)
    except OSError:
        pass
    return records


def load_manual(logs_dir):
    path = os.path.join(logs_dir, "fleet-ledger.jsonl")
    return [r for r in read_jsonl(path) if r.get("source") == "manual"]


def write_ledger(logs_dir, records):
    path = os.path.join(logs_dir, "fleet-ledger.jsonl")
    with open(path, "w") as fh:
        for r in records:
            fh.write(json.dumps(r, sort_keys=True) + "\n")
    return path


# ── rollups ──────────────────────────────────────────────────────────────────


def bucket():
    return {"seats": 0, "cost_usd": 0.0, "cost_unknown_seats": 0,
            "active_s": 0, "waiting_s": 0, "seat_elapsed_s": 0,
            "start": None, "end": None, "failed": 0}


def fold(b, r):
    b["seats"] += 1
    if r.get("cost_known") and isinstance(r.get("cost_usd"), (int, float)):
        b["cost_usd"] += r["cost_usd"]
    else:
        b["cost_unknown_seats"] += 1
    active = r.get("active_s") or 0
    b["active_s"] += active
    b["waiting_s"] += r.get("waiting_s") or 0
    s, e = r.get("start"), r.get("end")
    start, end = parse_ts(s), parse_ts(e)
    seat_elapsed = int((end - start).total_seconds()) if start and end else active
    b["seat_elapsed_s"] += max(seat_elapsed, active)
    if r.get("outcome") not in ("success", None):
        b["failed"] += 1
    if s and (b["start"] is None or s < b["start"]):
        b["start"] = s
    if e and (b["end"] is None or e > b["end"]):
        b["end"] = e
    return b


def elapsed_s(b):
    s, e = parse_ts(b["start"]), parse_ts(b["end"])
    return max(0, int((e - s).total_seconds())) if s and e else 0


def work_share(b):
    """Active time over seat time, seat by seat. Parallel seats add seat
    hours, not share, so this can never pass 100%."""
    if not b["seat_elapsed_s"]:
        return None
    return min(1.0, b["active_s"] / b["seat_elapsed_s"])


def money(b):
    if b["cost_unknown_seats"] >= b["seats"] and b["seats"]:
        return "cost unknown"
    if b["cost_unknown_seats"]:
        return "$%.2f + %d unknown" % (b["cost_usd"], b["cost_unknown_seats"])
    return "$%.2f" % b["cost_usd"]


def dur(seconds):
    seconds = int(seconds)
    if seconds >= 3600:
        return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)
    return "%dm%02ds" % (seconds // 60, seconds % 60)


def rollups(records):
    seats = [r for r in records if r.get("kind") == "seat"]
    manual = [r for r in records if r.get("source") == "manual"]
    per_round, per_pr, per_init, per_day = {}, {}, {}, {}
    for r in seats:
        key_r = (r.get("initiative") or "unknown", r.get("issue"), r.get("round"))
        fold(per_round.setdefault(key_r, bucket()), r)
        key_i = (r.get("initiative") or "unknown", r.get("issue"))
        fold(per_init.setdefault(key_i, bucket()), r)
        per_init[key_i].setdefault("plans", set()).add(r.get("plan") or "unknown")
        day = (r.get("start") or "????-??-??")[:10]
        fold(per_day.setdefault(day, bucket()), r)
        if r.get("pr") and r.get("pr_lookup") == "verified":
            key_p = (r.get("repository") or "unknown", r["pr"])
            fold(per_pr.setdefault(key_p, bucket()), r)
    return {"seats": seats, "manual": manual, "per_round": per_round,
            "per_pr": per_pr, "per_initiative": per_init, "per_day": per_day}


def print_rollup(roll, out):
    w = lambda line="": out.write(line[:100] + "\n")
    per_round, per_pr = roll["per_round"], roll["per_pr"]
    per_init, per_day, manual = roll["per_initiative"], roll["per_day"], roll["manual"]

    w("FLEET LEDGER  (one record per seat run; cost unknown is never zero)")
    w("=" * 72)
    w()
    w("PER INITIATIVE")
    w("%-33s %5s %22s %9s %9s %9s %7s" %
      ("initiative", "seats", "cost", "active", "seat", "wall", "work"))
    for (name, issue), b in sorted(per_init.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0)):
        label = name + (" #%d" % issue if issue else "")
        share = work_share(b)
        w("%-33.33s %5d %22.22s %9s %9s %9s %7s" %
          (label, b["seats"], money(b), dur(b["active_s"]), dur(b["seat_elapsed_s"]),
           dur(elapsed_s(b)), ("%d%%" % (100 * share)) if share is not None else "n/a"))
    w()
    w("PER ROUND")
    w("%-30s %5s %5s %22s %9s %9s" % ("initiative", "round", "seats", "cost", "active", "waiting"))
    for (name, issue, rnd), b in sorted(per_round.items(),
                                        key=lambda kv: (kv[0][0], kv[0][1] or 0, kv[0][2])):
        label = name + (" #%d" % issue if issue else "")
        w("%-30.30s %5s %5d %22.22s %9s %9s" %
          (label, rnd, b["seats"], money(b), dur(b["active_s"]), dur(b["waiting_s"])))
    w()
    w("PER PR (verified gh lookups only)")
    w("%-33s %5s %22s %9s %9s %9s %7s" %
      ("pr", "seats", "cost", "active", "seat", "wall", "work"))
    for (repo, pr), b in sorted(per_pr.items()):
        share = work_share(b)
        w("%-33.33s %5d %22.22s %9s %9s %9s %7s" %
          ("%s PR %d" % (repo, pr), b["seats"], money(b), dur(b["active_s"]),
           dur(b["seat_elapsed_s"]), dur(elapsed_s(b)),
           ("%d%%" % (100 * share)) if share is not None else "n/a"))
    if not per_pr:
        w("  (no verified PR lookups; skipped lookups are marked unverified in the ledger)")
    w()
    w("PER DAY (UTC)")
    w("%-12s %5s %22s %9s %9s %9s %7s" %
      ("day", "seats", "cost", "active", "seat", "wall", "work"))
    for day, b in sorted(per_day.items()):
        share = work_share(b)
        w("%-12s %5d %22.22s %9s %9s %9s %7s" %
          (day, b["seats"], money(b), dur(b["active_s"]), dur(b["seat_elapsed_s"]),
           dur(elapsed_s(b)), ("%d%%" % (100 * share)) if share is not None else "n/a"))
        for r in manual:
            if (r.get("date") or "") == day:
                note = ("  " + r["note"]) if r.get("note") else ""
                w("  orchestrator session (manual): $%.2f%s" % (r.get("usd") or 0, note))
    undated = [r for r in manual if (r.get("date") or "") not in per_day]
    for r in undated:
        note = ("  " + r["note"]) if r.get("note") else ""
        w("%-12s orchestrator session (manual): $%.2f%s" % (r.get("date") or "?", r.get("usd") or 0, note))
    w()
    total = bucket()
    for r in roll["seats"]:
        fold(total, r)
    w("TOTAL seats %d, cost %s, active %s" %
      (total["seats"], money(total), dur(total["active_s"])))
    w("Work share is active time over seat time, seat by seat: never over 100%.")
    w("Seat hours next to wall hours show how parallel the seats ran.")
    if manual:
        w("Manual orchestrator readings are their own lines above; nothing sums,")
        w("caps, warns or throttles on them.")


def write_ledger_json(logs_dir, roll):
    initiatives = []
    for (name, issue), b in sorted(per_init_items(roll),
                                   key=lambda kv: (kv[0][0], kv[0][1] or 0)):
        share = work_share(b)
        initiatives.append({
            "initiative": name,
            "issue": issue,
            "plans": sorted(b.get("plans") or []),
            "seats": b["seats"],
            "cost_usd": round(b["cost_usd"], 4),
            "cost_known": b["cost_unknown_seats"] == 0,
            "cost_unknown_seats": b["cost_unknown_seats"],
            "active_s": b["active_s"],
            "seat_elapsed_s": b["seat_elapsed_s"],
            "elapsed_s": elapsed_s(b),
            "work_share": round(share, 4) if share is not None else None,
        })
    days = []
    for day, b in sorted(roll["per_day"].items()):
        share = work_share(b)
        days.append({"date": day, "seats": b["seats"],
                     "cost_usd": round(b["cost_usd"], 4),
                     "cost_known": b["cost_unknown_seats"] == 0,
                     "cost_unknown_seats": b["cost_unknown_seats"],
                     "active_s": b["active_s"],
                     "seat_elapsed_s": b["seat_elapsed_s"],
                     "elapsed_s": elapsed_s(b),
                     "work_share": round(share, 4) if share is not None else None})
    payload = {
        "schema": "fleet-ledger-rollup/1",
        "generated_at": fmt_ts(datetime.now(timezone.utc)),
        "initiatives": initiatives,
        "days": days,
        "orchestrator_manual": [
            {"date": r.get("date"), "usd": r.get("usd"), "note": r.get("note"),
             "source": "manual"}
            for r in roll["manual"]],
        "note": "Manual orchestrator readings are recorded, never used to cap, warn or throttle.",
    }
    path = os.path.join(logs_dir, "ledger.json")
    with open(path, "w") as fh:
        json.dump(payload, fh, indent=1, sort_keys=False)
        fh.write("\n")
    return path


def per_init_items(roll):
    return roll["per_initiative"].items()


def cmd_build(args):
    records = build_records(args.logs_dir, args.wave_plans_dir, use_gh=not args.no_gh,
                            seat_logs_dir=args.seat_logs_dir)
    records = records + load_manual(args.logs_dir)
    path = write_ledger(args.logs_dir, records)
    roll = rollups(records)
    json_path = write_ledger_json(args.logs_dir, roll)
    print_rollup(roll, sys.stdout)
    sys.stderr.write("ledger: %s (%d seat records, %d manual)\nledger.json: %s\n" %
                     (path, len(roll["seats"]), len(roll["manual"]), json_path))
    return 0


def cmd_rollup(args):
    records = read_jsonl(os.path.join(args.logs_dir, "fleet-ledger.jsonl"))
    roll = rollups(records)
    write_ledger_json(args.logs_dir, roll)
    print_rollup(roll, sys.stdout)
    return 0


def cmd_orchestrator(args):
    if not args.date or not re.match(r"^\d{4}-\d{2}-\d{2}$", args.date):
        sys.stderr.write("ledger-orchestrator: DATE must be YYYY-MM-DD\n")
        return 2
    try:
        usd = float(args.usd)
    except (TypeError, ValueError):
        sys.stderr.write("ledger-orchestrator: USD must be a number\n")
        return 2
    record = {"schema": SCHEMA, "source": "manual", "kind": "orchestrator_reading",
              "date": args.date, "usd": usd, "note": args.note or None,
              "recorded_at": fmt_ts(datetime.now(timezone.utc))}
    path = os.path.join(args.logs_dir, "fleet-ledger.jsonl")
    with open(path, "a") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")
    sys.stderr.write("ledger: manual orchestrator reading appended to %s\n" % path)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="ledger.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("build", "rebuild the ledger from logs (idempotent)"),
                            ("rollup", "print rollups from the existing ledger"),
                            ("orchestrator", "append a manual orchestrator reading")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--logs-dir", default="logs")
        p.add_argument("--wave-plans-dir", default="wave-plans")
        p.add_argument("--seat-logs-dir", default=os.path.expanduser("~/dev/agent-logs"),
                       help="directory the launchers write seat logs to (cost fallback)")
        p.add_argument("--no-gh", action="store_true",
                       help="skip the gh PR lookup (marked unverified)")
        p.add_argument("--date", default=None)
        p.add_argument("--usd", default=None)
        p.add_argument("--note", default=None)
    args = parser.parse_args(argv)
    if args.command == "build":
        return cmd_build(args)
    if args.command == "rollup":
        return cmd_rollup(args)
    return cmd_orchestrator(args)


if __name__ == "__main__":
    sys.exit(main())
