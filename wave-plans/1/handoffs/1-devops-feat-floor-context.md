# Handoff: PR 74 data half, review fixes (feat/floor-context)

## Built

- `scripts/desk_live.py`
  - `task_path` (new) and `first_sentence`: slash tokens outside the worktree read `outside-repo`, inside paths print repo-relative; cut at the first sentence end whatever its length, else 120.
  - `attach_seat_context` factored out of `attach_context`; `attach_replay_context` (new) runs on the replay path of `build()` so replay seats carry repo, issue, task_line, pr.
  - `today_view`: live is no `dispatch_end` and started today or yesterday (local). `timedelta` imported.
- `tests/run-desk-live-tests.sh` Part J: the three review inputs, worktree/home/parent/file-URL path cases, replay seat context, overnight and stale dispatch fixture (14 new tests). Landing fixtures in Parts F, I, J clamp `ts()` at local midnight.
- `docs/experience-data.md`: `issue` in the fleet-queue/1 example and table; task_line path law; live predicate wording; replay seats keep the four fields.

## Decisions

- "Path inside the worktree" is structural, not an existence check: a relative token with no parent escape is kept (branch slugs like `feat/x` and `origin/main` appear in task lines and must survive). Absolute paths under REPO_DIR print relative. Same law as `activity_path`.
- The path scrub runs before the sentence cut so a dotted path segment cannot shift the cut.
- Live window is today plus yesterday, not "any stream with no end": a crashed stream from days ago must not be counted forever. `day_streams` still prefilters by mtime (48 h).
- Replay reads the queue file only to resolve plan paths; it publishes no queue/today/repos/summary.
- PR 74 left as draft: the critic issued BLOCK-FIX and re-review is pending; flipping to ready would expose it to the auto-merge sweep. Owner decision.
- Fixture midnight clamp added even though outside the four findings: the suite failed six pre-existing tests at 00:14 local on the untouched HEAD, and the CI gate would flake nightly in UTC.

## Do not repeat

- Do not try `git stash` based baselines while `_DAY_CACHE` matters: not relevant here (separate processes), but the six-failure baseline was time-of-day, not the diff.
- Do not add an existence check to `task_path`; it drops branch slugs.
- The now-view fixture helper at ~line 850 must NOT be clamped: its elapsed times feed sentence assertions.

## Evidence

- Commit `1b7e220887e43c69158a2f9990ef86279fe4e16a`, pushed to `origin/feat/floor-context`.
- `python3 -m py_compile scripts/desk_live.py` rc=0; `./tests/run-desk-live-tests.sh` rc=0 passed 309 failed 0; `make test` rc=0.
- `python3 scripts/desk_live.py --once` exit 0; `--once --replay` exit 0 (details in the PR comment).
- Review inputs: `'Push with [redacted] and write outside-repo now.'`, `'Go.'`, `'Project the sentence.'`.

## Open questions

- Plan header `purpose` goes through `scrub_text` only (no path law). Not flagged by the critic; same leak shape is possible if a header names a home path.
- Whether PR 74 should leave draft now or after the critic's second pass.
