#!/usr/bin/env python3
"""The orchestrator loop behind scripts/queue-runner.sh.

The runner (bash) owns the tick: the pause switch, the tick lock, who is busy,
and the one start per tick. This module owns the judgment the tick needs and
the bookkeeping around it, in four subcommands the runner calls in order:

  settle      look at every detached dispatch that has ended since the last
              tick and act on its critic verdicts: one automatic fix round on
              BLOCK-FIX, a landing through scripts/land.sh when every critic
              said SAFE-TO-MERGE or APPROVE-MERGE and the PR is green and
              clean, a stop for everything else. Also clears stops whose PR
              has since merged or closed.
  guard       read free memory and swap; say once per change of state whether
              starts are held, and write that into the queue (hold) and the
              stops file so the Floor shows why nothing starts.
  candidates  the queued, unblocked plans in declared order, minus those whose
              AFTER header names a plan that has not landed yet (their reason
              is written into the queue entry, and cleared again by this same
              command once the named plan lands).

Verdict parsing is imported from scripts/desk_live.py (first_line_verdict,
critic_record, latest_round): one parser for the Floor and the runner. The
same module's summarize_stream decides what "landed" means for a dispatch.

Output protocol (one line each, tab separated), read by the runner:
  note<TAB>text     goes to the runner log and stdout
  say<TAB>text      stdout in verbose mode only
  guard<TAB>active|clear
  cand<TAB>repo<TAB>plan

Files (all under logs/, per machine, gitignored except the queue):
  logs/dispatch-runs/<id>.pid      what dispatch.sh --detach wrote
  logs/dispatch-runs/<id>.loop     this module's mark that <id> was handled
  logs/dispatch-runs/queue-runner-guard.state   last guard state
  logs/fleet-stops.jsonl           one line per stop, one per clearance
  logs/fleet-queue.json            hold and waiting reasons (queue.sh writes)

Stdlib only. The one network dependency is gh, read-mostly: the two writes it
ever does are `gh pr ready` before a landing and the merge inside land.sh.
--dry-run makes every subcommand read-only: nothing marked, nothing queued,
nothing written, nothing landed.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)
import desk_live  # noqa: E402  (the one verdict parser)

GH_TIMEOUT_S = 30
LAND_TIMEOUT_S = 3600
STOPS_SCHEMA = "fleet-stops/1"
GUARD_KEY = "memory-guard"
LANDING_VERDICTS = frozenset(("SAFE-TO-MERGE", "APPROVE-MERGE"))
ESCALATION_RE = re.compile(r"\b(BLOCK-ESCALATE|BLOCK-CLOSE)\b")
AFTER_RE = re.compile(r"^#\s*AFTER:\s*(\S+)", re.IGNORECASE)
FIX_ROUND_RE = re.compile(r"^#\s*FIX-ROUND:\s*(\d+)\s+of\s+(\S+)", re.IGNORECASE)
DISPATCH_RE = re.compile(r"^#\s*DISPATCH:\s*(.*)$", re.IGNORECASE)
MAX_STOP_CHECKS_PER_TICK = 10

# One action per stop kind: the words the Floor's NEEDS YOU row ends with.
STOP_ACTIONS = {
    "guard": "free memory or wait; the runner resumes by itself",
    "second_block": "open the comment; the runner fired its one fix round",
    "escalate": "decide: open the comment",
    "close": "close the PR or say why not",
    "unparsed": "ask the critic for a verdict from the vocabulary",
    "critic_silent": "ask the critic: no verdict posted",
    "red_checks": "open the checks",
    "not_clean": "make the PR mergeable (rebase or resolve), then unblock",
    "merge_refused": "merge by hand; land.sh refused",
    "no_pr": "open the PR or check the producer's log",
    "pr_closed": "reopen the PR or drop the plan",
    "no_producer": "write the fix plan by hand",
}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(level, text):
    # Tabs separate the fields of a result line; every other control char goes.
    text = re.sub(r"[\x00-\x08\x0a-\x1f\x7f]", " ", str(text))
    sys.stdout.write("%s\t%s\n" % (level, text))
    sys.stdout.flush()


def note(text):
    emit("note", text)


def say(text):
    emit("say", text)


def is_critic(agent):
    agent = str(agent or "")
    return agent.endswith("-critic") or agent == "security-reviewer"


def norm_plan(value):
    value = str(value or "").strip()
    if not value:
        return ""
    if os.path.isabs(value):
        try:
            rel = os.path.relpath(value, REPO_DIR)
        except ValueError:
            rel = os.path.basename(value)
        value = rel if not rel.startswith("..") else os.path.basename(value)
    return os.path.normpath(value).replace(os.sep, "/")


def repo_slug(url):
    """GitHub owner/name from a clone url, else None."""
    text = str(url or "").strip()
    if not text:
        return None
    text = re.sub(r"\.git$", "", text)
    match = re.search(r"[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$", text)
    return match.group(1) if match else None


def repo_name(url):
    return os.path.basename(re.sub(r"\.git$", "", str(url or "").rstrip("/")))


def run(cmd, timeout=GH_TIMEOUT_S, env=None):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


# ── plan header ──────────────────────────────────────────────────────────────

def plan_header(path):
    """(after, fix_round, dispatch_line, purpose) from a plan's comment lines."""
    after = fix_round = dispatch = None
    purpose = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped.startswith("#"):
                    continue
                m = AFTER_RE.match(stripped)
                if m and after is None:
                    after = m.group(1)
                m = FIX_ROUND_RE.match(stripped)
                if m and fix_round is None:
                    fix_round = (int(m.group(1)), m.group(2))
                m = DISPATCH_RE.match(stripped)
                if m and dispatch is None:
                    dispatch = m.group(1).strip()
                body = stripped.lstrip("#").strip()
                if not purpose and body and not desk_live.is_machine_header(body):
                    purpose = desk_live.scrub_text(body)
    except OSError:
        pass
    return after, fix_round, dispatch, purpose


