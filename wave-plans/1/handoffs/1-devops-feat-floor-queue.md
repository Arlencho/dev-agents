# Ops Floor: block fix + two advisories (PR 68, branch feat/floor-queue)

## Built

Three commits, page sources only. `site/` is build output and was not committed.

1. `5f0898b fix(floor): move the Landed today note under the card head`
   `scripts/experience_build.py` (`_live_today_card`, teach shell),
   `templates/experience/floor.js` (`renderToday` comment).
   The note moved out of the `.cardhead .more` slot (which is
   `white-space: nowrap`) into `<p class="muted" id="floor-today-note">`
   under the head, the same shape `#floor-queue-note` already uses. The head
   keeps a short fixed label ("from the event stream"), so the nowrap slot
   only ever holds constant text. The client path writes into the same id,
   now a paragraph, so both paths land in the safe element.

2. `dbc29b2 fix(floor): qualify the still live count off a live stream`
   `scripts/experience_build.py` (`_live_today_card` takes `state`, called
   with the `state` `_live_floor_body` already computed),
   `templates/experience/floor.js` (`renderToday(d, st)`, `renderAll` passes
   the state it already has). Off a live stream the count reads
   "N still live at last event"; present tense survives only while live.

3. `200e97b fix(floor): stop the elapsed ticker when the stream is not live`
   `templates/experience/floor.js`. New module flag `elapsedLive`, false at
   boot, set from `renderAll`'s state, cleared on a non-ok response, a failed
   live fetch and a failed replay load. `tickElapsed` returns early when it is
   false, so the seat keeps the `elapsed_s` the projection reported.

## Decisions

- Moved the note rather than dropping `white-space: nowrap` from
  `.cardhead .more`. The nowrap is correct for the short fixed labels it was
  built for ("structure preview", "declared, not observed"); the bug was
  putting a variable length data driven string in it. No CSS change, so no
  other card shifts.
- Qualified rather than omitted the count. Omitting loses the fact that two
  dispatches were running when the stream went quiet; "at last event" keeps
  the fact and drops the present tense claim.
- `elapsedLive` starts false. A page loaded from the build snapshot has not
  confirmed anything yet, so it must not count up until a fetch says live.
- Freeze only, no dimming. The row already carries QUIET and the ambient line
  already says stale/offline, so a second visual channel was not needed.

## Evidence

Fixture is projected through the real `scripts/desk_live.py`, not hand written
JSON: 3 queued plans in a `fleet-queue/1` file, 2 live dispatches each with a
`seat_progress` line, 3 dispatches with `dispatch_end` today of which one is
`failed`. `AGE_S` shifts every timestamp back to age the projection.

```
python3 /tmp/floorfix/gen.py
python3 scripts/desk_live.py --once --events-dir /tmp/floorfix/events \
  --queue-file /tmp/floorfix/queue.json --out /tmp/floorfix/live.json
# live.json written: status=running, seats=2, view=live, staleness=live
# today_meta: streams_read 5, live [20260912-1700-delta, 20260912-1710-echo]
```

BLOCK 1, the critic repro at 400x900 with 2 dispatches live today
(`make experience`, copy live.json, rebuild, serve on 127.0.0.1, evaluate
`[scrollWidth, clientWidth]`):

```
before  scrollWidth 431  clientWidth 400   offender: span#floor-today-note (width 333, right 431)
after   scrollWidth 400  clientWidth 400   offenders: []   note is now p.muted
also    320x900 -> 320/320       1280x900 -> 1280/1280
```

Advisory 1, same projection aged three ways, server HTML and client repaint
agree in all three:

```
live    (30s)    ... 5 stream(s) read . 2 still live                  led live
stale   (300s)   ... 5 stream(s) read . 2 still live at last event    led stale
offline (1800s)  ... 5 stream(s) read . 2 still live at last event    led off
```

Advisory 2, seat timers sampled 3 seconds apart:

```
live    (30s)     20m36s -> 20m39s, 15m36s -> 15m39s   runs
stale   (300s)    25m00s -> 25m00s, 20m00s -> 20m00s   frozen
offline (1800s)   50m00s -> 50m00s, 45m00s -> 45m00s   frozen
live, data/live.json aborted at the route layer:
                  20m30s -> 20m30s, 15m30s -> 15m30s   frozen
```

Gates:

```
make experience                                  exit 0
python3 -m py_compile scripts/experience_build.py exit 0
node --check templates/experience/floor.js        exit 0
bash -n scripts/experience-build.sh               exit 0
./tests/run-experience-tests.sh                   exit 0   314 passed, 0 failed
./tests/run-desk-live-tests.sh                    exit 0   209 passed, 0 failed
```

## Do not repeat

- Do not put a data driven string in `.cardhead .more`. It is nowrap and it
  will overflow the moment the data gets longer. Use the muted paragraph.
- Do not read `staleness.state` straight from the projection for a liveness
  claim. It is projection time state; the page recomputes from
  `last_event_ts` (`_live_state` on the build side, `liveState` on the
  client), and that is the value to gate on.
- Do not measure the ticker with a fixture older than an hour: `fmtDur`
  collapses to `1h10m` and a one second change is invisible. Keep seat
  elapsed under 3600s when probing.
- `site/experience/` is gitignored build output. Editing it proves nothing.

## Open questions

None blocking. The head label "from the event stream" is a free choice; if the
critic prefers the queue card's phrasing ("declared, not observed") inverted,
it is a one line change and still fixed length.
