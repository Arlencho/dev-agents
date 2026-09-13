# Handoff: Floor plain round 2, block 2 (PR 70, feat/floor-plain)

## Built

Closed the last open block from the round-2 frontend critic report, plus both
not-blocking notes. Commit `9a4d37c`, pushed to `feat/floor-plain`, PR 70 left
as draft, evidence pasted as a PR comment.

- `templates/experience/floor.js`: new `secsBetween(laterTs, earlierTs)`;
  `nowStatus` now takes `(now, st, seat, lastEventTs)` and under stale/offline
  computes elapsed as `last_event_ts - seat.started_at` and heartbeat as
  `last_event_ts - seat.last_heartbeat_ts`; `nowRow`/`renderNow` thread
  `d.last_event_ts` through. `fmtAgo` floors instead of rounding.
- `scripts/experience_build.py`: mirror changes (`_secs_between`,
  `_now_status(now, state, seat, last_event_ts)`, call site passes the seat and
  `live.get("last_event_ts")`; `_fmt_ago` floors).
- `templates/experience/site.css`: `.tlist > li.trow` grid is now
  `minmax(0, 1fr) 6rem 6rem`; the timer column no longer sizes to its text, so
  the outcome word's right edge is stable across rows.

## Decisions (+why)

- Compute from timestamps rather than dropping the clauses: the projection
  already carries everything, and the clause keeps its information value
  (elapsed at the last event is a real fact, not a guess). If either timestamp
  is missing or unparsable the clause drops instead of printing a
  projection-time number; honesty rule already used elsewhere on the page.
- Live path untouched: while the stream is live the projection is fresh, so
  `now.elapsed_s` / `now.heartbeat_age_s` stay the source and the elapsed span
  keeps ticking from `started_at` in the browser.
- Only `fmtAgo`/`_fmt_ago` changed to floor, not `fmtMin`/`_fmt_min`: the
  critic's note was about the age formatter disagreeing with the LED threshold
  between 90 and 119 s. `fmtMin` is a duration in a sentence, not an age
  against a threshold, and the expected "15 min in" comes out of
  round(890/60)=15.
- Timer track is 6rem because the longest value `fmtMin` prints is
  "under a minute" (14 mono chars at 11px, about 92px). Anything longer
  right-aligns and overflows left into the column gap, so it can never push
  the page sideways; verified no horizontal scroll at 400px with that exact
  value present.

## Open questions

- My verification fixture has no plan file on disk, so the sentence reads
  "wave 2" rather than the critic's "wave 2 of 3" (`wave_total` joins from the
  plan header, untouched here). The critic's own fixture had one; if their
  re-run shows "wave 2 of 3" that is the plan join working, not a regression.
- `fmtMin` still rounds. If a future report wants durations floored too, that
  is a separate, deliberate change.

## Do not repeat

- Chrome 152 on this machine (`--headless --dump-dom`) renders and writes the
  DOM but never exits, even for a `data:` URL, and `--virtual-time-budget`
  does not save it. Workaround in `/tmp/floor-verify/run.sh`: launch in
  background, poll the output file for the marker, then kill. Each read costs
  about 2 s this way.
- `desk_live.py --dispatch-id` wants the full filename stem
  (`verify-300-dev-agents`), not the short id, or the projection silently
  comes back `status=idle` with no seats.
- The Landed `duration_s` in `today[]` comes from the `dispatch_end` event,
  not from `seat_exit`. A fixture without `duration_s` on `dispatch_end`
  renders "-" timers.
- Fixture timestamps are wall-clock relative: generate, project and read in
  one command or a live fixture quietly becomes an offline one while you
  debug something else.

## Evidence

- `./tests/run-experience-tests.sh`: exit 0, 314 passed 0 failed.
- `./tests/run-desk-live-tests.sh`: exit 0, 250 passed 0 failed.
- `make experience`: exit 0.
- Fixture: `seat_dispatch` 890 s before the last event, heartbeat 5 s before,
  projected with the real `desk_live.py --once`, newest event 8/300/1800 s
  old, read in headless Chrome at 1280 and 400 on both render paths. Pasted
  from the browser (full JSON per read in the PR comment):
  - stale: `1 running at last event · 1 up next · 3 landed today · last event 5 min ago · stream stale`
    / `devops, was testing with make, wave 2, 15 min in at the last event, last heartbeat 5 s before the last event.`
  - offline: `... last event 30 min ago · stream offline` / same sentence.
  - live: `last event 14 s ago` / `running 15 min, heartbeat 13 s ago.`
- `scrollWidth === clientWidth` in all 12 reads (1265/1265, 485/485).
- `.tout` right edges identical across rows (1057/1057/1057 px at 1280,
  329/329/329 px at 400) with timers "under a minute", "7 min", "12 min".

## Next hint

For the critic: the RED script `/tmp/fc-floor2/red2.sh` should now pass both
assertions on both mirrors; the numbers no longer move with projection time.
The two not-blocking notes are also done, so a re-measure of the outcome
column at 400px and a 90 to 119 s age sample are the quickest confirmations.
This was loop 2 of 2, so any remaining item is a CTO call, not another round.
