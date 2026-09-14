#!/usr/bin/env python3
"""The orchestrator loop behind scripts/queue-runner.sh.

The runner (bash) owns the tick: the pause switch, the tick lock, who is busy,
and the one start per tick. This module owns the judgment the tick needs and
the bookkeeping around it, in four subcommands the runner calls in order:

  settle      look at every detached dispatch that has ended since the last
              tick and act on its critic verdicts, in this order: a block from
              any critic (one automatic fix round on BLOCK-FIX, once per plan;
              a stop for BLOCK-ESCALATE, BLOCK-CLOSE, a BLOCK-FIX naming an
              escalation reason, a bare word, or a silence that replaced a
              verdict); then the head must be green (a run on another commit
              or a cancelled workflow is red, and a check suite still open is
              not green whatever its completed jobs say); then every assigned
              critic seat must have said SAFE-TO-MERGE or APPROVE-MERGE under
              its own heading, bound to the current head (a verdict word on a
              body line is no verdict, a SAFE recorded on an earlier head does
              not count, and a SAFE that records no head does not count);
              then the PR must be CLEAN; then, with landing on, this machine
              must hold a checkout of the repo and a landing runs through
              scripts/land.sh. Landing sits behind QUEUE_LOOP_LAND and is off
              by default, until the landing gate is proven: off, the runner
              makes no write call at all (no gh pr ready, no gh pr merge, no
              land.sh) and a PR past every gate becomes a stop of kind
              ready_to_merge with the action merge, so the Floor's NEEDS YOU
              shows it. A PR GitHub gives no headRefOid never lands and binds
              no SAFE. A draft is marked ready only with landing on, and the
              pass that marked ready never lands: the next tick re-reads the
              PR and re-runs the named rollup on the head.
              Critic verdicts are read from the PR's comments and reviews. A
              plan may name where its critics post with a header line such
              as '# VERDICTS: owner/repo#2340'; then the comments of that
              issue are read too, keeping only comments at or after the run
              start whose body names the PR as 'PR N' or the branch as a
              whole slash-token. No header keeps the PR-only reading.
              Also clears stops whose PR has since merged or closed.
  guard       read the system-wide free percentage the way memory_pressure
              reports it (free plus inactive plus speculative plus purgeable
              pages from vm_stat when that tool is absent, /proc/meminfo
              last) and the swap used; say once per change of state whether
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

Stdlib only. The one network dependency is gh, read-mostly: the only writes it
ever does are `gh pr ready` before a landing and the merge inside land.sh, and
those only when QUEUE_LOOP_LAND switches landing on (default off).
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
# The five reasons a BLOCK-ESCALATE names (the charter's list, the only one).
# A BLOCK-FIX that carries one anywhere in its body is a judgment case: it is
# read as BLOCK-ESCALATE and fires nothing.
ESCALATION_REASONS = ("scope grew", "PRD is wrong or silent", "pre-existing defect found",
                      "cheaper path exists", "security judgment")
ESCALATION_REASON_RE = re.compile(
    r"\b(%s)\b" % "|".join(re.escape(r) for r in ESCALATION_REASONS), re.IGNORECASE)
# A workflow run (check suite) that ended one of these ways is not a green
# head, whatever its surviving check runs say.
RUN_NOT_GREEN = frozenset(("CANCELLED", "FAILURE", "TIMED_OUT", "ACTION_REQUIRED",
                           "STARTUP_FAILURE", "STALE"))
# What a critic seat's plan line says about its comment heading.
HEADING_RE = re.compile(r"first line (?:reads|carries|is|says|must read)\s+[\"'`*]*(CRITIC\b[^.\n]*)",
                        re.IGNORECASE)
# The head commit's own check rollup, every run naming its commit and suite.
HEAD_CHECKS_QUERY = (
    "query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){"
    "object(oid:$oid){... on Commit{oid statusCheckRollup{contexts(last:100){nodes{__typename "
    "... on CheckRun{name status conclusion checkSuite{status conclusion commit{oid}}} "
    "... on StatusContext{context state}}}}}}}}")
AFTER_RE = re.compile(r"^#\s*AFTER:\s*(\S+)", re.IGNORECASE)
FIX_ROUND_RE = re.compile(r"^#\s*FIX-ROUND:\s*(\d+)\s+of\s+(\S+)", re.IGNORECASE)
DISPATCH_RE = re.compile(r"^#\s*DISPATCH:\s*(.*)$", re.IGNORECASE)
VERDICTS_RE = re.compile(r"^#\s*VERDICTS:\s*(.+?)\s*$", re.IGNORECASE)
VERDICTS_ISSUE_RE = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)")
VERDICTS_NUMBER_RE = re.compile(r"(?:issue\s+)?#(\d+)|\bissue\s+(\d+)", re.IGNORECASE)
MAX_STOP_CHECKS_PER_TICK = 10

# One action per stop kind: the words the Floor's NEEDS YOU row ends with.
STOP_ACTIONS = {
    "guard": "free memory or wait; the runner resumes by itself",
    "ready_to_merge": "merge",
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


def land_switch_on():
    """QUEUE_LOOP_LAND: landing is off unless the variable says on, exactly.
    Off is the default while the landing gate is unproven."""
    return os.environ.get("QUEUE_LOOP_LAND", "").strip().lower() in ("1", "true", "on", "yes")


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
    """(after, fix_round, dispatch_line, purpose, verdicts) from a plan's
    comment lines. verdicts is the VERDICTS header value (where the plan's
    critics post, for example 'owner/repo#2340'), else None."""
    after = fix_round = dispatch = verdicts = None
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
                m = VERDICTS_RE.match(stripped)
                if m:
                    if verdicts is None:
                        verdicts = m.group(1)
                    continue
                body = stripped.lstrip("#").strip()
                if not purpose and body and not desk_live.is_machine_header(body):
                    purpose = desk_live.scrub_text(body)
    except OSError:
        pass
    return after, fix_round, dispatch, purpose, verdicts


def verdicts_issue(value, slug):
    """(slug, number) a VERDICTS header value names: 'owner/repo#2340' pins
    the repo; '#2340' and 'issue 2340' read against the run's own repo. None
    when the value names no issue."""
    text = str(value or "")
    match = VERDICTS_ISSUE_RE.search(text)
    if match:
        return match.group(1), int(match.group(2))
    match = VERDICTS_NUMBER_RE.search(text)
    if match and slug:
        return slug, int(match.group(1) or match.group(2))
    return None


def names_run_pr(body, number, branch):
    """True when a comment body names the run's PR ('PR 2851', 'PR #2851') or
    its branch as a whole slash-token. A bare '#N' is an issue reference, not
    a PR number, and when the body names any 'PR #M' this PR is not among,
    the comment speaks of another PR and covers nobody on this run. The PR
    numbers and the slash-token rule are the ones desk_live.critic_record
    already applies (PR_REF_RE, _slugs)."""
    text = str(body or "")
    if number:
        prs = {int(n) for n in desk_live.PR_REF_RE.findall(text)}
        if int(number) in prs:
            return True
        if prs:
            return False
    if branch:
        slugs = {tok.strip(".,;:()'\"`") for tok in text.split() if "/" in tok}
        if str(branch) in slugs:
            return True
    return False


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


def stop_text(value, limit=200):
    """One line as the stops file may carry it. The same law as a seat's task
    line on the Floor (desk_live.first_sentence): the first sentence only,
    every slash token checked against this worktree (an operator path, a home
    path, a variable reads outside-repo), control chars out, secret shapes
    redacted, capped. Nothing else reaches the file."""
    return desk_live.first_sentence(value, limit)


def verdict_line(rec):
    """The verdict line as parsed (heading, round, verdict): what the stops
    file and the log carry instead of the raw first line, so nothing a critic
    wrote after the verdict (a path, a prompt, a token) travels with it."""
    if rec.get("verdict") is None:
        return "%s: no single verdict word on its newest first line" % rec["stem"]
    rnd = " ROUND %d" % rec["round"] if (rec.get("round") or 1) > 1 else ""
    return "%s%s: %s" % (rec["stem"], rnd, rec["verdict"])


def open_stop(stops_file, key, kind, dry_run, **fields):
    """One stop: a line in the stops file, a line in the log. Never a merge."""
    record = {"key": key, "state": "open", "kind": kind,
              "action": STOP_ACTIONS.get(kind, "look")}
    for name, value in fields.items():
        if value is None:
            continue
        if name == "plan":
            value = os.path.basename(str(value))
        elif name == "pr_url":
            value = desk_live.scrub_text(value)
        elif isinstance(value, str):
            value = stop_text(value)
        record[name] = value
    append_stop(stops_file, record, dry_run)
    where = ""
    if record.get("pr"):
        where = " PR #%s" % record["pr"]
    note("%sstop (%s)%s: %s. Action: %s" % (
        "would " if dry_run else "", kind, where,
        record.get("sentence") or "", record["action"]))


def clear_stop(stops_file, key, why, dry_run, **fields):
    record = {"key": key, "state": "cleared", "reason": stop_text(why)}
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
        """State, draft flag, merge state and the check rollup, re-read after
        a write: the answer to `gh pr ready` is never the pre-ready rollup."""
        data, why = self.json(
            ["pr", "view", str(number), "-R", slug, "--json",
             "state,isDraft,mergeStateStatus,headRefOid,statusCheckRollup"],
            "gh pr view %s#%s" % (slug, number))
        if data is None:
            return None, why
        return data, None

    def issue_comments(self, slug, number):
        """The comments of the issue a plan's VERDICTS header names."""
        data, why = self.json(
            ["issue", "view", str(number), "-R", slug, "--json", "comments"],
            "gh issue view %s#%s" % (slug, number))
        if data is None:
            return None, why
        comments = data.get("comments") if isinstance(data, dict) else None
        if not isinstance(comments, list):
            return None, "gh issue view returned an unexpected payload"
        return [c for c in comments if isinstance(c, dict)], None

    def head_checks(self, slug, head):
        """The head commit's own check rollup from GitHub, each run naming the
        commit and the suite it belongs to. (rollup, None), ([], None) when the
        commit has no checks at all, else (None, why)."""
        owner, _sep, name = str(slug or "").partition("/")
        data, why = self.json(
            ["api", "graphql", "-f", "owner=%s" % owner, "-f", "name=%s" % name,
             "-f", "oid=%s" % head, "-f", "query=%s" % HEAD_CHECKS_QUERY],
            "gh api graphql checks of %s" % str(head)[:8])
        if data is None:
            return None, why
        try:
            commit = data["data"]["repository"]["object"]
        except (KeyError, TypeError):
            return None, "gh api graphql returned no commit"
        if not isinstance(commit, dict):
            return None, "head %s is not on GitHub" % str(head)[:8]
        rollup = commit.get("statusCheckRollup")
        if not isinstance(rollup, dict):
            return [], None
        nodes = (rollup.get("contexts") or {}).get("nodes") or []
        return [n for n in nodes if isinstance(n, dict)], None

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


