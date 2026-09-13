# Handoff: Floor in the terminal (feat/floor-terminal, Refs 72)

## Built

- `scripts/floor_tty.py`: renders `site/experience/data/live.json` (the file the page reads, never the streams) as plain text in the section 4 order: status line, NEEDS YOU, NOW by repo, UP NEXT, FAILED then LANDED today. At most 60 lines and 100 columns; refreshes every 5 s in place, `q` quits, `--once` prints and exits 0, `--color` adds colour without changing a character, `--now` pins the clock for tests, `--file` picks another projection.
- `Makefile`: `make floor` target (help comment, `FLOOR_FLAGS` pass-through), wired `tests/run-floor-tty-tests.sh` into `make test` after the desk-live suite.
- `tests/run-floor-tty-tests.sh` (66 checks) with `tests/fixtures/live/floor-v3.json` (a populated v3 projection: two repos live, a quiet seat, six NEEDS YOU items, a blocked queue row, landed, failed and aborted rows, plus planted stream paths, plan paths, log names and urls that must never print) and the pinned renders under `tests/fixtures/floor-tty/`.
- Docs: one line in `README.md` next to `make desk-follow`, a paragraph in `docs/experience.md` next to `make desk-live`.

## Decisions

- Branched from `origin/feat/floor-v3b` because v3-B (PR 80) is not on main yet; the PR body says so.
- State (live, stale, offline) derives from `last_event_ts` against the projection's thresholds, like the page, never from the stored `staleness.state`; replay is forced by the projection's own watermark.
- Rows are laid out by a fitter that shaves the longest flexible part first (with per-part floors) and paints colour after layout, so colour and plain modes print the same characters and nothing important vanishes first. The quiet clause leads the seat sentence so a width cut can never drop it.
- References print as text only (comment id and issue, PR number, run id, file and line inside the checkout); urls, stream paths, plan paths and log names are never printed.
- Replay: no counts of the present, no queue, no day, no "live" word; the REPLAY watermark is on the status line and every section header.

## Do not repeat

- Nesting a heredoc with the same delimiter inside a patch heredoc silently truncates the patch (zsh parse error, nothing applied).
- `echo ======` in zsh triggers `=cmd` expansion; use other separators.
- `cat` is aliased to `bat` in this shell; use `command cat` for `-v`.
- A test that greps for the long dash must build the pattern from code points or it matches itself.

## Evidence

- `./tests/run-floor-tty-tests.sh` exit 0, `floor tty: 66 passed, 0 failed`.
- `shellcheck -S warning tests/run-floor-tty-tests.sh` exit 0.
- `make floor FLOOR_FLAGS=--once` on a projection of the main checkout's four streams (read-only, `--events-dir`): exit 0, first line `Offline: no new event for over 15 min, so everything below is history.`
- `./tests/run-experience-tests.sh` exit 0 (354 passed), `./tests/run-desk-live-tests.sh` exit 0 (368 passed), `bash tests/critic/phase-b-honesty-repro.sh` exit 0 (6 passed).
- `make test` exit 2: stops at `tests/run-worktree-tests.sh` (94 passed, 6 failed, the two "two real dispatches" sections). Same suite on pristine origin/feat/floor-v3b: 96 passed, 4 failed, same section. Pre-existing, as PR 80 notes.
- `./tests/run-detached-dispatch-tests.sh` exit 1 (34 passed, 45 failed) with an identical ok/FAIL pattern on the pristine base: the environment, not the branch.
- Draft PR: https://github.com/Arlencho/dev-agents/pull/83 (base feat/floor-v3b, retarget to main after #80 merges). Commit 35f9edd.

## Open questions

- INITIATIVES (section 4.5) is not rendered; the task did not list it and the 60-line budget is tight. Easy to add as a sixth `Section` if wanted.
