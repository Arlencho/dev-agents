#!/usr/bin/env python3
"""Seat watchdog: run a vendor CLI, stop it when the model goes quiet.

Wraps the vendor CLI inside the launcher pipeline (providers/lib.sh
run_and_classify):

    seat-watchdog.py -- claude -p ...  |  seat-progress.py  |  tee <agent log>

Every byte the child prints is written back to stdout unchanged, so the agent
log stays exactly what the CLI printed. On the side the watchdog tracks the
timestamp of the last MODEL EVENT and, when no model event has passed for
SEAT_QUIET_AFTER_S seconds, kills the whole child process tree and exits 124
(EXIT_HUNG), so dispatch.sh can tell a hung seat apart from a failed one
(issue #92: three seats ran five hours on thinking-token ticks alone).

A model event is work the model actually did:
  - a stream-json line whose type is "assistant" or "user" (a tool result
    rides in a user event)
  - in plain-text output (kimi/grok), any line that is not a known ticker
Never a model event:
  - system lines (hook_started, hook_response, init, thinking_tokens)
  - rate_limit_event lines
  - spinner / wait tickers ("Waiting 0s / 10m", "background task still
    running"): a seat that only ticks is quiet by definition

The child runs in its own session so the quiet kill can take the whole tree
without touching the launcher. Signals aimed at the watchdog (a dispatcher
Ctrl-C reaches the pipeline's process group) are forwarded to the child tree
first, so no seat is orphaned.

Env in (all optional):
  SEAT_QUIET_AFTER_S      quiet period in seconds (default 1800; 0 disables:
                          the CLI is exec'd directly, no wrapper at all)
  SEAT_QUIET_POLL_S       how often the quiet check runs (default 5)
  SEAT_QUIET_KILL_GRACE_S TERM-to-KILL grace on a quiet stop (default 5)

Exit status: the child's own code, or 124 when the seat was stopped for
going quiet. Telemetry never masks the child's real exit.
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

EXIT_HUNG = 124
EXIT_UNAVAILABLE = 69


def env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


QUIET_AFTER_S = env_float("SEAT_QUIET_AFTER_S", 1800)
POLL_S = max(0.2, env_float("SEAT_QUIET_POLL_S", 5))
KILL_GRACE_S = max(0.2, env_float("SEAT_QUIET_KILL_GRACE_S", 5))

# Wait/spinner tickers of the text-mode CLIs: periodic proof of process life
# that says nothing about model progress. A seat emitting only these is hung.
TICKER_RES = (
    re.compile(r"\bWaiting \d"),
    re.compile(r"background tasks? still running"),
)


def is_model_event(raw):
    """True when one output line is work the model did, never a tick."""
    line = raw.strip()
    if not line:
        return False
    if line.startswith(b"{"):
        try:
            event = json.loads(line)
        except ValueError:
            # Real output that is not parseable stream-json: it came from the
            # model or a tool, so it counts (a hung seat emits parseable ticks).
            return True
        if isinstance(event, dict) and event.get("type") in ("assistant", "user"):
            return True
        return False
    text = line.decode("utf-8", "replace")
    for pattern in TICKER_RES:
        if pattern.search(text):
            return False
    return True


class Watchdog(object):
    def __init__(self, cmd):
        self.cmd = cmd
        self.proc = None
        self.last_event = time.monotonic()
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.killed_for_quiet = False

    def note(self, raw):
        if is_model_event(raw):
            with self.lock:
                self.last_event = time.monotonic()

    def quiet_for(self):
        with self.lock:
            return time.monotonic() - self.last_event

    def signal_child(self, sig):
        try:
            os.killpg(os.getpgid(self.proc.pid), sig)
        except (ProcessLookupError, PermissionError, OSError):
            pass

    def checker(self):
        while not self.done.wait(POLL_S):
            if self.proc.poll() is not None:
                return
            if self.quiet_for() < QUIET_AFTER_S:
                continue
            self.killed_for_quiet = True
            sys.stderr.write(
                "seat-watchdog: no model event for %ds; stopping the seat (exit %d)\n"
                % (int(QUIET_AFTER_S), EXIT_HUNG))
            sys.stderr.flush()
            self.signal_child(signal.SIGTERM)
            deadline = time.monotonic() + KILL_GRACE_S
            while self.proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            if self.proc.poll() is None:
                self.signal_child(signal.SIGKILL)
            return

    def run(self):
        try:
            self.proc = subprocess.Popen(
                self.cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                bufsize=0,
            )
        except OSError as exc:
            sys.stderr.write("seat-watchdog: cannot start %s: %s\n" % (self.cmd[0], exc))
            return EXIT_UNAVAILABLE

        # A signal aimed at the pipeline (dispatcher Ctrl-C, a supervisor
        # kill) must reach the child tree too, or the seat is orphaned.
        def forward(sig, _frame):
            self.signal_child(sig)
            self.done.set()

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, forward)

        watcher = threading.Thread(target=self.checker, daemon=True)
        watcher.start()

        out = sys.stdout.buffer
        child_out = self.proc.stdout
        while True:
            raw = child_out.readline()
            if not raw:
                break
            try:
                out.write(raw)
                out.flush()
            except (BrokenPipeError, OSError):
                # The log side is gone; keep supervising the child anyway.
                pass
            self.note(raw)

        rc = self.proc.wait()
        self.done.set()
        if self.killed_for_quiet:
            return EXIT_HUNG
        if rc < 0:
            return 128 + (-rc)
        return rc


def main(argv):
    cmd = list(argv)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        sys.stderr.write("usage: seat-watchdog.py -- <command...>\n")
        return 2
    if QUIET_AFTER_S <= 0:
        # Disabled: replace ourselves with the CLI, no wrapper semantics at all.
        try:
            os.execvp(cmd[0], cmd)
        except OSError as exc:
            sys.stderr.write("seat-watchdog: cannot start %s: %s\n" % (cmd[0], exc))
            return EXIT_UNAVAILABLE
    return Watchdog(cmd).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