def item_commit(item):
    """The commit a rollup item names (on itself or on its check suite), else None."""
    for holder in (item, item.get("checkSuite")):
        commit = holder.get("commit") if isinstance(holder, dict) else None
        if isinstance(commit, dict) and commit.get("oid"):
            return str(commit["oid"])
    return None


def item_run_conclusion(item):
    """How the workflow run (check suite) behind a check run ended, upper-cased,
    else an empty string."""
    suite = item.get("checkSuite")
    if not isinstance(suite, dict):
        return ""
    run = suite.get("workflowRun")
    if isinstance(run, dict) and run.get("conclusion"):
        return str(run["conclusion"]).upper()
    return str(suite.get("conclusion") or "").upper()


def rollup_named(rollup):
    """True when every check run in the rollup names the commit it ran on.

    gh pr list's rollup names none: it is the PR's last commit by gh's own
    query, but no item says so and no item carries its suite's conclusion.
    Such a payload is a pre-filter; before a landing the runner asks the head
    commit itself (Gh.head_checks). A payload that names its commits is
    judged as it stands."""
    runs = [i for i in rollup or [] if isinstance(i, dict)
            and (i.get("__typename") or "CheckRun") == "CheckRun" and "context" not in i]
    return bool(runs) and all(item_commit(i) for i in runs)


