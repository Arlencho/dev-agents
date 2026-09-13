# Handoff: the orchestrator loop (feat/orchestrator-loop, wave 1)

## Built

- `scripts/queue_loop.py` (new): the judgment behind the runner in three subcommands the tick calls in order: `settle` (act on ended detached runs: one fix round on BLOCK-FIX, landing via land.sh when all critics safe + checks green + CLEAN, a stop otherwise; clears stops whose PR merged/closed or whose plan left the queue), `guard` (vm_stat + sysctl, thresholds from `config/queue-runner.yaml`, once-per-state-change logging, queue `hold`, stops file), `candidates` (queued + unblocked + AFTER satisfied; writes/clears `waiting` on the entry).
- `scripts/queue-runner.sh`: calls the helper (settle, guard, candidates), keeps every prior behaviour (pause, tick lock, busy detection, DISPATCH header parsing, block on failed start, one start per tick). Result lines from the helper land in `$TICK_LOCK/<sub>.out`; note/say lines are relayed.
- `scripts/desk_live.py`: verdict block copied byte-for-byte from `origin/feat/floor-v3a` (`first_line_verdict`, `critic_verdict`, `critic_record`, `latest_round`, `public_comment`, constants); `read_stops`, `read_queue_hold`; `queue[]` rows carry `blocked`/`waiting`, `queue_meta.hold`, `stops[]`, `stops_meta`; `parse_plan(full_task=True)`; `after|fix-round` added to the machine-header regex.
- `scripts/queue.sh`: `wait`, `hold`, `release` subcommands; render shows `hold:` and `waiting:`; same regex change.
- `scripts/dispatch.sh`: pid file line 5 = repo url (the runner asks gh about it after the run).
- `scripts/land.sh`: `LAND_REPO` / `LAND_ROOT` env overrides; prod probe only for the product repo.
- `config/queue-runner.yaml` (new), `scripts/queue-runner-install.sh --dry-run`, `make queue-runner-install-dry`, `make stops-list`, `.gitignore` for `logs/fleet-stops.jsonl`.
- Tests: `tests/run-queue-loop-tests.sh` (126 checks) + `tests/fixtures/loop/`; wired into `make test`.
- Docs: README "The loop", `docs/plan-file-format.md` § Header lines (DISPATCH, AFTER, FIX-ROUND), `docs/experience-data.md` (queue fields, stops schema), plist comment.

## Decisions

- Verdict parser lives in desk_live.py and is imported; it is not on main yet (floor-v3a PR 77 is a draft). Copied verbatim so whichever lands second resolves to one copy. Drop this copy when rebasing on a merged floor-v3a.
- "Free" = free + inactive + speculative + purgeable pages / hw.memsize (bare "Pages free" is meaningless on macOS, per the operator's memory note). Live reading at build time: 38 to 40 percent, so the 50 percent default holds every start on this machine today. Left the task's default in place; flagged in the PR.
- Guard fails open when neither vm_stat nor /proc/meminfo is readable (says so in the log). Fail-closed would silence the runner forever on a platform it does not target.
- A dispatch stop clears itself when its PR merges/closes or its plan is removed from the queue. dispatch.sh registers every plan it runs in the queue, so "plan gone" only happens on an explicit `queue rm`.
- Only detached runs (pid file) are settled; attached runs have a person at the terminal.
- BEHIND/DIRTY/BLOCKED merge states are stops (spec: anything but CLEAN). UNKNOWN and pending checks are transient: not marked, looked at again next tick.
- A BLOCK-FIX comment whose body carries BLOCK-ESCALATE or BLOCK-CLOSE anywhere is an escalate stop, never a fix round.
- Comments are only counted from the dispatch's `started_at` on, so yesterday's SAFE never lands today's PR.

## Do not repeat

- Do not run `make test` from inside a dispatched seat without unsetting `DISPATCH_DETACHED`, `DISPATCH_RUN_LOG`, `FLEET_DISPATCH_ID`: dispatch.sh --detach then thinks it is the child and never forks; the worktree suite's id globs never match. The three suites now unset these themselves.
- `tests/run-worktree-tests.sh` "two real dispatches" rows flake under load (load average 6+ with five live dispatches); rerun alone before believing a failure.
- `emit()` in queue_loop.py must keep tabs: scrubbing all control chars turned `cand<TAB>repo<TAB>plan` into spaces and every start silently failed with "plan file not found".
- macOS has no `timeout`; zsh treats a bare `=====` word as a path expansion.

## Evidence

- `./tests/run-queue-loop-tests.sh` -> `== 126 passed, 0 failed ==`, exit 0
- `./tests/run-detached-dispatch-tests.sh` -> `== 79 passed, 0 failed ==`, exit 0
- `./tests/run-worktree-tests.sh` -> `== 100 passed, 0 failed ==`, exit 0 (alone)
- `./tests/run-desk-live-tests.sh` -> `passed: 309   failed: 0`
- `make queue-runner-install-dry` -> plutil OK, exit 0
- `./scripts/queue-runner.sh --dry-run` against the live queue: guard active (free 40 percent of 32 GB, swap 2.4 GB), five repos busy via branch locks, exit 0
- shellcheck -S warning on queue-runner.sh, queue-runner-install.sh, land.sh, run-queue-loop-tests.sh: exit 0

## Open questions

- Threshold defaults: 50 percent free holds starts on the 32 GB machine at normal load. Owner to confirm or lower (config/queue-runner.yaml, no restart).
- land.sh for non-product repos: `LAND_ROOT` is set only when a checkout exists (dev-agents itself or `~/dev/<repo>/.git`); otherwise land.sh's default root is used for fetch and sweep.

## Next hint

Wave 2 (verdict vocabulary in every critic role) can point at `docs/plan-file-format.md` § Header lines and README "The loop" for the runner's side of the contract: BLOCK-FIX fires one fix round, BLOCK-ESCALATE/BLOCK-CLOSE stop, SAFE-TO-MERGE/APPROVE-MERGE may land.
