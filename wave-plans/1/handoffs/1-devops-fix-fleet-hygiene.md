# Handoff: fix/fleet-hygiene block-fix round (PR 67)

## Built

Four commits on `fix/fleet-hygiene`, one per review item:

- `7d578fd` `scripts/dispatch.sh`: `dispatch_wait_interruptible` (poll seat pid with `kill -0` in 1s
  slices, then `wait` for the exact status) and `dispatch_sleep_interruptible` (sliced fixed
  delays). Used by the wave wait, the retry wait and the retry backoff. Close-out traps moved into
  `dispatch_lock_arm_traps`; the `dispatch-lock:end` marker now sits after it so
  `tests/run-dispatch-lock-tests.sh` extracts the real trap code. Three signal tests added.
- `3d778f4`: both EXIT traps capture `dispatch_rc=$?` first and `exit "$dispatch_rc"`. Suite asserts
  a self-failed run keeps its own code (7).
- `5a4c39c`: lock path is now `${FLEET_HOME:-$HOME/dev}/dispatch-locks/<repo>.lock`, machine-global.
  README section rewritten. `logs/dispatch-locks/` ignore rule removed. Suite pins `HOME` to its
  sandbox and asserts the default path is outside the checkout.
- `4b5da01`: `handoff.md` untracked and gitignored.

## Decisions

- **`~/dev` is the per-user fleet base**, so the lock joins it. Evidence: `scripts/run-remote.sh:84`
  (`~/dev/agent-logs`), `:116` (`~/dev/<repo>`, the tree the lock protects), `:213`
  (`~/dev/agent-runtime`). The launchd jobs log to `~/Library/Logs` (`scripts/*-install.sh:12`),
  which is a log sink, not a state base, so it was not used for the lock.
- **The reported Ctrl-C leak was a harness artifact.** An async child of a non-interactive shell
  inherits SIGINT ignored, and a shell cannot trap a signal ignored at entry, so the INT trap never
  installed in that spawn shape (`trap -p INT` empty). The suite now restores the default INT/TERM
  disposition in `perl` before `setpgrp(0,0); exec`, so it measures `dispatch.sh`.
- **The genuine hole was the blocking `sleep`**: a direct SIGINT one second into `sleep 20` ran the
  trap 19.03s later. The retry backoff is 10s or 30s, so the lock outlived the cancel by that long.
  That case fails against the blocking primitives and passes after the change.
- Traps kept as a function rather than inline so the suite can arm the shipped trap code without the
  fenced block acquiring a lock at source time.

## Do not repeat

- Do not conclude "the INT trap never runs" from a harness that backgrounds the holder with `&` from
  a non-interactive shell. Reset the disposition first or the test measures itself.
- Do not assume bash loses the exit status through an EXIT trap: measured, 130 survives a trap body
  that ends in `false`, in bash 3.2 and 5.3. The rc capture is hardening, not a live bug fix, and
  the commit message says so.
- Do not put the lock under `LOGS_DIR`: that is per clone and serializes nothing across clones.

## Evidence

```
$ bash tests/run-dispatch-lock-tests.sh     -> 26 passed, 0 failed, exit 0
$ bash tests/run-launcher-tests.sh          -> 22 passed, 0 failed, exit 0
$ bash -n scripts/dispatch.sh               -> exit 0
$ bash -n tests/run-dispatch-lock-tests.sh  -> exit 0
$ shellcheck -S warning tests/run-dispatch-lock-tests.sh -> exit 0
$ make test                                 -> All test suites passed, exit 0
$ make lint                                 -> exit 0
```

`shellcheck -S warning scripts/dispatch.sh` reports 4 warnings (SC2095, SC2207, 2x SC2034); the same
4 exist on `main`.

## Open questions

- `DISPATCH_WAIT_SLICE_S=1` means one `sleep` process per second per waiting seat. Cheap, but if a
  wave ever runs dozens of seats it may be worth raising to 2s.
- Issue #66 (per-seat worktree) is still the real fix for within-wave sharing. Not touched here.