def checks_running(rollup):
    """True when a check run or status context on the rollup is itself still
    running, as opposed to every job done and only a suite not yet closed."""
    for item in rollup or []:
        if not isinstance(item, dict):
            continue
        kind = item.get("__typename") or ("StatusContext" if "context" in item else "CheckRun")
        if kind == "StatusContext":
            if str(item.get("state") or "").upper() in ("PENDING", "EXPECTED", ""):
                return True
        elif str(item.get("status") or "").upper() != "COMPLETED":
            return True
    return False


def head_checks_state(rollup, head):
    """checks_state, bound to the head commit.

    A run that names another commit is stale and red (a green run on the
    previous push is not a green head). A run whose workflow run was cancelled,
    failed or timed out is red even when the run itself reads success or
    skipped (a cancelled workflow is not a green head). A check suite still
    open is pending even when every job under it completed with success: only
    a completed suite on the head counts. Then the per-run states, as
    checks_state reads them."""
    head = str(head or "")
    red, open_suites = [], []
    for item in rollup or []:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or item.get("context") or "check"
        oid = item_commit(item)
        if oid and head and oid != head:
            red.append("%s ran on %s, head is %s" % (name, oid[:8], head[:8]))
            continue
        suite = item.get("checkSuite")
        if isinstance(suite, dict):
            suite_status = str(suite.get("status") or "").upper()
            if suite_status and suite_status != "COMPLETED":
                open_suites.append("%s: its check suite is %s" % (
                    name, suite_status.lower().replace("_", " ")))
                continue
        conclusion = item_run_conclusion(item)
        if conclusion in RUN_NOT_GREEN:
            red.append("%s: its workflow run %s" % (name, conclusion.lower().replace("_", " ")))
    if red:
        return "red", "red checks: " + ", ".join(red[:5])
    state, sentence = checks_state(rollup)
    if state == "red":
        return state, sentence
    if open_suites:
        return "pending", "checks still running: " + ", ".join(open_suites[:5])
    return state, sentence


