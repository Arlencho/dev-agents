# Handoff: rebase feat/floor-terminal onto main (PR 83)

## Built
- Rebased feat/floor-terminal onto origin/main (90fe6d2) and force-pushed: 00b2d0b -> 4a72127.
- The four v3-A/v3-B commits already on main as squashes (#77 47767ce, #80 1cb8f78) were resolved by taking main's version of every non-terminal file and came out empty; skipped. The two terminal commits (4adbd6e, 4a72127) applied cleanly.
- Final diff vs main: 9 files, terminal-owned only (scripts/floor_tty.py, tests/run-floor-tty-tests.sh, tests/fixtures/floor-tty/*, tests/fixtures/live/floor-v3.json, Makefile floor target, README section, docs/experience.md section).
- Ran make experience (exit 0). Build output is under gitignored site/experience/ and no site files are tracked (git ls-files site/ is empty), so there was nothing from the build to commit.
- PR 83 body gained a "Rebase onto main (2026-09-13)" section with both verification commands and exit codes. PR was a draft; marked ready for review.

## Decisions (+why)
- Resolved conflicts with git checkout --ours (ours = the main side during rebase) then git rebase --skip, because every conflicting hunk belonged to v3-A/v3-B content whose final form already lives on main; keeping the branch copies would have resurrected stale pre-squash code.
- Main moved mid-rebase (d4a6a42 -> 90fe6d2, a wave-plan-only commit). Rebased a second time onto the new tip so the branch sits on current main; second rebase was clean.

## Do not repeat
- During a rebase, --ours is main and --theirs is the branch commit; do not invert.
- make experience writes only into gitignored site/experience/; do not hunt for build output to commit.

## Evidence
- ./tests/run-floor-tty-tests.sh -> "floor tty: 97 passed, 0 failed", exit 0 (commit 4a72127).
- make desk-live-once -> live.json written, exit 0; python3 scripts/floor_tty.py --once -> rendered idle floor (3 up next, 7 initiatives), exit 0.
- git diff origin/main --stat -> 9 files, 1510 insertions, 1 deletion, terminal-owned only.
- git push --force-with-lease -> + 00b2d0b...4a72127, exit 0.

## Open questions
- None blocking. If main moves again before merge, another trivial rebase may be needed.

## Next hint
- Critic: confirm the four skipped commits are truly byte-equivalent to main for the files they touched (compare 1cb8f78's tree against the pre-rebase branch 00b2d0b for scripts/desk_live.py, templates/experience/floor.js, site.css, experience_build.py, docs/experience-data.md, and the two test scripts), and that no v3-B regression fix was stranded.
