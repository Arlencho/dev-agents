# Handoff: Floor page round two (PR #70, feat/floor-plain, e34eee2)

## Built

Page-side fixes for the frontend critic's four blocks, mirrored function for function in `templates/experience/floor.js` (polled repaint) and `scripts/experience_build.py` (build snapshot):

- **Block 1**: `renderSummary(d, st)` prints `st.age` from `liveState` (browser-computed from `last_event_ts`), the same clock as the meta line and state note. `_floor_summary_html(live, state, age)` prints the build-time value of the same clock.
- **Block 2**: top line, seat clause and the Now note all take the page state. Under stale/offline the top line appends `stream stale|offline` and qualifies `running at last event`; the phase clause goes past tense (`was testing with make`), elapsed freezes as `20 min in at the last event`, heartbeat reads `last heartbeat 48 s before the last event`.
- **Block 3**: Landed today prints `today[].outcome` (wave 1 field) with a status-map fallback for older projections. failed = `st st-fail`, aborted = `st st-warn`, landed = `st st-done`.
- **Block 4**: seat sentence split into `nowPurpose` (own `.nowpurpose` line) + `nowStatus` (short clause of nouns). Program reads `testing with make`, never `editing (node)`.
- Notes taken: `.trow` is now a grid with a fixed 6rem outcome column (`.tout`) that holds at 400px; one clock per fact, the seat elapsed lives once in the status clause as a `data-elapsed-min` span ticking in plain minutes; `fmtMin`/`fmtAgo` placeholders use `-` not the long dash.
- `templates/experience/site.css`: the `.trow` grid rules.

## Decisions

- Kept the mirrored JS/Python pairs identical instead of deduping: the contract is that the build snapshot and the polled repaint render the same page, and the two languages share no template layer. Said so in the PR comment.
- The elapsed clock moved out of `.nowhead` into the status clause for sentence rows (`data-elapsed-min="1"` makes `tickElapsed` use `fmtMin`). That is how "one clock per fact" was reconciled with the required `running 15 min` wording. Fallback rows (now=null, replay) keep the old header timer in `fmtDur`.
- "0 running at last event" on an idle offline projection is awkward but honest; left as is.
- PR left as draft per task. Issue #69 not touched (no status labels changed); the loop owner advances it.

## Do not repeat

- `make experience` step 1 (`experience_data.py`) wipes `data/`, including `live.json`: to test the build-time Floor renderer against a fixture, copy the fixture in and run `python3 scripts/experience_build.py --repo . --out site/experience` directly, not `make experience`.
- Degraded heartbeat wording: `fmtAgo(x) + " before the last event"` reads "48 s ago before the last event". Strip the suffix (`.replace(/ ago$/, "")` / `ago[:-4]`).
- No puppeteer/playwright here; headless Chrome via CDP over node's built-in WebSocket works: `/tmp/floor-cdp.js` (gone after reboot, recreate from the PR comment data if needed).

## Evidence

- `./tests/run-experience-tests.sh`: 314 passed, 0 failed. `./tests/run-desk-live-tests.sh`: 250 passed, 0 failed. `make experience` exit 0; `desk_live.py --once` exit 0; `experience_build.py` exit 0.
- Browser reads (headless Chrome, http server on `site/experience`, one 3 s poll in) at 1280 and 400, live/stale/offline fixtures + today's real streams: full strings in the PR comment on #70 (comment 5648064911). `scrollWidth === clientWidth` in every state at both widths.
- Real `failed` outcome confirmed on today's dispatch `20260912-173421` (1 of 1 seat failed) rendering red.

## Next hint

For the critic: the RED test should now pass; check the degraded heartbeat clause (`before the last event`, no "ago") and that the `.trow` grid holds the outcome column when a purpose wraps at 400. Loop 2 of 2.