# A commit a critic comment names: a token of 40 or more word characters, the
# shape of "Head at report: <sha>" and of "Reviewed <sha>." A SAFE is bound
# to the head it names.
HEAD_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{40,}(?![A-Za-z0-9])")


def safes_on_head(threads, head):
    """The threads, minus landing verdicts not bound to the head.

    A SAFE-TO-MERGE or APPROVE-MERGE counts only for the head it records:
    the body names the head commit (a token of 40 or more word characters,
    the shape of "Head at report: <sha>"), or the thread is a review GitHub
    recorded on the head (commit.oid). A SAFE that names an earlier head, a
    short SHA, or no commit at all is not bound to the head and never counts:
    a push after SAFE, or a critic that did not record the head, returns the
    PR to waiting for critics. An empty head binds no SAFE at all."""
    head = str(head or "")
    if not head:
        return [t for t in threads if t.get("verdict") not in LANDING_VERDICTS]
    out = []
    for thread in threads:
        if thread.get("verdict") in LANDING_VERDICTS:
            named = HEAD_TOKEN_RE.findall(thread.get("_body") or "")
            if named:
                if head not in named:
                    continue
            elif str(thread.get("_commit") or "") != head:
                continue
        out.append(thread)
    return out


def unbound_safes(before, after, head):
    """The stems of landing verdicts safes_on_head dropped for recording no
    head at all (no 40-char token in the body, no review commit on the head),
    sorted. A stale verdict named an earlier head; an unbound one recorded
    nothing, and the stop says so."""
    head = str(head or "")
    out = set()
    for thread in before:
        if thread in after or thread.get("verdict") not in LANDING_VERDICTS:
            continue
        if HEAD_TOKEN_RE.findall(thread.get("_body") or ""):
            continue
        if head and str(thread.get("_commit") or "") == head:
            continue
        out.add(thread.get("stem") or "critic")
    return sorted(out)


def escalation_reason(body):
    """The escalation word or charter reason a comment body carries, else None."""
    match = ESCALATION_RE.search(str(body or "")) or ESCALATION_REASON_RE.search(str(body or ""))
    return match.group(1) if match else None


def critic_threads(pr, since, extra=None):
    """The newest record of every critic thread (thread = first-line heading)
    among the PR's comments and reviews posted at or after ``since`` (the
    dispatch start), newest first. ``extra`` carries the comments of the issue
    a VERDICTS header names, already filtered to the ones that name this run;
    they parse under the same rules as a PR comment.

    A comment whose first line carries CRITIC and no single verdict word is
    silence (the fleet rule). Silence never opens a thread; but a later
    silence under a heading that had a verdict supersedes it, so the thread
    comes back with verdict None and the runner stops for a person instead of
    landing on the earlier SAFE. Each thread carries ``_body`` (raw, for the
    escalation sentence), ``_commit`` (the commit a review was recorded on,
    else None) and ``_line`` (the parsed verdict line, the only form of it
    the stops file and the log ever carry)."""
    records, bodies, commits = [], {}, {}

    def add(cid, url, at, body, kind, commit=None):
        text = str(body or "")
        if since and isinstance(at, str) and at < since:
            return
        rec = desk_live.critic_record(cid, url, at, text, kind=kind)
        if rec is None:
            lines = text.strip().splitlines()
            first = lines[0].strip() if lines else ""
            if not desk_live.CRITIC_LINE_RE.search(first):
                return
            rnd = desk_live.ROUND_RE.search(first)
            rec = {"id": cid, "at": at if isinstance(at, str) else None, "kind": kind,
                   "verdict": None, "round": int(rnd.group(1)) if rnd else 1,
                   "stem": desk_live.critic_stem(first)}
        records.append(rec)
        bodies[cid] = text
        if commit:
            commits[cid] = str(commit)

    for c in list(pr.get("comments") or []) + list(extra or []):
        if isinstance(c, dict):
            add(c.get("id"), c.get("url"), c.get("createdAt"), c.get("body"), "comment")
    for r in pr.get("reviews") or []:
        if isinstance(r, dict):
            commit = r.get("commit")
            add(r.get("id"), r.get("url"), r.get("submittedAt"), r.get("body"), "review",
                commit.get("oid") if isinstance(commit, dict) else None)
    spoke = {r["stem"].upper() for r in records if r["verdict"] is not None}
    threads = [t for t in desk_live.latest_round(records) if t["stem"].upper() in spoke]
    for rec in threads:
        rec["_body"] = bodies.get(rec["id"], "")
        rec["_commit"] = commits.get(rec["id"])
        rec["_line"] = verdict_line(rec)
    return threads


def heading_in_task(text):
    """The comment heading a critic seat's plan line names ("... first line
    reads CRITIC ZETA with SAFE-TO-MERGE or BLOCK-FIX"), as a thread stem,
    else None."""
    match = HEADING_RE.search(str(text or ""))
    if not match:
        return None
    stem = desk_live.critic_stem(match.group(1))
    return stem if stem != "CRITIC" else None


