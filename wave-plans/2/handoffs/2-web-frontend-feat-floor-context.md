# Handoff: PR 74 replay block fix (feat/floor-context)

## Built

- `templates/experience/floor.js` (`renderNow`, was line 499): the NOW card
  head note now has a replay branch. `liveClaim` is empty when
  `st.state === "replay"`, so the head reads `N seats across M dispatches`
  instead of `N seats live across M dispatches`. Stale/offline still qualify
  with " at last event".
- `scripts/experience_build.py` (`_live_now_card`, was line 1276): same
  branch in the snapshot mirror; docstring updated to state the replay rule.
- Commit `314657a` pushed to `origin/feat/floor-context`.

## Decisions

- Followed the producer's own rule in `repoHeadCounts` /
  `_repo_head_counts` (drop the word "live" entirely under replay) rather
  than inventing new wording, per the critic comment on PR 74.
- Did not touch the "across M dispatches" half of the card head: the critic
  passed stale/offline as-is, and adding "live" to dispatches there would
  diverge from the wording already approved.
- "no seat is live" (empty case) left unchanged: with zero seats it is a
  true statement, not a liveness claim, and the repo header does not render
  in that case either.

## Do not repeat

- Do not re-derive the replay rule from `degraded` alone; `degraded` covers
  only stale/offline. Replay is a separate state from `liveState()`.

## Evidence

- `bash tests/run-experience-tests.sh`: 314 passed, 0 failed.
- `bash tests/run-desk-live-tests.sh`: 309 passed, 0 failed.
- `make experience`: rebuilds clean.
- Drove the real `floor.js` in Node with a stub DOM (/tmp/floor-note-harness.js)
  and the real `_live_now_card` in Python, synthetic projection with
  dev-agents 1 seat and olympus-platform 2 seats:

  floor.js polled path:
  - live:    card head `3 seats live across 2 dispatches`; repo head `2 seats live · 1 dispatch live`
  - stale:   card head `3 seats live at last event across 2 dispatches`; repo head `2 seats live at last event · 1 dispatch live at last event`
  - offline: card head `3 seats live at last event across 2 dispatches`; repo head `2 seats live at last event · 1 dispatch live at last event`
  - replay:  card head `3 seats across 2 dispatches`; repo head `2 seats · 1 dispatch`

  experience_build.py snapshot path prints the identical four lines.

## Open questions

- None blocking. The critic's non-blocking notes (shell strip above the h1,
  PR body still saying "the page is a separate PR") are owner's call.

## Next hint

- Critic: re-check only the card head against the first `.repohead` under
  REPLAY (the original repro: `python3 scripts/desk_live.py --once --replay
  --dispatch-id <settled id>`, rebuild, open the Floor). Everything else on
  the done-when list already passed and was not touched by this diff.
