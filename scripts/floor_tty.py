#!/usr/bin/env python3
"""The Floor in the terminal.

Reads the same live.json the Floor page reads (site/experience/data/live.json,
written by scripts/desk_live.py) and renders it as plain text in the order of
docs/proposals/floor-v3-purpose.md section 4:

    1. the status line: running, up next, landed, failed, needs you, last
       event age. Under stale, offline or replay the state is said in words
       before any number.
    2. NEEDS YOU, one line per item: the text, the one action, the PR or
       comment reference as text.
    3. NOW grouped by repo, one line per seat: repo, role, issue, task line,
       status sentence, elapsed.
    4. UP NEXT: position, repo, issue, purpose, the blocked reason in place.
    5. INITIATIVES: repo, milestone, waves landed of planned, open issues,
       last landed PR, the exit sentence.
    6. FAILED today, then LANDED today.

Never more than 60 lines, never wider than 100 columns. Refreshes every five
seconds in place; q quits; --once prints and exits for scripting. Plain text
by default; --color adds colour and changes no character of the text.

The rules of section 6 hold here as on the page: the renderer never reads the
event streams, only the projection; a queued plan is only ever queued;
stale and offline mark every section; a replay carries its watermark on
every section; no prompt, task body, path or secret is printed (the
projection publishes none, and this file prints only the fields it names).

The same gate as the page: a file that is not a JSON object with schema
live/1 is not a projection. It is refused before anything is counted, so the
terminal can never paint a live Floor from a file the page would drop. A key
the projection lacks reads as the page reads it: the strip figures need a
summary, and a missing list is the same empty copy as an empty one.
"""

import argparse
import json
import os
import re
import select
import sys
import time
from datetime import datetime, timezone

WIDTH = 100
LINES = 60
DEFAULT_FILE = os.path.join("site", "experience", "data", "live.json")
ISO = "%Y-%m-%dT%H:%M:%SZ"

# Names the page uses for the checks, so "not checked" reads the same here.
CHECK_WORDS = {
    "critic_block": "critic verdicts",
    "ready_to_merge": "merge-ready PRs",
    "quiet_seat": "quiet seats",
    "failed_dispatch": "failed runs",
    "prd_proposed": "PRD sign-offs",
    "missing_variable": "repository variables",
}

# ANSI codes, applied only in colour mode and only around whole text runs.
ANSI = {
    "bold": "\x1b[1m",
    "dim": "\x1b[2m",
    "red": "\x1b[31m",
    "green": "\x1b[32m",
    "yellow": "\x1b[33m",
    "reverse": "\x1b[7m",
    "off": "\x1b[0m",
}
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


# ── time helpers, the same words as the page ───────────────────────────────


def parse_ts(value):
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def secs_between(later, earlier):
    a, b = parse_ts(later), parse_ts(earlier)
    if a is None or b is None:
        return None
    return max(0, int(round((a - b).total_seconds())))


def fmt_min(secs):
    """Plain-words durations for sentences: minutes, never 12m05s."""
    if not isinstance(secs, (int, float)) or secs < 0:
        return "-"
    s = int(secs)
    if s < 60:
        return "under a minute"
    if s < 3600:
        return "%d min" % round(s / 60)
    h, m = s // 3600, int(round((s % 3600) / 60))
    return "%d h %d min" % (h, m) if m else "%d h" % h