def seat_headings(parsed_seats, critics, branch):
    """(role, heading or None) per critic seat of the run on ``branch``: the
    stream's critic seats, in task order, matched to the plan's critic lines
    of the same role and branch. A seat the plan does not name gets None."""
    lines = [s for s in parsed_seats
             if (s.get("branch") or "") == branch and is_critic(s.get("agent"))]
    out = []
    for tid in sorted(critics, key=lambda t: (len(t), t)):
        seat = critics[tid]
        if (seat.get("branch") or "") != branch:
            continue
        heading = None
        for i, line in enumerate(lines):
            if line.get("agent") == seat.get("agent"):
                heading = heading_in_task(line.get("task_text") or line.get("task"))
                lines.pop(i)
                break
        out.append((seat.get("agent"), heading))
    return out


def assign_threads(threads, headings, plan):
    """Bind every assigned critic seat to one thread, by stem.

    A seat whose plan line names a heading needs a thread under that stem,
    exactly. A seat the plan does not name takes an unclaimed thread whose
    heading shares a word with a heading the run did name (minus CRITIC); a
    word shared with the plan filename alone never counts, and any other stem
    is somebody else's comment and covers nobody. The plan argument stays in
    the signature for the callers that already pass it. Returns the seats
    left without a thread, by heading or role."""
    by_stem = {t["stem"].upper(): t for t in threads}
    run_words = set()
    for _role, heading in headings:
        if heading:
            run_words |= set(heading.upper().split()) - {"CRITIC"}
    claimed, missing = set(), []
    for _role, heading in headings:
        if heading is None:
            continue
        key = heading.upper()
        if key in by_stem and key not in claimed:
            claimed.add(key)
        else:
            missing.append(heading)
    for role, heading in headings:
        if heading is not None:
            continue
        free = sorted(k for k in by_stem if k not in claimed and set(k.split()) & run_words)
        if free:
            claimed.add(free[0])
        else:
            missing.append(role or "critic")
    return missing


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
    after, _fix_round, dispatch_line, purpose, _verdicts = header
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

