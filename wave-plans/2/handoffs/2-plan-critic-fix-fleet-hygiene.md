# Handoff: fix/fleet-hygiene (PR #67)

## Built

**FIX A, one local dispatch at a time.** `scripts/dispatch.sh` takes a per-repo lock before the
first wave, but only when a worker host is `localhost` / `127.0.0.1`.

- Lock file: `logs/dispatch-locks/<repo>.lock` (under the `LOGS_DIR` the script already uses),
  gitignored next to `logs/provider-state/`. Contents: holder pid, plan path, start timestamp.
- Blocked run prints one line naming the holder pid and the plan it is running, then queues with
  a heartbeat line every 60s, or exits `9` with the new `--no-wait` flag.
- Released on normal exit, on `set -e` abort, and on INT / TERM / HUP. Stale lock (owner pid gone)
  is cleared and taken over.
- `--no-wait` documented in the file header, `usage()`, and the README dispatch section.
- `tests/run-dispatch-lock-tests.sh` (new, 15 assertions, wired into `make test`).

**FIX B, the catch-all role exit.** `providers/kimi/launch.sh` and `providers/grok/launch.sh`
resolve the charter explicitly; `roles/claude.md` added (plus the `make sync` copy in
`providers/claude/agents/`). Rows 15 and 16 added to `tests/run-launcher-tests.sh`.

Issue #66 opened for the per-seat worktree redesign; referenced from the lock comment in
`dispatch.sh` as the real fix.

## Decisions

- **Lock scope is localhost-only.** Remote workers have their own machines and their own
  checkouts, so a lock there would serialize the fleet for no reason.
- **Lock lives in `logs/dispatch-locks/`, not `logs/provider-state/`.** Same log directory the
  script already uses, but rate-cap state and dispatch locks have different lifetimes; mixing
  them would make the cooldown files harder to reason about.
- **`--no-wait` exits 9, not 1.** A wrapper needs to tell "another dispatch is running" apart
  from "this dispatch failed".
- **Lock block is fenced with `dispatch-lock:begin` / `:end` markers** so the test suite can
  source the real code instead of restating it. Same trick `run-roster-tests.sh` uses on
  `flow.sh`'s `CRITIC_OF`.
- **The catch-all seat gets a real `roles/claude.md`** rather than a per-launcher special case,
  so every dispatched role name resolves to a file. `model: sonnet` matches `routing.yaml`'s
  `default`, which is what the roster test's frontmatter-vs-routing invariant requires. The
  explicit-resolution guard in the launchers stays anyway: it is the part that keeps a missing
  charter from becoming a command.

## Do not repeat

- **The reproduction command as given exits 0 and always will on that path.**
  `bash ~/dev/agent-runtime/launch.sh claude print the word ok and stop` runs whichever launcher
  the last dispatch shipped into `~/dev/agent-runtime/`. When that is the name-resolving one, it
  never reads `roles/` and cannot hit the bug. The real evidence is in the fleet log, not in a
  fresh run: `~/dev/agent-logs/olympus-platform-fix-claude-1789206249-20260912-114430.log`.
- **`~/dev/agent-runtime/` is shared mutable state, same as the checkout.** Every dispatch
  overwrites `launch.sh` and `roles/` in place while other seats may be executing that exact
  file, and `roles/` still holds leftovers from earlier seats (`devops.md`, `docs-writer.md`,
  `frontend-critic.md`, `plan-critic.md`, `web-frontend.md`). A torn read of that file is a
  plausible second route to the same line-33 error. Noted in issue #66; not fixed here.
- **There is no `scripts/task-worktree.sh` in this repo.** The per-task worktree rule is an
  olympus-platform policy. Work happened in the dispatched checkout on the task branch.
- **`shellcheck` will not stop warning about `[ cond ]; check ... $?`** (SC2319). Use a helper
  that takes the command (`check_true "name" test -f "$path"`) instead of chasing `$?`.
- **Do not pipe `dispatch.sh --help` into `grep -q`** in a test: `usage()` exits 1 and the early
  pipe close turns into exit 141. Capture the output into a variable first.

## Evidence

```
$ sed -n '120p' scripts/run-remote.sh
WORK_DIR="\$HOME/dev/$REPO_NAME"
$ sed -n '245,262p' scripts/run-remote.sh        # per seat, inside that one tree
cd "$WORK_DIR" ; git fetch origin ; git checkout main ; git pull origin main ; git checkout "$BRANCH"

$ tail -1 ~/dev/agent-logs/olympus-platform-fix-claude-1789206249-20260912-114430.log
/Users/arlenrios/dev/agent-runtime/launch.sh: line 33: =/Users/arlenrios/dev/agent-runtime/roles/claude.md: No such file or directory

$ cd ../olympus-platform && bash ~/dev/agent-runtime/launch.sh claude print the word ok and stop
REPRO EXIT CODE: 0          # before and after; see Do not repeat

$ ROLES_DIR=<empty> bash /tmp/oldstyle.sh claude     # the logged shape, reconstructed
/tmp/oldstyle.sh: line 6: =/.../claude.md: No such file or directory
old-style path exit: 127
$ ROLES_DIR=<empty> bash providers/kimi/launch.sh claude "print the word ok and stop"
kimi exit: 0  stderr: WARNING: no charter for role 'claude' under <dir>, running without a role charter
$ ROLES_DIR=<empty> bash providers/grok/launch.sh claude "print the word ok and stop"
grok exit: 0  stderr: WARNING: no charter for role 'claude' under <dir>, running without a role charter

$ bash -n scripts/dispatch.sh providers/kimi/launch.sh providers/grok/launch.sh \
         tests/run-dispatch-lock-tests.sh tests/run-launcher-tests.sh     # all clean
$ shellcheck -S warning tests/run-dispatch-lock-tests.sh                  # clean
$ make lint     # Summary: 0 added, 0 updated, 19 unchanged, 2 not-owned, 0 drift ; workers.yaml OK
$ make test     # all suites pass: launcher 22/22, dispatch lock 15/15, roster 59/59, ...
```

Commits: `7ae58dc` (FIX A), `33c2d6f` (FIX B). PR #67, issue #66.

## Open questions

- The lock does nothing for two seats in the *same* wave, which is the common case. Until #66
  lands, a wave with two seats on the same repo still shares one working tree.
- `~/dev/agent-runtime/` per-dispatch isolation is folded into #66 but could be split out: it is
  a much smaller change than the worktree work and removes the torn-launcher failure mode on its
  own.

## Next hint

If #66 is picked up: `scripts/run-remote.sh:120` (`WORK_DIR`), `:245-262` (the checkout block),
`:285` (push), and `:330-345` (the ledger's git queries) are the four places that must all move
to the seat worktree together. The handoff copy at `:365-380` reads `handoff.md` from the repo
root and moves with them.
