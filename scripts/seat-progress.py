#!/usr/bin/env python3
"""Seat progress reader: a live agent stream in, redaction-safe events out.

Sits in the launcher pipeline (providers/lib.sh run_and_classify):

    vendor CLI --output-format stream-json  |  seat-progress.py  |  tee <agent log>

Every byte read on stdin is written back to stdout unchanged, so the agent log
stays exactly what the CLI printed. On the side, the reader folds the stream
into four counts and emits a ``seat_progress`` event through the existing
emitter (``scripts/fleet-events.sh``) so the Ops Floor can say what the seat is
doing right now.

REDACTION LAW (docs/experience-data.md § Redaction law, do not weaken):
  What may leave this process
    - the tool name (e.g. Read, Edit, Bash)
    - one repo-relative path, when the tool targets a file
      (anything resolving outside the repo becomes the literal "outside-repo")
    - counts: files edited, commands run, tests run, commits made
    - one phase word: reading | reviewing | editing | testing | committing
    - the PROGRAM NAME of the last shell command: its first token only, with
      env assignments and sudo/nohup/time wrappers stripped, a path reduced to
      its basename, never an argument, and a basename shaped like a credential
      replaced by the literal word "redacted" before it is written
  What never leaves it
    - prompts, task bodies, assistant or user message text, thinking
    - tool argument values of any kind, including command lines
    - absolute paths, session ids, environment values

Command lines ARE inspected in-process (to tell a test run from a commit from
any other command) and are never emitted, not even truncated.

Env in (all optional; missing ones degrade to pure pass-through of the stream):
  FLEET_EVENTS_SH        path to scripts/fleet-events.sh (the only writer)
  FLEET_EVENTS_FILE      stream file the emitter appends to
  FLEET_DISPATCH_ID      dispatch id stamped on every event
  SEAT_TASK_ID           task id of this seat (matches seat_dispatch)
  SEAT_AGENT             role name of this seat
  SEAT_REPO_DIR          repo root used to make paths repo-relative (default cwd)
  SEAT_PROGRESS_INTERVAL_S  quiet-period emit floor in seconds (default 15)

Exit status is always 0: telemetry never fails a dispatch.
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

EMITTER = os.environ.get("FLEET_EVENTS_SH", "")
EVENTS_FILE = os.environ.get("FLEET_EVENTS_FILE", "")
TASK_ID = os.environ.get("SEAT_TASK_ID", "")
AGENT = os.environ.get("SEAT_AGENT", "")
REPO_DIR = os.environ.get("SEAT_REPO_DIR", "") or os.getcwd()
OUTSIDE = "outside-repo"

try:
    INTERVAL_S = float(os.environ.get("SEAT_PROGRESS_INTERVAL_S", "15") or 15)
except ValueError:
    INTERVAL_S = 15.0

# Tools that change files on disk: they drive files_edited.
EDIT_TOOLS = ("edit", "write", "multiedit", "notebookedit")
# Input keys that name a file. Only these ever yield a path; every other
# argument value is dropped on the floor.
PATH_KEYS = ("file_path", "notebook_path", "path")

# A command line matching these ran a test suite. Inspected, never emitted.
TEST_RE = re.compile(
    r"(^|[;&|(]\s*|\s)("
    r"pytest|py\.test|unittest|tox|nox"
    r"|jest|vitest|mocha|ava"
    r"|go\s+test|cargo\s+test|gradle\s+test|mvn\s+test|dotnet\s+test|rspec|bats"
    r"|(npm|yarn|pnpm|bun)\s+(run\s+)?test"
    r"|make\s+[a-z-]*test"
    r"|(bash\s+|sh\s+|\./)?tests?/[^\s]*"
    r"|[^\s]*run-[a-z0-9-]+-tests\.sh"
    r")",
    re.IGNORECASE,
)
COMMIT_RE = re.compile(r"(^|[;&|(]\s*|\s)git(\s+-[^\s]+)*\s+commit(\s|$)", re.IGNORECASE)

# Wrapper words that stand in front of the real program: skipped so the Floor
# says "make" instead of "sudo". Only these three, and only when they lead.
WRAPPERS = ("sudo", "nohup", "time")
# ``FOO=bar cmd``: the assignment is never the program, and its VALUE must not
# leave this process either, so the whole token is dropped.
ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# What a published program name may look like: one bare word. An option, a
# variable, a redirect or a subshell is not a program name and yields nothing.
PROGRAM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
PROGRAM_MAX = 40
# How many leading tokens are inspected for the program (assignments and
# wrappers included). A program buried deeper publishes nothing: fail-open,
# never a guess. Documented in docs/experience-data.md next to the table.
PROGRAM_TOKEN_SCAN = 8
# A basename can itself be a credential (``sudo ~/.ssh/ghp_...``). The token
# passes the same shaped-secret scrub the Almanac runs on everything it
# publishes (scripts/experience_data.py REDACTIONS, the shapes a single bare
# word can take) and a match is written as the literal word below, so the
# Floor learns that a command ran and never which. Kept as a copy on purpose:
# this reader sits in the launcher pipe and must not import the site builder.
SECRET_TOKEN_RES = [
    re.compile(r"(?i)\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,})"),
    re.compile(r"\bsk-[A-Za-z0-9\-_]{16,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
]
REDACTED = "redacted"


def program_name(command):
    """Program name of one shell command. First token only, never an argument.

    The reduction, in order:
      ``FOO=bar cmd``        env assignments are dropped, values included
      ``sudo|nohup|time cmd``leading wrappers are dropped
      ``./scripts/x.sh``     a token that looks like a path becomes its basename,
                             so no directory (inside or outside the repo) leaves
      anything else          only a bare word is published; an option (``-u``),
                             a subshell (``(cd``) or a variable yields ``None``
      a credential shape     a bare word that looks like a token or key is
                             written as the literal ``redacted``, whole, never
                             a truncated prefix of it

    Only the first PROGRAM_TOKEN_SCAN tokens are inspected. Returns None rather
    than a guess: the Floor would rather say nothing than print an argument.
    """
    if not isinstance(command, str) or not command.strip():
        return None
    try:
        tokens = shlex.split(command, comments=False, posix=True)
    except ValueError:
        # Unbalanced quotes: tokenising is not reliable, so publish nothing
        # instead of risking half an argument.
        return None
    for token in tokens[:PROGRAM_TOKEN_SCAN]:
        if not token:
            continue
        if ENV_ASSIGN_RE.match(token):
            continue
        if token.lower() in WRAPPERS:
            continue
        if "/" in token:
            token = os.path.basename(token.rstrip("/"))
        if not PROGRAM_RE.match(token or ""):
            return None
        if any(p.search(token) for p in SECRET_TOKEN_RES):
            return REDACTED
        return token[:PROGRAM_MAX]
    return None


def repo_relative(raw):
    """Repo-relative path, or the literal OUTSIDE marker. Never absolute.

    Paths are resolved against the repo root before the comparison so
    ``../../etc/hosts`` and ``/tmp/x`` both land on the marker instead of
    leaking an operator path into the stream.
    """
    if not raw or not isinstance(raw, str):
        return None
    try:
        root = os.path.realpath(REPO_DIR)
        target = raw if os.path.isabs(raw) else os.path.join(root, raw)
        target = os.path.realpath(target)
        relative = os.path.relpath(target, root)
    except (OSError, ValueError):
        return OUTSIDE
    if relative == os.curdir:
        return OUTSIDE
    if relative.startswith(os.pardir) or os.path.isabs(relative):
        return OUTSIDE
    return relative


class Progress(object):
    """Counts folded from the stream, plus the emitter throttle."""

    def __init__(self):
        self.edited = set()          # distinct repo-relative paths written
        self.commands = 0
        self.tests = 0
        self.commits = 0
        self.tool = None
        self.path = None
        self.program = None         # program of the LAST shell command, sticky
        self.last_emit = 0.0
        self.dirty = False
        self.emitted = 0

    def phase(self):
        """Phase word derived from the counts alone (a monotone ladder).

        It says how far the seat has got, not what its last keystroke was.
        """
        if self.commits:
            return "committing"
        if self.tests:
            return "testing"
        if self.edited:
            return "editing"
        if self.commands:
            return "reviewing"
        return "reading"

    def tool_call(self, name, tool_input):
        """Fold one tool call. Returns True when it should be emitted now."""
        if not isinstance(name, str) or not name:
            return False
        self.tool = re.sub(r"[^A-Za-z0-9_.-]", "", name)[:40]
        self.path = None
        args = tool_input if isinstance(tool_input, dict) else {}

        target = None
        for key in PATH_KEYS:
            value = args.get(key)
            if isinstance(value, str) and value:
                target = repo_relative(value)
                break
        self.path = target

        lowered = self.tool.lower()
        if lowered in EDIT_TOOLS:
            self.edited.add(target or OUTSIDE)
        elif lowered in ("bash", "bashoutput", "shell", "run", "terminal"):
            command = args.get("command")
            if isinstance(command, str) and command.strip():
                self.commands += 1
                # The program name is the only thing a command line contributes
                # to the stream. It replaces the previous one even when it
                # reduces to nothing, so the Floor never shows a stale program.
                self.program = program_name(command)
                if COMMIT_RE.search(command):
                    self.commits += 1
                if TEST_RE.search(command):
                    self.tests += 1
        self.dirty = True
        return True

    def fields(self):
        """The whole payload. Four counts, a tool, a path, a phase, a program."""
        out = [
            "phase=%s" % self.phase(),
            "files_edited=%d" % len(self.edited),
            "commands_run=%d" % self.commands,
            "tests_run=%d" % self.tests,
            "commits_made=%d" % self.commits,
        ]
        if TASK_ID != "":
            out.append("task_id=%s" % TASK_ID)
        if AGENT:
            out.append("agent=%s" % AGENT)
        if self.tool:
            out.append("tool=%s" % self.tool)
        if self.path:
            out.append("path=%s" % self.path)
        if self.program:
            out.append("program=%s" % self.program)
        return out


def emitting_enabled():
    return bool(EMITTER) and bool(EVENTS_FILE) and os.path.isfile(EMITTER)


def emit(progress):
    """Hand the payload to fleet-events.sh. Best effort, never raises."""
    if not emitting_enabled():
        progress.last_emit = time.time()
        progress.dirty = False
        return
    cmd = ["bash", EMITTER, "emit", "seat_progress"] + progress.fields()
    try:
        subprocess.call(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=dict(os.environ),
        )
    except Exception:
        progress.last_emit = time.time()
        return
    progress.last_emit = time.time()
    progress.dirty = False
    progress.emitted += 1


def tool_calls(event):
    """Yield (name, input) for every tool call in one stream line.

    Only the tool blocks are read. Text, thinking, and tool results are
    skipped without being touched.
    """
    if not isinstance(event, dict):
        return
    message = event.get("message")
    blocks = message.get("content") if isinstance(message, dict) else None
    if not isinstance(blocks, list):
        return
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "tool_use":
            yield block.get("name"), block.get("input")


def pump(stdin, stdout, progress):
    for raw in stdin:
        stdout.write(raw)
        stdout.flush()
        now = time.time()
        fired = False
        try:
            text = raw.decode("utf-8", "replace").strip()
            if text.startswith("{"):
                event = json.loads(text)
                for name, tool_input in tool_calls(event):
                    if progress.tool_call(name, tool_input):
                        emit(progress)
                        fired = True
        except (ValueError, TypeError):
            pass  # not a stream event; the log keeps it, the Floor ignores it
        if not fired:
            # A line arrived, so the seat is alive: refresh the same counts at
            # most once per interval. Tool calls above are never throttled.
            progress.dirty = True
            if (now - progress.last_emit) >= INTERVAL_S:
                emit(progress)
    if progress.dirty:
        emit(progress)   # closing counts, so the last phase is not lost


def main():
    stdin = getattr(sys.stdin, "buffer", sys.stdin)
    stdout = getattr(sys.stdout, "buffer", sys.stdout)
    progress = Progress()
    try:
        pump(stdin, stdout, progress)
    except KeyboardInterrupt:
        pass
    except Exception:
        # Never truncate the agent log because the reader tripped: fall back to
        # a dumb copy for whatever is left of the stream.
        try:
            shutil.copyfileobj(stdin, stdout)
            stdout.flush()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