def spent_plans(runs_dir):
    """Plans whose one fix round the runner already fired, from its own marks:
    every <id>.loop that reads fix-round names, through its pid file, the plan
    it settled. The FIX-ROUND header and the -fixN suffix are hints; this is
    the state, whatever the plan file says."""
    spent = set()
    for pid_path in list_pid_files(runs_dir):
        try:
            with open(pid_path[:-4] + ".loop", "r", encoding="utf-8") as fh:
                mark = fh.read().split("\t", 1)[0].strip()
        except OSError:
            continue
        if mark != "fix-round":
            continue
        info = read_pid_file(pid_path)
        if info and info.get("plan"):
            spent.add(os.path.basename(norm_plan(info["plan"])))
    return spent


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
        headings = seat_headings(parsed.get("seats") or [], critics, branch)
        n_critics = len(headings)
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

        # Critic verdicts come from the PR. A plan with a VERDICTS header
        # also reads the issue it names, keeping only comments whose body
        # names this PR or this branch (critic_threads applies the run-start
        # filter; names_run_pr applies the naming filter). A gh failure here
        # is transient, like a failed pr list: look again next tick.
        extra = []
        if header[4]:
            ref = verdicts_issue(header[4], slug)
            if ref is None:
                say("%s: VERDICTS header names no issue (%s); reading the PR only"
                    % (dispatch_id, stop_text(header[4], 80)))
            else:
                comments, why = gh.issue_comments(ref[0], ref[1])
                if comments is None:
                    say("%s: %s; will look again next tick" % (dispatch_id, why))
                    return None
                extra = [c for c in comments if names_run_pr(c.get("body"), number, branch)]
        threads = critic_threads(pr, summary.get("started_at"), extra)
        verdicts = [t["verdict"] for t in threads]
        sentence = threads[0]["_line"] if threads else "no critic verdict since the run started"

        # 1. A block from any critic acts first, whoever posted it, and a later
        #    block or silence has already replaced that critic's earlier SAFE.
        silent = [t for t in threads if t["verdict"] is None]
        if silent:
            open_stop(args.stops, dispatch_id, "unparsed", dry,
                      sentence="%s; the earlier verdict no longer stands" % silent[0]["_line"],
                      **common)
            mark = "stop:unparsed"
            continue
        escalated = [(t, escalation_reason(t["_body"])) for t in threads if t["verdict"] == "BLOCK-FIX"]
        escalated = [(t, reason) for t, reason in escalated if reason]
        if "BLOCK-ESCALATE" in verdicts or escalated:
            if "BLOCK-ESCALATE" not in verdicts:
                block, reason = escalated[0]
                sentence = "%s; names %s" % (block["_line"], reason)
            open_stop(args.stops, dispatch_id, "escalate", dry, verdict="BLOCK-ESCALATE",
                      sentence=sentence, **common)
            mark = "stop:escalate"
            continue
        if "BLOCK-CLOSE" in verdicts:
            open_stop(args.stops, dispatch_id, "close", dry, verdict="BLOCK-CLOSE",
                      sentence=sentence, **common)
            mark = "stop:close"
            continue
        bad = [v for v in verdicts if v not in LANDING_VERDICTS and v != "BLOCK-FIX"]
        if bad:
            open_stop(args.stops, dispatch_id, "unparsed", dry, verdict=bad[0],
                      sentence="%s (verdict word %s is not one the runner acts on)" % (sentence, bad[0]),
                      **common)
            mark = "stop:unparsed"
            continue
        if "BLOCK-FIX" in verdicts:
            block = [t for t in threads if t["verdict"] == "BLOCK-FIX"][0]
            sentence = block["_line"]
            spent = (header[1] is not None or re.search(r"-fix\d+\.plan$", plan)
                     or os.path.basename(plan) in spent_plans(args.runs_dir)
                     or os.path.isfile(os.path.join(REPO_DIR, fix_plan_path(plan))))
            if spent:
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
                     % (fix_path, repo, os.path.basename(plan), number, sentence))
            else:
                ok, err = queue_call(args.queue_sh, ["add", fix_path, repo, fix_purpose])
                if ok:
                    queue_call(args.queue_sh, ["mv", fix_path, "1"])
                    note("fix round 1: wrote %s and queued it first for %s, AFTER %s "
                         "(BLOCK-FIX on PR #%s: %s)" % (fix_path, repo, os.path.basename(plan),
                                                        number, sentence))
                else:
                    note("fix round 1: wrote %s but could not queue it: %s" % (fix_path, err))
            mark = "fix-round"
            continue

        # 2. The head must be green before any verdict is counted: a run that
        #    names another commit, or a cancelled workflow, is red here, and a
        #    check suite still open is not green whatever its jobs say. Jobs
        #    still running are looked at again next tick; jobs done under a
        #    suite that will not close is a stop for a person. A PR GitHub
        #    gives no headRefOid has no head a check or a SAFE can bind to:
        #    it never lands.
        head = str(pr.get("headRefOid") or "")
        if not head:
            open_stop(args.stops, dispatch_id, "red_checks", dry,
                      verdict=verdicts[0] if verdicts else None,
                      sentence="%s; GitHub names no head commit for this PR" % sentence, **common)
            mark = "stop:red_checks"
            continue
        rollup = pr.get("statusCheckRollup")
        checks, check_sentence = head_checks_state(rollup, head)
        if checks == "pending" and checks_running(rollup):
            say("%s: PR #%s %s; will look again next tick" % (dispatch_id, number, check_sentence))
            return None
        if checks != "green":
            open_stop(args.stops, dispatch_id, "red_checks", dry,
                      verdict=verdicts[0] if verdicts else None,
                      sentence="%s; %s" % (sentence, check_sentence), **common)
            mark = "stop:red_checks"
            continue

        # 3. Every assigned critic seat said SAFE-TO-MERGE or APPROVE-MERGE,
        #    each under its own heading, bound to the head that is about to
        #    merge: a SAFE recorded on an earlier head does not count after
        #    the head moves, a SAFE that records no head never counts, and a
        #    stem the run did not assign covers no seat.
        kept = safes_on_head(threads, head)
        unbound = unbound_safes(threads, kept, head)
        threads = kept
        missing = assign_threads(threads, headings, plan)
        if missing:
            silence = "%d of %d critic seats posted a verdict since the run started; " \
                      "missing: %s" % (n_critics - len(missing), n_critics, ", ".join(missing))
            if unbound:
                silence += "; %s did not record the head" % ", ".join(unbound)
            open_stop(args.stops, dispatch_id, "critic_silent", dry,
                      sentence=silence, **common)
            mark = "stop:critic_silent"
            continue

        # 4. The PR must be mergeable as it stands.
        merge_state = str(pr.get("mergeStateStatus") or "").upper()
        if merge_state == "UNKNOWN":
            say("%s: PR #%s merge state still being computed; will look again next tick"
                % (dispatch_id, number))
            return None
        if merge_state != "CLEAN":
            open_stop(args.stops, dispatch_id, "not_clean", dry, verdict=verdicts[0],
                      sentence="%s; merge state %s" % (sentence, merge_state or "unknown"), **common)
            mark = "stop:not_clean"
            continue

        # 5. gh pr list's rollup names no commit per run: before any landing
        #    decision, ask the head commit itself and judge that rollup the
        #    same way. This gate is read-only and runs with landing on or off.
        if not rollup_named(rollup):
            fresh, why = gh.head_checks(slug, head)
            if fresh is None:
                say("%s: PR #%s: %s; will look again next tick" % (dispatch_id, number, why))
                return None
            checks, check_sentence = head_checks_state(fresh, head)
            if checks == "pending" and checks_running(fresh):
                say("%s: PR #%s %s; will look again next tick" % (dispatch_id, number, check_sentence))
                return None
            if checks != "green":
                open_stop(args.stops, dispatch_id, "red_checks", dry, verdict=verdicts[0],
                          sentence="%s; on head %s: %s" % (sentence, head[:8], check_sentence),
                          **common)
                mark = "stop:red_checks"
                continue

        # 6. Landing sits behind QUEUE_LOOP_LAND and is off by default, until
        #    the landing gate is proven. Off, the runner makes no write call
        #    (no gh pr ready, no gh pr merge, no land.sh): a PR past every
        #    gate is a stop row for a person, action merge.
        if not args.land_enabled:
            draft_note = "; the PR is still a draft" if pr.get("isDraft") else ""
            open_stop(args.stops, dispatch_id, "ready_to_merge", dry, verdict=verdicts[0],
                      sentence="%s; %s%s" % (sentence, check_sentence, draft_note), **common)
            mark = "stop:ready_to_merge"
            continue

        # 7. A landing needs a checkout of this repo on this machine: land.sh
        #    fetches and sweeps in it, and must never stand in another repo's.
        root = land_root(url)
        if root is None:
            open_stop(args.stops, dispatch_id, "merge_refused", dry, verdict=verdicts[0],
                      sentence="%s; no local checkout of %s on this machine for land.sh"
                      % (sentence, repo), **common)
            mark = "stop:merge_refused"
            continue

        # 8. The landing: a draft is marked ready first, then the checks and
        #    the merge state are re-read on the head. Marking ready starts new
        #    runs and the re-read cannot tell the pre-ready green from them,
        #    so the pass that marked ready never lands: the next tick re-reads
        #    the PR from pr list and re-runs the named rollup on the head
        #    (gate 5) before land.sh.
        if pr.get("isDraft"):
            if dry:
                note("would mark PR #%s ready (draft); the pass that marks ready never lands"
                     % number)
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
                post_head = str(fresh.get("headRefOid") or "")
                if not post_head:
                    open_stop(args.stops, dispatch_id, "red_checks", dry, verdict=verdicts[0],
                              sentence="%s; after ready: GitHub names no head commit" % sentence,
                              **common)
                    mark = "stop:red_checks"
                    continue
                post_rollup = fresh.get("statusCheckRollup")
                post_checks, post_sentence = head_checks_state(post_rollup, post_head)
                if post_checks == "pending" and checks_running(post_rollup):
                    say("%s: PR #%s after ready: %s; will look again next tick"
                        % (dispatch_id, number, post_sentence))
                    return None
                if post_checks != "green":
                    open_stop(args.stops, dispatch_id, "red_checks", dry, verdict=verdicts[0],
                              sentence="%s; after ready: %s" % (sentence, post_sentence), **common)
                    mark = "stop:red_checks"
                    continue
                merge_state = str(fresh.get("mergeStateStatus") or "").upper()
                if merge_state == "UNKNOWN":
                    say("%s: PR #%s merge state still being computed; will look again next tick"
                        % (dispatch_id, number))
                    return None
                if merge_state != "CLEAN":
                    open_stop(args.stops, dispatch_id, "not_clean", dry, verdict=verdicts[0],
                              sentence="%s; merge state %s" % (sentence, merge_state or "unknown"),
                              **common)
                    mark = "stop:not_clean"
                    continue
                note("marked PR #%s ready; the landing re-reads the head on the next tick" % number)
                return None
        if dry:
            note("would land PR #%s of %s via land.sh (%s; %s; merge state clean)"
                 % (number, slug, sentence, check_sentence))
            mark = "landed"
            continue
        env = dict(os.environ, LAND_REPO=slug, LAND_ROOT=root)
        rc, out, err = run([args.land, str(number)], timeout=LAND_TIMEOUT_S, env=env)
        tail = stop_text(" ".join((out or "").splitlines()[-3:]), 200)
        if rc == 0:
            note("landed PR #%s of %s via land.sh (%s). %s" % (number, slug, sentence, tail))
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


