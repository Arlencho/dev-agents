# Handoff: detached dispatch (branch feat/detached-dispatch)

## Built

- `scripts/dispatch.sh --detach`: forks a session leader (perl `fork` + `POSIX::setsid` + `exec`,
  stdin `/dev/null`, stdout/stderr to `logs/dispatch-runs/<id>.log`, HUP ignored), writes
  `<id>.pid` (pid, repo slug, plan, start ts) and `<id>.exit`, prints id/pid/log and returns.
  Child runs the attached path unchanged under the forced id (`DISPATCH_DETACHED`), implies
  `--auto`, colors off. `--review` runs before the fork; `--interactive` is refused.
- `scripts/dispatch-status.sh <id>`: running / final status, seat table from the events, last
  ten log lines. Exit 3 running, 0 ended, 2 unknown.
- `scripts/dispatch-wait.sh <id> [timeout]`: polls every 30 s (`DISPATCH_WAIT_POLL_S`), same
  summary, exit 0 ended / 3 timed out / 2 unknown.
- `scripts/queue-runner.sh` (+ `docs/queue-runner-launchd.plist`, install/uninstall scripts,
  make targets `queue-runner*`, `dispatch-detach`, `dispatch-status`, `dispatch-wait`,
  `queue-block`, `queue-unblock`): one start per tick, one run per repo, repo URL and flags from
  the plan's `# DISPATCH:` line, pause with `QUEUE_RUNNER_PAUSE=1`, log at
  `logs/dispatch-runs/queue-runner.log`. Unstartable plans are marked blocked with the reason.
- `scripts/queue.sh block <plan> <reason>` / `unblock <plan>`; render shows `blocked: ...`.
- README section "Detached dispatch", pointer in `docs/local-pr-sentinel.md`, flag lines in
  `docs/operator-guide.md`, `.gitignore` entry for `logs/dispatch-runs/`.
- `tests/run-detached-dispatch-tests.sh`, wired into `make test`.

## Decisions

- macOS has no `setsid` binary, so the detach is one perl call rather than `setsid nohup`; the
  parent gets the exact child pid from the fork (no pid-file race). Linux workers get the same
  path; no second code path to test.
- Busy-per-repo is decided from live pids (pid files + branch lock files), not from the queue's
  `running` status, so a killed attached run cannot wedge the runner forever.
- The runner blocks a plan it cannot start instead of retrying every minute; the reason shows in
  `make queue-list`.
- Draft PR, not merged, per the task.

## Do not repeat

- `dispatch.sh --help | grep -q` under `pipefail` returns 141 (SIGPIPE); capture the text first.
- Do not put `Co-Authored-By` / vendor trailers on commits or PRs in this repo.
- `ps -o sess` prints 0 on macOS; prove session leadership with `pgid == pid` and `tty == ??`.

## Evidence

- `bash -n` + `shellcheck -S warning` clean on every new script; pre-existing warnings only in
  `scripts/dispatch.sh` (unchanged lines).
- `plutil -lint docs/queue-runner-launchd.plist`: OK.
- `make lint`: OK. `make test`: all 13 suites pass; new suite 79 passed, 0 failed.
- Commit: see `git log -1` on `feat/detached-dispatch`.

## Next hint

- A tmp `git clone` of the committed branch running `tests/run-detached-dispatch-tests.sh` is the
  proof pasted in the PR body.
