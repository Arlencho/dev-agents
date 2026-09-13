# Handoff: PR 75 round two (feat/per-seat-worktrees)

## Built
- Kept both wip commits (490c4e9, 52c5d35): pid suffix on the dispatch id, fixed-code failure learnings, classifier drops prompt-echo lines, detached fetch point, cp-then-rename in remote_put, suite rows and docs.
- scripts/run-remote.sh: the fetch point refreshes local main fast-forward only (merge-base guard before `git branch -f`), so an unpushed seat commit on main is kept.
- tests/run-worktree-tests.sh: row "an unpushed local main commit reaches origin under the seat's".
- PR body rewritten where it still said the fetch point is parked on main; round-two section with evidence.

## Decisions
- Dispatch id uniqueness uses the dispatcher pid, not nanoseconds: `date +%N` is not portable to macOS and the pid is already what run-remote uses for direct runs.
- Classifier fix subtracts prompt lines from the output tail rather than changing the shim: a real CLI that echoes or quotes its prompt would hit the same misclassification.
- No attribution trailer or footer on the commit or PR: shared-repo rule in the task and the repo README.

## Do not repeat
- A local main that is ahead of origin is not "diverged": `merge --ff-only origin/main` succeeds silently, so do not assert the diverged warning for that case.
- The 490c4e9 CI failure (seat a exit 1, one worktree mid-run) was the GNU cp O_EXCL race in remote_put, not a worktree bug; 52c5d35 fixed it.

## Evidence
- tests/run-dispatch-lock-tests.sh: 32 passed, 0 failed, exit 0
- tests/run-launcher-tests.sh: 35 passed, 0 failed, exit 0
- tests/run-worktree-tests.sh: 100 passed, 0 failed, exit 0
- bash -n, shellcheck -S warning on every touched script: exit 0; actionlint .github/workflows/test.yml: exit 0
- Same-second proof (two real dispatch.sh runs): ids 20260913-080707-product-67854 and 20260913-080707-product-67857, two runtimes and two event files alive at once, both exit 0, no runtime left, fetch point detached.
- Proof script kept at /tmp/pr75/same-second-proof.sh (local machine only).

## Next hint
- Wait for the Fleet unit tests check on the pushed head, then answer the critic comment with the run link.