MEM_PRESSURE_RE = re.compile(r"System-wide memory free percentage:\s*([0-9]+(?:\.[0-9]+)?)\s*%")


def _sysctl_numbers():
    """(total_bytes, swap_used_gb, None) from sysctl, else (None, None, why)."""
    rc, mem, _err = run(["sysctl", "-n", "hw.memsize"])
    try:
        total = int(mem.strip())
    except ValueError:
        return None, None, "sysctl hw.memsize gave no number"
    if total <= 0:
        return None, None, "sysctl hw.memsize gave 0"
    rc, swap, _err = run(["sysctl", "-n", "vm.swapusage"])
    m = re.search(r"used\s*=\s*([0-9.]+)\s*([KMGT])", swap or "")
    if not m:
        return None, None, "sysctl vm.swapusage unreadable"
    return total, _size_gb(m.group(1), m.group(2)), None


def _reading(free_pct, total, swap_gb, source):
    """The reading dict, or (None, reason) when the numbers are impossible:
    a sensor that answers garbage is an unreadable sensor, not a reading."""
    if not 0.0 <= free_pct <= 100.0 or swap_gb < 0:
        return None, "%s gave an impossible reading (free %.0f%% of %.0f GB, swap %.1f GB)" % (
            source, free_pct, total / (1024.0 ** 3), swap_gb)
    return {"free_pct": free_pct, "swap_used_gb": swap_gb,
            "detail": "free %.0f%% of %.0f GB, swap used %.1f GB" % (
                free_pct, total / (1024.0 ** 3), swap_gb)}, None