def dispatch_parts(dispatch_line):
    """(repo_url, flags after the plan) from a '# DISPATCH:' line, else (None, [])."""
    words = str(dispatch_line or "").split()
    for i, word in enumerate(words):
        if word.endswith("dispatch.sh"):
            rest = words[i + 1:]
            if len(rest) >= 2:
                return rest[0], rest[2:]
            return (rest[0] if rest else None), []
    return None, []


# ── streams: what ran, how it ended ───────────────────────────────────────────

def stream_summaries(events_dir):
    out = []
    try:
        names = sorted(n for n in os.listdir(events_dir) if n.endswith(".jsonl"))
    except OSError:
        return out
    for name in names:
        summary = desk_live.summarize_stream(os.path.join(events_dir, name))
        if summary:
            out.append(summary)
    return out


def plan_landed(plan, events_dir):
    """(landed, reason) for the plan an AFTER header names.

    Landed means some dispatch of that plan (matched by basename, which is what
    the stream records) ended with outcome ``landed``: close-out completed and
    every seat's last exit success. The reason is one sentence for the queue.
    """
    base = os.path.basename(str(plan or ""))
    if not base:
        return False, "AFTER names no plan"
    runs = [s for s in stream_summaries(events_dir)
            if os.path.basename(str(s.get("plan") or "")) == base]
    if any(s.get("outcome") == "landed" for s in runs):
        return True, ""
    if not runs:
        return False, "after %s: not run yet" % base
    runs.sort(key=lambda s: s.get("started_at") or "")
    last = runs[-1]
    if last.get("ended_at") is None:
        return False, "after %s: still running (%s)" % (base, last.get("dispatch_id"))
    return False, "after %s: its last run %s (%s); fix and run it again" % (
        base, last.get("outcome") or last.get("end_status") or "ended", last.get("dispatch_id"))


def read_pid_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = [line.rstrip("\n") for line in fh]
    except OSError:
        return None
    lines += [""] * (5 - len(lines))
    return {"pid": lines[0].strip(), "repo": lines[1].strip(), "plan": lines[2].strip(),
            "started": lines[3].strip(), "url": lines[4].strip()}


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def stream_seats(path):
    """task_id -> {agent, branch} from seat_dispatch events."""
    seats = {}
    events, _malformed = desk_live.read_events(path)
    for ev in events:
        if ev.get("event") == "seat_dispatch" and ev.get("task_id") is not None:
            seats[str(ev["task_id"])] = {"agent": ev.get("agent"), "branch": ev.get("branch")}
    return seats


# ── stops file ────────────────────────────────────────────────────────────────