def fmt_ago(secs):
    """Ages floor, never round: at 101 s the line still reads 1 min ago."""
    if not isinstance(secs, (int, float)) or secs < 0:
        return "-"
    s = int(secs)
    if s < 60:
        return "%d s ago" % s
    if s < 3600:
        return "%d min ago" % (s // 60)
    return "%d h ago" % (s // 3600)


def plural(n, word):
    return "%d %s" % (n, word if n == 1 else word + "s")


# ── state, derived from last_event_ts like the page ────────────────────────


def live_state(d, now):
    """(state, age). Replay is forced by the projection's own watermark;
    live, stale and offline derive from last_event_ts against the
    projection's thresholds, never from the stored state alone."""
    replay = d.get("replay") or {}
    if d.get("view") == "replay" or replay.get("watermark") == "REPLAY":
        st = d.get("staleness") or {}
        age = st.get("seconds") if isinstance(st.get("seconds"), (int, float)) else None
        return "replay", age
    st = d.get("staleness") or {}
    stale_after = st.get("stale_after_s") or 120
    offline_after = st.get("offline_after_s") or 900
    last = parse_ts(d.get("last_event_ts"))
    if last is None:
        return (st.get("state") or "none"), None
    age = max(0, int((now - last).total_seconds()))
    if age >= offline_after:
        return "offline", age
    if age >= stale_after:
        return "stale", age
    return "live", age


def section_mark(state):
    if state == "replay":
        return " (REPLAY, history not the present)"
    if state == "stale":
        return " (stale, as of the last event)"
    if state == "offline":
        return " (offline, as of the last event)"
    return ""


def outcome_word(t):
    w = t.get("outcome")
    if w in ("landed", "failed", "aborted"):
        return w
    st = t.get("status")
    return "landed" if st == "settled" else "failed" if st == "failed" else "aborted"


# ── text fitting ───────────────────────────────────────────────────────────


def norm(text):
    """One line of text: whitespace runs collapsed, control characters gone."""
    return " ".join(str(text if text is not None else "").split())


def cut(text, limit):
    text = str(text if text is not None else "").replace("\n", " ").replace("\r", " ")
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    if limit <= 3:
        return text[:limit]
    return text[: limit - 3].rstrip() + "..."


def wrap(text, width=WIDTH, indent=""):
    words = norm(text).split()
    lines, cur = [], ""
    for w in words:
        cand = (cur + " " + w) if cur else w
        if len(indent) + visible_width(cand) > width and cur:
            lines.append(indent + cur)
            cur = w
        else:
            cur = cand
    if cur:
        lines.append(indent + cur)
    return lines or [indent]


def fit_row(parts, indent="  ", sep="  ", width=WIDTH, c=None):
    """One line from ordered parts. Each part is (text, flexible, colour,
    floor) or a plain string (fixed, no colour, floor 12). When the row is too wide the longest
    flexible part is shaved first, one character at a time, so the parts end
    up balanced instead of one of them vanishing; a fixed part is cut only
    when the flexible ones are down to their floor. Colour is painted after
    the layout, so the colour mode prints the same characters as the plain
    mode."""
    rows = []
    for p in parts:
        if isinstance(p, str):
            p = (p, False, None, 12)
        text, flex, code, floor = (p + (None, 12))[:4]
        text = norm(text)
        if text:
            rows.append([text, bool(flex), code, floor])
    if not rows:
        return indent

    def total():
        return len(indent) + sum(len(r[0]) for r in rows) + len(sep) * (len(rows) - 1)

    while total() > width:
        cands = [r for r in rows if r[1] and len(r[0]) > r[3]]
        if not cands:
            cands = [r for r in rows if len(r[0]) > 12]
        if not cands:
            break
        longest = max(cands, key=lambda r: len(r[0]))
        longest[0] = cut(longest[0], len(longest[0]) - 1)
    painted = [(c(r[0], r[2]) if c and r[2] else r[0]) for r in rows]
    return fit_visible(indent + sep.join(painted))


class Section:
    """A header, its rows, and a footer that grows when rows are trimmed. A
    row is one line, or a list of lines that stand or fall together (a
    wrapped row): the trim drops whole rows, never a continuation line."""

    def __init__(self, header, rows=None, footer_indent="  "):
        self.header = header
        self.rows = list(rows or [])
        self.hidden = 0
        self.footer_indent = footer_indent

    def lines(self):
        out = list(self.header) if isinstance(self.header, list) else [self.header]
        for r in self.rows:
            out.extend(r if isinstance(r, list) else [r])
        if self.hidden:
            out.append(self.footer_indent + "... and %d more not shown" % self.hidden)
        return out

    def trim_one(self):
        if len(self.rows) <= 1:
            return False
        self.rows.pop()
        self.hidden += 1
        return True


# ── the sections ───────────────────────────────────────────────────────────


def status_lines(d, state, age, c):
    """Status line. Stale, offline and replay are said in words before any
    number, then the counts the page's strip carries, same words."""
    summary = d.get("summary") if isinstance(d.get("summary"), dict) else None
    today = d.get("today") or []
    landed = sum(1 for t in today if outcome_word(t) == "landed")
    failed = sum(1 for t in today if outcome_word(t) == "failed")
    aborted = sum(1 for t in today if outcome_word(t) == "aborted")
    st = d.get("staleness") or {}

    if state == "replay":
        rp = d.get("replay") or {}
        seats = d.get("seats") or []
        moving = sum(1 for s in seats if s.get("status") == "running")
        done = sum(1 for s in seats if s.get("status") in ("success", "failed", "blocked"))
        where = ""
        if rp.get("as_of_seq") is not None:
            where = " at event %s of %s" % (rp.get("as_of_seq"), rp.get("total_events") or "?")
        head = c("REPLAY", "reverse") + ": history%s, not the present. No count of the present, no queue, no day." % where
        tail = "%s in motion at that point, %s settled." % (plural(moving, "seat"), done)
        return wrap(head) + wrap(tail)

    lead = ""
    if state == "stale":
        lead = c("Stale", "yellow") + ": no new event for over %s, so the counts are the last known state." % fmt_min(st.get("stale_after_s") or 120)
    elif state == "offline":
        lead = c("Offline", "red") + ": no new event for over %s, so everything below is history." % fmt_min(st.get("offline_after_s") or 900)
    elif state == "none":
        lead = "Idle: no event stream has been seen. Run a dispatch to put motion on the Floor."

    degraded = state in ("stale", "offline")
    # The figures are the page's strip: each one shows only when the
    # projection carries a summary, and running and up next only when the
    # summary states them. Without a summary the page hides every figure,
    # so the terminal prints none and says why, never a zero.
    figs = []
    if summary is None:
        figs.append("no counts: this projection carries no summary")
    else:
        if isinstance(summary.get("running"), int):
            figs.append("%d running%s" % (summary["running"], " at last event" if degraded else ""))
        if isinstance(summary.get("queued"), int):
            figs.append("%d up next" % summary["queued"])
        figs.append("%d landed" % landed)
        fig = ("%d failed, %d aborted" % (failed, aborted)) if aborted else "%d failed" % failed
        figs.append(c(fig, "red") if failed else fig)
        needs = summary["needs_you"] if isinstance(summary.get("needs_you"), int) else len(d.get("needs_you") or [])
        skipped = sum(1 for k in (d.get("needs_you_meta") or {}).get("checks") or [] if k.get("status") == "skipped")
        fig = "needs you: %d" % needs
        if skipped:
            fig += " (%s skipped)" % plural(skipped, "check")
        figs.append(c(fig, "red") if needs else fig)
    if age is not None:
        figs.append("last event " + fmt_ago(age))
    counts = ", ".join(figs)
    if lead:
        return wrap(lead) + wrap(counts)
    return wrap(counts)


def needs_ref(item):
    """The PR or comment reference as text; never a url, never a body. The
    text already names the seat, the branch and the repo, so the reference
    adds only what finds the source: the comment and its thread, the PR, the
    run, or the file and line."""
    src = item.get("source") or {}
    kind = src.get("kind")
    if kind == "comment":
        ref = "comment %s" % src["comment_id"] if src.get("comment_id") is not None else "comment"
        if src.get("issue"):
            return ref + " on issue %s" % src["issue"]
        if src.get("pr"):
            return ref + " on PR %s" % src["pr"]
        return ref
    if kind == "pr":
        return "PR %s" % (src.get("pr") or item.get("pr") or "?")
    if kind == "stream":
        return "run %s" % src.get("dispatch_id", "?")
    if kind == "file":
        return file_cite(src)
    if item.get("pr"):
        return "PR %s" % item["pr"]
    return ""


def file_cite(src):
    """The file and line, relative to the checkout, or nothing. An absolute
    path, a home path or a path that climbs out of the checkout is not a
    citation the terminal may print (section 6), so the action stands alone."""
    path = src.get("file")
    if not isinstance(path, str) or not path.strip():
        return ""
    path = path.strip()
    if os.path.isabs(path) or path.startswith("~") or ".." in path.split("/") or "\\" in path:
        return ""
    if path.startswith("./"):
        path = path[2:]
    line = src.get("line")
    return path + (" line %s" % line if line is not None else "")


def needs_section(d, state, c):
    mark = section_mark(state)
    header = c("NEEDS YOU", "bold") + mark
    if state == "replay":
        return Section(header, ["  Not shown on a replay: the past cannot ask for anything."])
    items = d.get("needs_you") or []
    meta = d.get("needs_you_meta") or {}
    skipped = [k for k in meta.get("checks") or [] if k.get("status") == "skipped"]
    rows = []
    for it in items:
        text = it.get("text") or it.get("type") or "item"
        action = it.get("action") or "look"
        ref = needs_ref(it)
        tail = action + (": " + ref if ref else "")
        if it.get("verified") is False:
            tail += " (unverified)"
        rows.append(fit_row([(text, True, None, 30), (tail, True, None, 52)], c=c))
    if not rows:
        if skipped:
            names = ", ".join(CHECK_WORDS.get(k.get("check"), k.get("check") or "check") for k in skipped)
            rows = wrap("Nothing found in the checks that ran; not checked: %s." % names, indent="  ")
        else:
            rows = ["  Nothing needs you."]
    elif skipped:
        names = ", ".join(CHECK_WORDS.get(k.get("check"), k.get("check") or "check") for k in skipped)
        rows.extend(wrap("Not checked: %s." % names, indent="  "))
    return Section(header, rows)


def seat_status(seat, state, now, last_event_ts):
    """The status sentence and the elapsed, both from timestamps the
    projection carries. Off a live stream both clocks stop at the last event
    and the sentence goes past tense, like the page."""
    nw = seat.get("now") if isinstance(seat.get("now"), dict) else {}
    degraded = state in ("stale", "offline")
    if nw.get("phase"):
        phase = nw["phase"] + (" with " + nw["program"] if nw.get("program") else "")
        sentence = ("was " if degraded else "") + phase
    else:
        sentence = "was at work" if degraded else "at work"
    wave = nw.get("wave") if nw else seat.get("wave")
    if isinstance(wave, int):
        sentence += ", wave %d" % wave + (" of %d" % nw["wave_total"] if isinstance(nw.get("wave_total"), int) else "")
    if degraded:
        elapsed = secs_between(last_event_ts, seat.get("started_at"))
    else:
        elapsed = secs_between(now.strftime(ISO), seat.get("started_at"))
        if elapsed is None:
            elapsed = nw.get("elapsed_s") if isinstance(nw.get("elapsed_s"), int) else seat.get("elapsed_s")
    # The quiet mark leads the sentence: when the row is shaved for width the
    # first clause survives, and the quiet mark is the one that must.
    if seat.get("quiet") is True and not degraded:
        hb = secs_between(now.strftime(ISO), seat.get("last_heartbeat_ts") or seat.get("started_at"))
        sentence = ("quiet for %s, " % fmt_min(hb) if hb is not None else "quiet, ") + sentence
    return sentence, (fmt_min(elapsed) + " in") if elapsed is not None else ""


def now_section(d, state, now, c):
    mark = section_mark(state)
    header = c("NOW", "bold") + mark
    seats = [s for s in d.get("seats") or [] if s.get("status") == "running"]
    if not seats:
        if state == "replay":
            return Section(header, ["  No seat in motion at this point of the replay."])
        if state in ("stale", "offline"):
            return Section(header, ["  No seat was live at the last event."])
        return Section(header, ["  No seat is live. The Floor shows motion only while a dispatch runs."])
    meta = {r.get("repo"): r for r in d.get("repos") or [] if r.get("repo")}
    groups = {}
    for s in seats:
        groups.setdefault(s.get("repo") or "unknown", []).append(s)

    def key(repo):
        m = meta.get(repo) or {}
        n = m.get("seats_live") if isinstance(m.get("seats_live"), int) else len(groups[repo])
        return (-n, repo)

    rows = []
    for repo in sorted(groups, key=key):
        m = meta.get(repo) or {}
        n_seats = m.get("seats_live") if isinstance(m.get("seats_live"), int) else len(groups[repo])
        n_disp = m.get("dispatches_live") if isinstance(m.get("dispatches_live"), int) else len(
            {s.get("dispatch_id") for s in groups[repo]})
        if state == "replay":
            counts = "%s, %s" % (plural(n_seats, "seat"), plural(n_disp, "dispatch"))
        else:
            qual = " at last event" if state in ("stale", "offline") else ""
            counts = "%s live%s, %s live%s" % (plural(n_seats, "seat"), qual, plural(n_disp, "dispatch"), qual)
        rows.append("  " + c(norm(repo), "bold") + ": " + counts)
        for s in groups[repo]:
            issue = s.get("issue") if isinstance(s.get("issue"), dict) else {}
            iss = "#%s" % issue["number"] if issue.get("number") else "no issue"
            if issue.get("milestone") and issue.get("lookup") == "verified":
                iss += " (" + issue["milestone"] + ")"
            task = s.get("task_line") or s.get("task") or "task line not on this machine"
            sentence, elapsed = seat_status(s, state, now, d.get("last_event_ts"))
            role = (s.get("now") or {}).get("role") if isinstance(s.get("now"), dict) else None
            role = role or s.get("agent") or "seat"
            rows.append(fit_row([s.get("repo") or "repo not reported", role, (iss, True, None, 12), (task, True, None, 28),
                                 (sentence, True, "yellow" if s.get("quiet") is True else None, 18), elapsed],
                                indent="    ", c=c))
    return Section(header, rows)


def queue_section(d, state, c):
    mark = section_mark(state)
    header = c("UP NEXT", "bold") + mark
    if state == "replay":
        return Section(header, ["  Not shown on a replay: a historical scrub carries no queue."])
    queue = d.get("queue") or []
    if not queue:
        return Section(header, ["  Nothing armed. The next dispatch is whatever the operator types."])
    rows = []
    for q in queue:
        issue = q.get("issue") if isinstance(q.get("issue"), dict) else {}
        iss = "#%s" % issue["number"] if issue.get("number") else "no issue"
        pos = "%s." % q.get("position", "?")
        purpose = q.get("purpose") or q.get("plan_basename") or "no purpose declared"
        blocked = q.get("blocked")
        tail = ("blocked: " + str(blocked), True, "yellow", 30) if blocked else "queued"
        rows.append(fit_row([pos, q.get("repo") or "repo not declared", (iss, True, None, 12),
                             (purpose, True, None, 30), tail], c=c))
    return Section(header, rows)


def initiative_facts(r):
    """The facts of one row in the page's words: waves landed of planned,
    open issues, last landed PR, the exit sentence."""
    bits = []
    waves = r.get("waves") if isinstance(r.get("waves"), dict) else {}
    if isinstance(waves.get("planned"), int):
        bits.append("wave %d of %d" % (waves.get("landed") or 0, waves["planned"]))
    if isinstance(r.get("open_issues"), int):
        bits.append(plural(r["open_issues"], "open issue"))
    ll = r.get("last_landed") if isinstance(r.get("last_landed"), dict) else {}
    if isinstance(ll.get("number"), int):
        bits.append("last landed #%d" % ll["number"] + (" " + ll["title"] if ll.get("title") else ""))
    if r.get("exit"):
        bits.append("exit: " + str(r["exit"]))
    if r.get("lookup") == "skipped":
        bits.append("streams and queue alone, milestone not verified"
                    + (" (%s)" % r["reason"] if r.get("reason") else ""))
    elif r.get("exit_lookup") == "skipped":
        bits.append("exit sentence not verified")
    return bits


def initiatives_section(d, state, c):
    """Section 4.5: one row per open milestone with recent activity, the
    same rows and the same empty copy as the page. The row flows like the
    page's (repo, title, then the facts) and wraps with a hanging indent
    rather than cutting the exit sentence, which is the answer to question 5.
    A row is never dropped; only the line budget may trim, and then the
    footer says how many."""
    header = c("INITIATIVES", "bold") + section_mark(state)
    rows = []
    for r in d.get("initiatives") or []:
        if not isinstance(r, dict):
            continue
        facts = initiative_facts(r)
        text = norm(r.get("repo") or "repo not reported") + "  " + norm(r.get("title") or "milestone")
        if facts:
            text += ": " + ", ".join(facts)
        lines = wrap(text, WIDTH - 2, indent="  ")
        rows.append([lines[0]] + ["  " + line for line in lines[1:]])
    if not rows:
        rows = ["  No open milestone with recent activity is known to this projection."]
    return Section(header, rows)


def today_row(t, c, red=False):
    repo = t.get("repo") or "repo not reported"
    word = outcome_word(t)
    dur = t.get("duration_s")
    what = word + (" after " + fmt_min(dur) if isinstance(dur, (int, float)) else "")
    pr = t.get("pr") if isinstance(t.get("pr"), dict) else {}
    pr_txt = ""
    if pr.get("number"):
        pr_txt = "PR %s" % pr["number"] + (" " + pr["title"] if pr.get("title") else "")
    purpose = t.get("purpose") or t.get("plan_basename") or "purpose not declared"
    return fit_row([repo, (purpose, True, None, 24), (what, False, "red" if red else None),
                    (pr_txt, True, None, 24)], c=c)


def today_sections(d, state, c):
    mark = section_mark(state)
    if state == "replay":
        return [Section(c("LANDED today", "bold") + mark, ["  Not shown on a replay: a historical scrub carries no day."])]
    today = d.get("today") or []
    failed = [t for t in today if outcome_word(t) in ("failed", "aborted")]
    landed = [t for t in today if outcome_word(t) == "landed"]
    out = []
    if failed:
        out.append(Section(c("FAILED today", "bold") + mark, [today_row(t, c, red=True) for t in failed]))
    out.append(Section(c("LANDED today", "bold") + mark,
                       [today_row(t, c) for t in landed] or ["  Nothing has landed today yet."]))
    return out


# ── the render ─────────────────────────────────────────────────────────────


def make_painter(colour):
    if not colour:
        return lambda text, _code: text
    return lambda text, code: ANSI[code] + text + ANSI["off"]


def render(d, now=None, colour=False, footer=None):
    """The whole screen as a list of lines: at most LINES, none over WIDTH
    visible columns (colour codes do not count)."""
    now = now or datetime.now(timezone.utc)
    c = make_painter(colour)
    state, age = live_state(d, now)
    head = status_lines(d, state, age, c)
    sections = [needs_section(d, state, c), now_section(d, state, now, c), queue_section(d, state, c),
                initiatives_section(d, state, c)]
    sections.extend(today_sections(d, state, c))
    budget = LINES - len(head) - len(sections) - (1 if footer else 0)  # blank line before each section

    def body_len():
        return sum(len(s.lines()) for s in sections)

    while body_len() > budget:
        longest = max(sections, key=lambda s: len(s.rows))
        if not longest.trim_one():
            break
    lines = list(head)
    for s in sections:
        lines.append("")
        lines.extend(s.lines())
    if footer:
        lines.append(c(footer, "dim"))
    return [fit_visible(line) for line in lines][:LINES]


def fit_visible(line):
    """Cut on visible width; colour codes stay whole or are dropped."""
    plain = ANSI_RE.sub("", line)
    if len(plain) <= WIDTH:
        return line
    if plain == line:
        return cut(line, WIDTH)
    return cut(plain, WIDTH)


def visible_width(line):
    return len(ANSI_RE.sub("", line))


# ── the loop ───────────────────────────────────────────────────────────────


def display_path(path):
    """Never print an absolute path: the path relative to here, else its name."""
    try:
        rel = os.path.relpath(path)
    except ValueError:
        rel = path
    if rel.startswith("..") or os.path.isabs(rel):
        return os.path.basename(path)
    return rel


class NotAProjection(ValueError):
    """The file parsed, but it is not a live/1 projection."""


def load(path):
    """The projection, or an exception. The gate is the page's
    (experience_build._load_live and floor.js renderAll): anything that is
    not a JSON object with schema live/1 is refused, never rendered."""
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        kind = {list: "array", str: "string", bool: "boolean", int: "number", float: "number"}.get(type(d), "null")
        raise NotAProjection("not a live/1 projection (a JSON %s, not an object)" % kind)
    if d.get("schema") != "live/1":
        raise NotAProjection("not a live/1 projection (schema %s)" % (json.dumps(d.get("schema")) if "schema" in d else "missing"))
    return d


def why(exc):
    """The one-line reason a file could not be shown."""
    return str(exc) if isinstance(exc, NotAProjection) else exc.__class__.__name__


def read_key(timeout):
    """Wait up to timeout seconds for a key on a tty stdin; return it or None."""
    try:
        r, _, _ = select.select([sys.stdin], [], [], timeout)
    except (ValueError, OSError):
        time.sleep(timeout)
        return None
    if r:
        return sys.stdin.read(1)
    return None


def watch(path, interval, colour, now_override):
    tty = sys.stdin.isatty()
    old = None
    if tty:
        try:
            import termios
            import tty as ttymod
            old = termios.tcgetattr(sys.stdin.fileno())
            ttymod.setcbreak(sys.stdin.fileno())
        except Exception:
            old = None
    footer = "refreshing every %d s, q quits" % interval
    try:
        while True:
            shown = display_path(path)
            try:
                d = load(path)
                lines = render(d, now_override, colour, footer=footer + ", " + shown)
            except FileNotFoundError:
                lines = ["No %s yet. Run make desk-live (or make desk-live-once) to write it." % shown, footer]
            except (OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
                # Every frame starts from a cleared screen, so a refused file
                # leaves no count of an earlier frame behind.
                lines = ["Could not read %s: %s" % (shown, why(exc)), footer]
            sys.stdout.write("\x1b[H\x1b[2J" + "\n".join(lines) + "\n")
            sys.stdout.flush()
            if tty and old is not None:
                key = read_key(interval)
                if key and key.lower() == "q":
                    return 0
            else:
                time.sleep(interval)
    except KeyboardInterrupt:
        return 0
    finally:
        if old is not None:
            import termios
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
            sys.stdout.write("\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="The Floor in the terminal: renders live.json as plain text.")
    ap.add_argument("--file", default=DEFAULT_FILE, help="the live.json the page reads (default %(default)s)")
    ap.add_argument("--once", action="store_true", help="print once and exit 0 (for scripting)")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between refreshes (default 5)")
    ap.add_argument("--color", "--colour", dest="colour", action="store_true",
                    help="add colour; the text is the same as the plain mode")
    ap.add_argument("--now", default=None, help="fixed clock (ISO 8601 UTC) for tests")
    args = ap.parse_args(argv)

    now_override = parse_ts(args.now) if args.now else None
    if args.now and now_override is None:
        sys.stderr.write("floor_tty: --now is not an ISO 8601 timestamp\n")
        return 2
    if args.once:
        try:
            d = load(args.file)
        except FileNotFoundError:
            sys.stderr.write("floor_tty: no %s yet. Run make desk-live (or make desk-live-once) to write it.\n"
                             % display_path(args.file))
            return 2
        except (OSError, ValueError) as exc:
            sys.stderr.write("floor_tty: could not read %s: %s\n" % (display_path(args.file), why(exc)))
            return 2
        sys.stdout.write("\n".join(render(d, now_override, args.colour)) + "\n")
        return 0
    return watch(args.file, max(1.0, args.interval), args.colour, now_override)


if __name__ == "__main__":
    sys.exit(main())