def read_memory():
    """{free_pct, swap_used_gb, detail} or (None, reason).

    The free percentage is the number the fleet reads by hand: the
    system-wide free percentage memory_pressure reports. When that tool is
    absent, the vm_stat sum of free, inactive, speculative and purgeable
    pages; macOS keeps raw free pages low by design and reclaims the rest on
    demand, so a guard on raw free holds a healthy machine. The
    /proc/meminfo fallback is for a machine with neither tool. A sensor that
    answers garbage is an unreadable sensor, not a reading: the guard cannot
    judge and says so."""
    rc, out, _err = run(["memory_pressure"])
    if rc == 0:
        m = MEM_PRESSURE_RE.search(out)
        if not m:
            return None, "memory_pressure answered but its output is unreadable"
        total, swap_gb, why = _sysctl_numbers()
        if why:
            return None, why
        return _reading(float(m.group(1)), total, swap_gb, "memory_pressure")
    rc, out, _err = run(["vm_stat"])
    if rc == 0 and "Pages free" in out:
        page = re.search(r"page size of (\d+) bytes", out)
        page_size = int(page.group(1)) if page else 4096

        def pages(name):
            m = re.search(r"^Pages %s:\s+(\d+)\." % name, out, re.MULTILINE)
            return int(m.group(1)) if m else 0

        available = (pages("free") + pages("inactive") + pages("speculative")
                     + pages("purgeable")) * page_size
        total, swap_gb, why = _sysctl_numbers()
        if why:
            return None, why
        return _reading(100.0 * available / total, total, swap_gb, "vm_stat")
    if rc == 0:
        return None, "vm_stat answered but its output is unreadable"
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
        if not 0.0 <= free_pct <= 100.0 or swap_gb < 0:
            return None, "/proc/meminfo gave an impossible reading (free %.0f%%, swap %.1f GB)" % (
                free_pct, swap_gb)
        return {"free_pct": free_pct, "swap_used_gb": swap_gb,
                "detail": "free %.0f%% of %.0f GB, swap used %.1f GB" % (
                    free_pct, total / (1024.0 * 1024.0), swap_gb)}, None
    except (OSError, KeyError, ValueError):
        return None, "neither memory_pressure, vm_stat nor /proc/meminfo is readable"


def cmd_guard(args):
    cfg = read_config(args.config)
    previous = ""
    try:
        with open(args.state_file, "r", encoding="utf-8") as fh:
            previous = fh.read().split("\t", 1)[0].strip()
    except OSError:
        pass
    mem, why = read_memory()
    if mem is None:
        # No reading is not a recovery: the last state stands, a hold included.
        # Only a machine with no state yet and no sensor runs unguarded.
        state = previous if previous in ("active", "clear") else "clear"
        reason = "memory guard: sensor unreadable (%s); keeping the last state, %s" % (why, state)
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

    changed = previous != state
    if changed:
        prefix = "dry run, would log: " if args.dry_run else ""
        if state == "active":
            note(prefix + reason + "; nothing starts until the numbers recover, nothing is killed")
            append_stop(args.stops, {"key": GUARD_KEY, "state": "open", "kind": "guard",
                                     "sentence": stop_text(reason), "action": STOP_ACTIONS["guard"]},
                        args.dry_run)
            if not args.dry_run:
                queue_call(args.queue_sh, ["hold", reason])
        else:
            if previous == "active":
                note(prefix + "memory guard cleared, starts resume (%s)" % (mem["detail"] if mem else why))
                append_stop(args.stops, {"key": GUARD_KEY, "state": "cleared",
                                         "reason": stop_text(mem["detail"] if mem else why)}, args.dry_run)
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
        after = plan_header(plan_abs)[0]
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
    args.land_enabled = land_switch_on()
    return {"settle": cmd_settle, "guard": cmd_guard, "candidates": cmd_candidates}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