def append_stop(stops_file, record, dry_run):
    record = dict(record)
    record.setdefault("schema", STOPS_SCHEMA)
    record.setdefault("ts", now_iso())
    if dry_run:
        return
    try:
        os.makedirs(os.path.dirname(stops_file) or ".", exist_ok=True)
        with open(stops_file, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError as exc:
        say("cannot write %s: %s" % (stops_file, exc))


def open_stop(stops_file, key, kind, dry_run, **fields):
    """One stop: a line in the stops file, a line in the log. Never a merge."""
    record = {"key": key, "state": "open", "kind": kind,
              "action": STOP_ACTIONS.get(kind, "look")}
    for name, value in fields.items():
        if value is None:
            continue
        if name == "plan":
            value = os.path.basename(str(value))
        elif isinstance(value, str):
            value = desk_live.scrub_text(value)
        record[name] = value
    append_stop(stops_file, record, dry_run)
    where = ""
    if record.get("pr"):
        where = " PR #%s" % record["pr"]
    note("%sstop (%s)%s: %s. Action: %s" % (
        "would " if dry_run else "", kind, where,
        record.get("sentence") or "", record["action"]))


def clear_stop(stops_file, key, why, dry_run, **fields):
    record = {"key": key, "state": "cleared", "reason": desk_live.scrub_text(why)}
    record.update({k: v for k, v in fields.items() if v is not None})
    append_stop(stops_file, record, dry_run)
    note("%sstop cleared (%s): %s" % ("would mark " if dry_run else "", key, why))


# ── gh ───────────────────────────────────────────────────────────────────────

class Gh(object):
    """gh calls for one tick: JSON in, dict out, every failure a reason."""

    def __init__(self):
        self.calls = 0

    def json(self, args, what):
        self.calls += 1
        rc, out, err = run(["gh"] + args)
        if rc != 0:
            return None, "%s failed (exit %s): %s" % (
                what, rc, desk_live.scrub_text(err or out, 160))
        try:
            data = json.loads(out or "")
        except ValueError:
            return None, "%s returned no JSON" % what
        return data, None

    def pr_for_branch(self, slug, branch):
        """The PR for a branch: open first, else the newest merged or closed."""
        data, why = self.json(
            ["pr", "list", "-R", slug, "--head", branch, "--state", "all", "--limit", "10",
             "--json", "number,state,isDraft,mergeStateStatus,url,headRefOid,"
                       "statusCheckRollup,comments,reviews,createdAt"],
            "gh pr list %s --head %s" % (slug, branch))
        if data is None:
            return None, why
        if not isinstance(data, list):
            return None, "gh pr list returned an unexpected payload"
        prs = [p for p in data if isinstance(p, dict)]
        for state in ("OPEN", "MERGED", "CLOSED"):
            hits = [p for p in prs if str(p.get("state") or "").upper() == state]
            if hits:
                hits.sort(key=lambda p: str(p.get("createdAt") or ""), reverse=True)
                return hits[0], None
        return None, "no PR for branch %s" % branch

    def pr_state(self, slug, number):
        data, why = self.json(
            ["pr", "view", str(number), "-R", slug, "--json", "state,isDraft,mergeStateStatus"],
            "gh pr view %s#%s" % (slug, number))
        if data is None:
            return None, why
        return data, None

    def pr_ready(self, slug, number):
        self.calls += 1
        rc, out, err = run(["gh", "pr", "ready", str(number), "-R", slug])
        if rc != 0:
            return "gh pr ready failed (exit %s): %s" % (rc, desk_live.scrub_text(err or out, 160))
        return None


def checks_state(rollup):
    """(state, sentence) for a PR's statusCheckRollup.

    green   every run completed with success, skipped or neutral
    red     a run failed, was cancelled, timed out or needs action
    pending a run is still queued or in progress
    none    nothing has run on this head; not green (land.sh lesson 8)
    """
    if not isinstance(rollup, list) or not rollup:
        return "none", "no check has run on the head commit"
    red, pending = [], []
    for item in rollup:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or item.get("context") or "check"
        kind = item.get("__typename") or ("StatusContext" if "context" in item else "CheckRun")
        if kind == "StatusContext":
            state = str(item.get("state") or "").upper()
            if state in ("SUCCESS",):
                continue
            if state in ("PENDING", "EXPECTED", ""):
                pending.append(name)
            else:
                red.append("%s %s" % (name, state.lower()))
            continue
        status = str(item.get("status") or "").upper()
        conclusion = str(item.get("conclusion") or "").upper()
        if status != "COMPLETED":
            pending.append(name)
        elif conclusion in ("SUCCESS", "SKIPPED", "NEUTRAL"):
            continue
        else:
            red.append("%s %s" % (name, conclusion.lower() or "failed"))
    if red:
        return "red", "red checks: " + ", ".join(red[:5])
    if pending:
        return "pending", "checks still running: " + ", ".join(pending[:5])
    return "green", "checks green (%d)" % len(rollup)


def critic_threads(pr, since):
    """Newest verdict per critic thread among the PR's comments and reviews
    posted at or after ``since`` (the dispatch start), plus the raw bodies so
    an escalation sentence inside a BLOCK-FIX comment can be seen."""
    records, bodies = [], {}
    for c in pr.get("comments") or []:
        if not isinstance(c, dict):
            continue
        at = c.get("createdAt")
        if since and isinstance(at, str) and at < since:
            continue
        rec = desk_live.critic_record(c.get("id"), c.get("url"), at, c.get("body"))
        if rec:
            records.append(rec)
            bodies[rec["id"]] = str(c.get("body") or "")
    for r in pr.get("reviews") or []:
        if not isinstance(r, dict):
            continue
        at = r.get("submittedAt")
        if since and isinstance(at, str) and at < since:
            continue
        rec = desk_live.critic_record(r.get("id"), r.get("url"), at, r.get("body"), kind="review")
        if rec:
            records.append(rec)
            bodies[rec["id"]] = str(r.get("body") or "")
    threads = desk_live.latest_round(records)
    for rec in threads:
        rec["_body"] = bodies.get(rec["id"], "")
        rec["_first"] = rec["_body"].strip().splitlines()[0].strip() if rec["_body"].strip() else ""
    return threads


# ── the fix plan ─────────────────────────────────────────────────────────────

def flatten(text):
    """A comment as one plan-line field: newlines become ' / ', spaces folded."""
    lines = [re.sub(r"\s+", " ", ln).strip() for ln in str(text or "").splitlines()]
    lines = [ln for ln in lines if ln]
    out = " / ".join(lines)
    return re.sub(r"[\x00-\x1f\x7f]", " ", out)


def fix_plan_path(plan):
    base = re.sub(r"\.plan$", "", plan)
    return base + "-fix1.plan"


def write_fix_plan(plan, header, producer, critic, comment_body, dry_run):
    """Write <plan>-fix1.plan next to the original. Returns (path, purpose, why)."""
    after, _fix_round, dispatch_line, purpose = header
    url, flags = dispatch_parts(dispatch_line)
    if not url:
        return None, None, "the original plan has no DISPATCH line to copy"
    path = fix_plan_path(plan)
    branch = producer.get("branch") or critic.get("branch") or ""
    task = ("Fix round 1 on branch %s after BLOCK-FIX. The critic comment, quoted in full: %s "
            "Fix every finding and add a test per finding." % (branch, flatten(comment_body)))
    critic_task = ("ROUND 2 of the review after the fix round. Read the round 1 comment first; "
                   "your comment's first line must carry the same heading, ROUND 2 and the "
                   "verdict. Original task: %s" % flatten(critic.get("task_text") or critic.get("task") or ""))
    fix_purpose = "%s Fix round 1 after BLOCK-FIX." % (purpose or os.path.basename(plan))
    lines = [
        "# %s Written by the queue runner %s." % (fix_purpose, now_iso()),
        "#",
        "# DISPATCH: ./scripts/dispatch.sh %s %s %s" % (url, path, " ".join(flags)),
        "# AFTER: %s" % plan,
        "# FIX-ROUND: 1 of %s" % plan,
        "",
        "1 | %s | %s | %s" % (producer.get("agent"), task, branch),
        "2 | %s | %s | %s" % (critic.get("agent"), critic_task, branch),
        "",
    ]
    if dry_run:
        return path, fix_purpose, None
    full = os.path.join(REPO_DIR, path) if not os.path.isabs(path) else path
    try:
        with open(full, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    except OSError as exc:
        return None, None, "cannot write %s: %s" % (path, exc)
    return path, fix_purpose, None


def queue_call(queue_sh, args):
    rc, out, err = run([queue_sh] + list(args))
    return rc == 0, desk_live.scrub_text(err or out, 160)


# ── settle: act on ended dispatches ──────────────────────────────────────────

def land_root(url):
    """The checkout land.sh fetches and sweeps in, when this machine has one."""
    name = repo_name(url)
    if name == os.path.basename(REPO_DIR):
        return REPO_DIR
    fetch_point = os.path.join(os.environ.get("FLEET_HOME") or os.path.expanduser("~/dev"), name)
    if os.path.isdir(os.path.join(fetch_point, ".git")):
        return fetch_point
    return None


def settle_one(args, gh, pid_path, info, stream_path):
    """Decide one ended dispatch. Returns the mark to write, or None to retry
    next tick (transient: gh unreachable, checks still running)."""
    dispatch_id = os.path.basename(pid_path)[:-4]
    plan = norm_plan(info["plan"])
    plan_abs = plan if os.path.isabs(plan) else os.path.join(REPO_DIR, plan)
    header = plan_header(plan_abs)
    url = info.get("url") or dispatch_parts(header[2])[0] or ""
    slug = repo_slug(url)
    repo = info.get("repo") or repo_name(url)
    dry = args.dry_run

    summary = desk_live.summarize_stream(stream_path) if os.path.isfile(stream_path) else None
    if summary is None or summary.get("ended_at") is None:
        say("%s: ended without a close-out (no dispatch_end); nothing to decide" % dispatch_id)
        return "no-close-out"
    if summary.get("outcome") != "landed":
        say("%s: %s (%s); the Floor shows it, nothing to decide" % (
            dispatch_id, summary.get("outcome"), os.path.basename(plan)))
        return summary.get("outcome") or "ended"

    seats = stream_seats(stream_path)
    critics = {tid: s for tid, s in seats.items() if is_critic(s.get("agent"))}
    if not critics:
        say("%s: no critic seat; nothing to decide" % dispatch_id)
        return "no-critic"
    if not slug:
        open_stop(args.stops, dispatch_id, "no_pr", dry, repo=repo, plan=plan,
                  dispatch_id=dispatch_id, sentence="no repo url on file for this run")
        return "stop:no_pr"

    parsed = desk_live.parse_plan(plan_abs, full_task=True) or {"seats": []}
    mark = None
    for branch in sorted({s.get("branch") or "" for s in critics.values()}):
        n_critics = sum(1 for s in critics.values() if (s.get("branch") or "") == branch)
        pr, why = gh.pr_for_branch(slug, branch)
        if pr is None and why and not why.startswith("no PR"):
            say("%s: %s; will look again next tick" % (dispatch_id, why))
            return None
        common = dict(repo=repo, plan=plan, dispatch_id=dispatch_id, branch=branch)
        if pr is None:
            open_stop(args.stops, dispatch_id, "no_pr", dry, sentence=why, **common)
            mark = "stop:no_pr"
            continue
        number = pr.get("number")
        common.update(pr=number, pr_url=pr.get("url"))
        state = str(pr.get("state") or "").upper()
        if state == "MERGED":
            say("%s: PR #%s already merged" % (dispatch_id, number))
            mark = mark or "merged"
            continue
        if state != "OPEN":
            open_stop(args.stops, dispatch_id, "pr_closed", dry,
                      sentence="PR #%s is %s" % (number, state.lower()), **common)
            mark = "stop:pr_closed"
            continue

        threads = critic_threads(pr, summary.get("started_at"))
        if len(threads) < n_critics:
            open_stop(args.stops, dispatch_id, "critic_silent", dry,
                      sentence="%d of %d critic seats posted a verdict since the run started"
                      % (len(threads), n_critics), **common)
            mark = "stop:critic_silent"
            continue
        verdicts = [t["verdict"] for t in threads]
        first = threads[0]
        sentence = first.get("_first") or first.get("stem")

        if any(v in ("BLOCK-ESCALATE",) for v in verdicts) or any(
                ESCALATION_RE.search(t["_body"]) for t in threads if t["verdict"] == "BLOCK-FIX"):
            open_stop(args.stops, dispatch_id, "escalate", dry, verdict="BLOCK-ESCALATE",
                      sentence=sentence, **common)
            mark = "stop:escalate"
            continue
        if "BLOCK-CLOSE" in verdicts:
            open_stop(args.stops, dispatch_id, "close", dry, verdict="BLOCK-CLOSE",
                      sentence=sentence, **common)
            mark = "stop:close"
            continue
        if any(v not in LANDING_VERDICTS and v != "BLOCK-FIX" for v in verdicts):
            bad = [v for v in verdicts if v not in LANDING_VERDICTS and v != "BLOCK-FIX"]
            open_stop(args.stops, dispatch_id, "unparsed", dry, verdict=bad[0],
                      sentence="%s (verdict word %s is not one the runner acts on)" % (sentence, bad[0]),
                      **common)
            mark = "stop:unparsed"
            continue
        if "BLOCK-FIX" in verdicts:
            block = [t for t in threads if t["verdict"] == "BLOCK-FIX"][0]
            sentence = block.get("_first") or sentence
            if header[1] is not None or re.search(r"-fix\d+\.plan$", plan):
                open_stop(args.stops, dispatch_id, "second_block", dry, verdict="BLOCK-FIX",
                          sentence=sentence, **common)
                mark = "stop:second_block"
                continue
            critic_seat = None
            producer = None
            for seat in parsed.get("seats") or []:
                if (seat.get("branch") or "") != branch:
                    continue
                if is_critic(seat.get("agent")):
                    critic_seat = critic_seat or seat
                else:
                    producer = seat   # the last producer wave on the branch
            if critic_seat is None:
                critic_seat = {"agent": next(s["agent"] for s in critics.values()
                                             if (s.get("branch") or "") == branch),
                               "branch": branch, "task": ""}
            if producer is None:
                open_stop(args.stops, dispatch_id, "no_producer", dry, verdict="BLOCK-FIX",
                          sentence=sentence, **common)
                mark = "stop:no_producer"
                continue
            fix_path, fix_purpose, why = write_fix_plan(plan, header, producer, critic_seat,
                                                        block["_body"], dry)
            if fix_path is None:
                open_stop(args.stops, dispatch_id, "no_producer", dry, verdict="BLOCK-FIX",
                          sentence="%s (%s)" % (sentence, why), **common)
                mark = "stop:no_producer"
                continue
            if dry:
                note("would write %s and queue it for %s after %s (BLOCK-FIX on PR #%s: %s)"
                     % (fix_path, repo, os.path.basename(plan), number, desk_live.scrub_text(sentence)))
            else:
                ok, err = queue_call(args.queue_sh, ["add", fix_path, repo, fix_purpose])
                if ok:
                    queue_call(args.queue_sh, ["mv", fix_path, "1"])
                    note("fix round 1: wrote %s and queued it first for %s, AFTER %s "
                         "(BLOCK-FIX on PR #%s: %s)" % (fix_path, repo, os.path.basename(plan),
                                                        number, desk_live.scrub_text(sentence)))
                else:
                    note("fix round 1: wrote %s but could not queue it: %s" % (fix_path, err))
            mark = "fix-round"
            continue

        # Every thread says SAFE-TO-MERGE or APPROVE-MERGE: the landing path.
        checks, check_sentence = checks_state(pr.get("statusCheckRollup"))
        if checks == "pending":
            say("%s: PR #%s %s; will look again next tick" % (dispatch_id, number, check_sentence))
            return None
        if checks != "green":
            open_stop(args.stops, dispatch_id, "red_checks", dry, verdict=verdicts[0],
                      sentence="%s; %s" % (sentence, check_sentence), **common)
            mark = "stop:red_checks"
            continue
        merge_state = str(pr.get("mergeStateStatus") or "").upper()
        if pr.get("isDraft"):
            if dry:
                note("would mark PR #%s ready (draft) before landing" % number)
            else:
                err = gh.pr_ready(slug, number)
                if err:
                    open_stop(args.stops, dispatch_id, "merge_refused", dry, verdict=verdicts[0],
                              sentence="%s; %s" % (sentence, err), **common)
                    mark = "stop:merge_refused"
                    continue
                fresh, why = gh.pr_state(slug, number)
                if fresh is None:
                    say("%s: %s; will look again next tick" % (dispatch_id, why))
                    return None
                merge_state = str(fresh.get("mergeStateStatus") or "").upper()
        if merge_state == "UNKNOWN":
            say("%s: PR #%s merge state still being computed; will look again next tick"
                % (dispatch_id, number))
            return None
        if merge_state != "CLEAN":
            open_stop(args.stops, dispatch_id, "not_clean", dry, verdict=verdicts[0],
                      sentence="%s; merge state %s" % (sentence, merge_state or "unknown"), **common)
            mark = "stop:not_clean"
            continue
        if dry:
            note("would land PR #%s of %s via land.sh (%s; %s; merge state clean)"
                 % (number, slug, desk_live.scrub_text(sentence), check_sentence))
            mark = "landed"
            continue
        env = dict(os.environ, LAND_REPO=slug)
        root = land_root(url)
        if root:
            env["LAND_ROOT"] = root
        rc, out, err = run([args.land, str(number)], timeout=LAND_TIMEOUT_S, env=env)
        tail = desk_live.scrub_text(" ".join((out or "").splitlines()[-3:]), 200)
        if rc == 0:
            note("landed PR #%s of %s via land.sh (%s). %s" % (number, slug,
                                                                 desk_live.scrub_text(sentence), tail))
            mark = "landed"
        else:
            open_stop(args.stops, dispatch_id, "merge_refused", dry, verdict=verdicts[0],
                      sentence="%s; land.sh exit %s: %s" % (sentence, rc, tail), **common)
            mark = "stop:merge_refused"
    return mark


def clear_resolved_stops(args, gh):
    """A stop goes when its plan left the queue or its PR merged or closed."""
    stops, _meta, _warnings = desk_live.read_stops(args.stops)
    if not stops:
        return
    entries, _w = desk_live.read_queue(args.queue)
    queued = {os.path.basename(str(e.get("plan") or "")) for e in entries}
    checked = 0
    for stop in stops:
        key = stop.get("key")
        if key == GUARD_KEY or not key:
            continue
        plan = stop.get("plan")
        if plan and plan not in queued:
            clear_stop(args.stops, key, "%s is no longer in the queue" % plan, args.dry_run)
            continue
        number = stop.get("pr")
        repo = stop.get("repo")
        if not number or not repo or checked >= MAX_STOP_CHECKS_PER_TICK:
            continue
        slug = None
        for pid_path in list_pid_files(args.runs_dir):
            info = read_pid_file(pid_path)
            if info and os.path.basename(pid_path)[:-4] == stop.get("dispatch_id"):
                slug = repo_slug(info.get("url"))
                break
        if not slug:
            continue
        checked += 1
        fresh, _why = gh.pr_state(slug, number)
        if fresh and str(fresh.get("state") or "").upper() in ("MERGED", "CLOSED"):
            clear_stop(args.stops, key, "PR #%s is %s" % (number, str(fresh["state"]).lower()),
                       args.dry_run)


def list_pid_files(runs_dir):
    try:
        return sorted(os.path.join(runs_dir, n) for n in os.listdir(runs_dir) if n.endswith(".pid"))
    except OSError:
        return []


def cmd_settle(args):
    gh = Gh()
    for pid_path in list_pid_files(args.runs_dir):
        dispatch_id = os.path.basename(pid_path)[:-4]
        mark_path = os.path.join(args.runs_dir, dispatch_id + ".loop")
        if os.path.exists(mark_path):
            continue
        info = read_pid_file(pid_path)
        if not info or not info["pid"]:
            continue
        if pid_alive(info["pid"]):
            continue
        stream_path = os.path.join(args.events_dir, dispatch_id + ".jsonl")
        mark = settle_one(args, gh, pid_path, info, stream_path)
        if mark is None:
            continue
        if args.dry_run:
            say("%s: would mark handled (%s)" % (dispatch_id, mark))
            continue
        try:
            with open(mark_path, "w", encoding="utf-8") as fh:
                fh.write("%s\t%s\n" % (mark, now_iso()))
        except OSError as exc:
            say("cannot write %s: %s" % (mark_path, exc))
    clear_resolved_stops(args, gh)
    return 0


# ── guard: memory and swap ────────────────────────────────────────────────────

def read_config(path):
    cfg = {"min_free_percent": 50.0, "max_swap_used_gb": 3.5}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*(min_free_percent|max_swap_used_gb)\s*:\s*([0-9.]+)", line)
                if m:
                    cfg[m.group(1)] = float(m.group(2))
    except OSError:
        pass
    for key, env in (("min_free_percent", "QUEUE_RUNNER_MIN_FREE_PCT"),
                     ("max_swap_used_gb", "QUEUE_RUNNER_MAX_SWAP_GB")):
        value = os.environ.get(env)
        if value:
            try:
                cfg[key] = float(value)
            except ValueError:
                pass
    return cfg


def _size_gb(number, unit):
    scale = {"K": 1.0 / (1024 * 1024), "M": 1.0 / 1024, "G": 1.0, "T": 1024.0}
    return float(number) * scale.get(unit.upper(), 1.0 / 1024)


def read_memory():
    """{free_pct, swap_used_gb, detail} or (None, reason). macOS first, then
    /proc/meminfo; unreadable means the guard cannot judge and says so."""
    rc, out, _err = run(["vm_stat"])
    if rc == 0 and "Pages free" in out:
        page = re.search(r"page size of (\d+) bytes", out)
        page_size = int(page.group(1)) if page else 4096

        def pages(name):
            m = re.search(r"^Pages %s:\s+(\d+)\." % name, out, re.MULTILINE)
            return int(m.group(1)) if m else 0

        available = (pages("free") + pages("inactive") + pages("speculative")
                     + pages("purgeable")) * page_size
        rc, mem, _err = run(["sysctl", "-n", "hw.memsize"])
        try:
            total = int(mem.strip())
        except ValueError:
            return None, "sysctl hw.memsize gave no number"
        if total <= 0:
            return None, "sysctl hw.memsize gave 0"
        rc, swap, _err = run(["sysctl", "-n", "vm.swapusage"])
        m = re.search(r"used\s*=\s*([0-9.]+)\s*([KMGT])", swap or "")
        if not m:
            return None, "sysctl vm.swapusage unreadable"
        swap_gb = _size_gb(m.group(1), m.group(2))
        free_pct = 100.0 * available / total
        return {"free_pct": free_pct, "swap_used_gb": swap_gb,
                "detail": "free %.0f%% of %.0f GB, swap used %.1f GB" % (
                    free_pct, total / (1024.0 ** 3), swap_gb)}, None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            info = {}
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[0].endswith(":"):
                    info[parts[0][:-1]] = int(parts[1])
        total = info["MemTotal"]
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        swap_gb = (info.get("SwapTotal", 0) - info.get("SwapFree", 0)) / (1024.0 * 1024.0)
        free_pct = 100.0 * avail / total if total else 0.0
        return {"free_pct": free_pct, "swap_used_gb": swap_gb,
                "detail": "free %.0f%% of %.0f GB, swap used %.1f GB" % (
                    free_pct, total / (1024.0 * 1024.0), swap_gb)}, None
    except (OSError, KeyError, ValueError):
        return None, "neither vm_stat nor /proc/meminfo is readable"


def cmd_guard(args):
    cfg = read_config(args.config)
    mem, why = read_memory()
    if mem is None:
        state, reason = "clear", "memory guard off: %s" % why
    else:
        reasons = []
        if mem["free_pct"] < cfg["min_free_percent"]:
            reasons.append("free memory %.0f%% is under %.0f%%" % (mem["free_pct"], cfg["min_free_percent"]))
        if mem["swap_used_gb"] > cfg["max_swap_used_gb"]:
            reasons.append("swap used %.1f GB is over %.1f GB" % (mem["swap_used_gb"], cfg["max_swap_used_gb"]))
        if reasons:
            state = "active"
            reason = "memory guard: starts held, %s (%s)" % (" and ".join(reasons), mem["detail"])
        else:
            state, reason = "clear", "memory guard clear (%s)" % mem["detail"]

    previous = ""
    try:
        with open(args.state_file, "r", encoding="utf-8") as fh:
            previous = fh.read().split("\t", 1)[0].strip()
    except OSError:
        pass
    changed = previous != state
    if changed:
        prefix = "dry run, would log: " if args.dry_run else ""
        if state == "active":
            note(prefix + reason + "; nothing starts until the numbers recover, nothing is killed")
            append_stop(args.stops, {"key": GUARD_KEY, "state": "open", "kind": "guard",
                                     "sentence": reason, "action": STOP_ACTIONS["guard"]},
                        args.dry_run)
            if not args.dry_run:
                queue_call(args.queue_sh, ["hold", reason])
        else:
            if previous == "active":
                note(prefix + "memory guard cleared, starts resume (%s)" % (mem["detail"] if mem else why))
                append_stop(args.stops, {"key": GUARD_KEY, "state": "cleared",
                                         "reason": mem["detail"] if mem else why}, args.dry_run)
            else:
                say(reason)
            if not args.dry_run:
                queue_call(args.queue_sh, ["release"])
        if not args.dry_run:
            try:
                with open(args.state_file, "w", encoding="utf-8") as fh:
                    fh.write("%s\t%s\t%s\n" % (state, now_iso(), reason))
            except OSError as exc:
                say("cannot write %s: %s" % (args.state_file, exc))
    else:
        say(reason)
    emit("guard", state)
    return 0


# ── candidates: queued, unblocked, and not waiting on an AFTER ───────────────

def cmd_candidates(args):
    entries, warnings = desk_live.read_queue(args.queue)
    for warning in warnings:
        note("cannot read queue: %s" % warning)
        return 1
    for entry in entries:
        if (entry.get("status") or "queued") != "queued":
            continue
        if (entry.get("blocked") or "").strip():
            continue
        repo = str(entry.get("repo") or "").strip()
        plan = str(entry.get("plan") or "").strip()
        if not repo or not plan:
            continue
        plan_abs = plan if os.path.isabs(plan) else os.path.join(REPO_DIR, plan)
        after, _fix, _dispatch, _purpose = plan_header(plan_abs)
        reason = ""
        if after:
            landed, reason = plan_landed(after, args.events_dir)
            if landed:
                reason = ""
        current = str(entry.get("waiting") or "").strip()
        if reason != current:
            if args.dry_run:
                say("would write into the queue for %s: waiting: %s" % (plan, reason or "(cleared)"))
            else:
                queue_call(args.queue_sh, ["wait", plan] + ([reason] if reason else []))
                if reason:
                    note("%s waits: %s" % (plan, reason))
                else:
                    note("%s no longer waits: %s has landed" % (plan, os.path.basename(after)))
        if reason:
            say("skip: %s (%s)" % (plan, reason))
            continue
        emit("cand", "%s\t%s" % (repo, plan))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("settle", "guard", "candidates"))
    parser.add_argument("--queue", default=os.path.join(REPO_DIR, "logs", "fleet-queue.json"))
    parser.add_argument("--runs-dir", default=os.path.join(REPO_DIR, "logs", "dispatch-runs"))
    parser.add_argument("--events-dir", default=os.path.join(REPO_DIR, "logs", "fleet-events"))
    parser.add_argument("--stops", default=desk_live.DEFAULT_STOPS_FILE)
    parser.add_argument("--config", default=os.path.join(REPO_DIR, "config", "queue-runner.yaml"))
    parser.add_argument("--state-file", default=None)
    parser.add_argument("--queue-sh", default=os.path.join(SCRIPT_DIR, "queue.sh"))
    parser.add_argument("--land", default=os.path.join(SCRIPT_DIR, "land.sh"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.state_file is None:
        args.state_file = os.path.join(args.runs_dir, "queue-runner-guard.state")
    return {"settle": cmd_settle, "guard": cmd_guard, "candidates": cmd_candidates}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
