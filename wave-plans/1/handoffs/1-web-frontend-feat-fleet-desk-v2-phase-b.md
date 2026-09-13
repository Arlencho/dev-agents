# Handoff — Fleet Desk v2 Phase B, OPS FLOOR UI (web-frontend seat)

Task: wire `/live/` to the real `live/1` projection ([SYNTHESIS §3 Phase B](docs/proposals/fleet-desk-v2-SYNTHESIS.md))
on `feat/fleet-desk-v2-phase-b`, after the data path landed. Supersedes the Phase B data-path
handoff (devops seat, branch `feat/fleet-desk-v2-phase-b-data`, merged in as `ef00cd9`).

## Built

| File | What |
|------|------|
| `scripts/experience_build.py` | `Renderer._load_live()` reads `<out>/data/live.json` (only `schema == "live/1"`, else `None`). `live_page()` is now one skeleton with two fill states: `_live_shell_body()` (Phase A teach shell, unchanged assertions) and `_live_floor_body()` — ambient LED (live/stale/offline from `staleness.state`), waiting-on strip, pipeline counts, Wave lanes grouped by wave + ghost lanes from `seats_planned − len(seats)`, Conductor spine (`spine-node hot/done`) when `mode=conductor`, hierarchy context (Repo/Mission from `repo`/`plan`, Company honestly `—`), redaction-safe event tail (last 12, newest first). `_home_live_teaser()` mirrors the snapshot. `page()` gained an optional `script` param; `write_assets` also ships `floor.js`. |
| `templates/experience/floor.js` **(new)** | ~150-line stdlib-free poller, loaded only by `/live/` with `data-live-json="../data/live.json"`. Re-reads the projection every 3 s and repaints LED/waiting/counts/lanes-or-spine/event tail in place; recomputes staleness from `last_event_ts` vs the projection's own thresholds. Fetch failure (`file://`, server down) → build snapshot stays untouched. |
| `templates/experience/site.css` | Live-state classes only: `.led.live/.stale` (+ pulse, killed by the existing reduced-motion rule), `.st-run`, `.lane.run`, `.vendor.warn`, `.spine-node.done/.hot`, `.wavehead2`, `.waiting .witem`, `ol.events`. |
| `tests/fixtures/live/{wave,conductor}.json` **(new)** | Synthetic `live/1` projections (deterministic staleness baked in — no wall-clock dependence). Wave: ratecap→failover→settled seat + running seat + 1 ghost (seats_planned 4 vs 3). Conductor: done/done/hot spine + open human gate + STALE state. |
| `tests/run-experience-tests.sh` | Phase B block after the shell pins: wave fixture (LED, waiting, counts, lanes, rate-cap/failover chrome, ghost, wave grouping, hierarchy, event tail, poller wiring, home teaser), conductor fixture (spine hot/done, STALE LED, human gate, no wave lanes), degradation (malformed JSON → shell; removed JSON → teach shell restored, no live chrome). |
| `docs/experience.md` | "Ops Floor (Phase A shell)" → "Ops Floor"; documents what the wired floor renders, the poller, and the `file://` degradation path (`desk-live-once` + rebuild). |

## Decisions (+why)

- **Builder trusts stored `staleness.state`; JS recomputes from timestamps.** The static page is
  labeled a snapshot of `live.json` at build time — re-deriving staleness at build would make the
  fixtures wall-clock-nondeterministic. The poller recomputes continuously, so served pages go
  STALE/OFFLINE on their own. Honesty is preserved by the label + live correction.
- **One skeleton, two fill states, poller on both.** The shell carries the same region ids
  (`floor-led`, `floor-waiting-items`, `pipe-*`, `floor-mode-body`, `floor-events`), so a page
  opened before `make desk-live` starts still lights up without a rebuild; the teach previews sit
  inside `#floor-mode-body` and are honestly replaced when real data arrives.
- **Ghost lanes only when `seats_planned > len(seats)`** — the stream never names unstarted seats,
  so ghosts carry no agent/branch, only "plan seat · queued". No invented seats.
- **Company stays `—` in floor hierarchy.** The `live/1` stream carries repo/plan but never a
  company join; inventing one was the exact M5 violation pinned in Phase A. Mission level shows the
  plan filename, not a guessed issue.
- **No `experience_data.py` / schema v2 touch** — live state reads from `data/live.json` only;
  `index.json` is never contaminated (SYNTHESIS §3.5 law).

## Do not repeat

- Don't expect `make experience` to refresh the floor during a dispatch — the static snapshot is
  build-time only. Auto-refresh path is `make desk-live` (poller over http), not rebuilds.
- Don't put wall-clock-derived assertions in the fixtures; bake `staleness` into the JSON.
- `site/experience/` is gitignored — a local `data/live.json` left behind by `desk_live.py --once`
  changes what Part B of the experience suite renders (assertions are written to pass either way,
  but don't be surprised).

## Evidence

- `./tests/run-experience-tests.sh` → `== 290 passed, 0 failed ==` (was 265 pre-Phase-B; +25 new pins).
- `make test` → `All test suites passed.` (incl. `run-desk-live-tests.sh` 81/81 from the data branch).
- `node --check templates/experience/floor.js` → syntax OK.
- E2E: `desk_live.py --port 8779` over `tests/fixtures/fleet-events/wave-run.jsonl` → `/live/` serves
  the floor, `/data/live.json` returns `live/1 running offline seats 3` (fixture is 11 h old →
  honestly OFFLINE), SSE `/events` streams `event: live`. Server stopped, temp dir removed.
- Production data layer untouched: `git diff main..HEAD -- scripts/experience_data.py` → empty;
  `SCHEMA_VERSION = 2` unchanged.

## Open questions / next hint (critic)

- Python and JS render the same regions in two languages (by design: static snapshot + live
  repaint). Check the mirror sites for drift: `_seat_pill`/`seatPill`, `_seat_lane`/`seatLane`,
  `_live_spine`/`renderSpine`, waiting-on item markup.
- The floor hierarchy shows plan filename at the Mission level; joining repo/plan → real mission
  (issue) was rejected as invention-prone. Accept or propose a stream-carried `mission` field
  (schema `live/1` extension) — that is a data-contract discussion, not a UI one.
- Pre-existing Phase A quirk (not introduced here): every page renders both the `page()` default
  hierarchy strip and its body-embedded custom one. Out of scope for Phase B; flag if it should
  become a cleanup task.

---

# CRITIC VERDICT — Fleet Desk v2 Phase B (loop 1)

**VERDICT: REVISE** — 2 executable failures + 1 surviving mutation. Repro: `bash tests/critic/phase-b-honesty-repro.sh` (RED on `99e9fee`: 1 passed, 5 failed).

Scope check first: `make test` is green (81/81 desk-live, 290/290 experience), `make desk-live` and
`make desk-live-once` exist and work, `index.json` is uncontaminated, and the redaction law holds.
The two defects below are honesty laws the PR states about itself, not style opinions.

## D1 — The build-time floor reports a dead run as LIVE (major)

Law broken: `scripts/desk_live.py:19` — *"a stream that stopped updating reads STALE, then OFFLINE — never 'live'"*.

`scripts/experience_build.py:1006,1027,1029` (floor) and `:1190` (home teaser) copy
`staleness.state` verbatim out of `live.json` instead of deriving it from `last_event_ts` at build
time. `templates/experience/floor.js:44-55` does derive it (*"trust timestamps over the stored
snapshot state"*). That is mirror drift — the exact class of bug this handoff's own "Open questions"
section asks the critic to look for.

Same run, both renderers, today:

```
  stored staleness (tests/fixtures/live/wave.json): live     3 s | last_event_ts 2026-07-29T10:20:02Z
  desk_live.py now                                : offline 39325 s | last_event_ts 2026-07-29T10:20:02Z
```

Reproduced end to end with a `live.json` written by `desk_live.py` **3 days ago** and left in
`site/experience/data/` (which `clean_html` deliberately preserves, and which this handoff's
"Do not repeat" already notes gets left behind). Rebuilding today renders:

```
<span class="led live" id="floor-led">                     <- green LED
<strong>running</strong> - dispatch 20260726-090000-...    <- no " · stream offline" note (suppressed at :1027)
last event 4s ago                                          <- the last event was 3 days ago
<span class="st st-run">in flight</span><span class="timer">4s   <- a seat "in flight" since Sunday
```

Two reasons the stated mitigation ("labeled snapshot + the poller corrects it") does not hold:

1. **The home teaser has no poller.** `floor.js` is injected only by `live_page()`; `grep -rl floor.js`
   over a built site returns `live/index.html` only. So `index.html` renders
   `<span class="st st-run">live</span> dispatch 20260726-...` permanently — it cannot self-correct
   even when served by `make desk-live`. "Poller on both" is not what ships.
2. **On `file://` the snapshot is the whole product.** `floor.js:9-10` documents that a blocked
   `fetch` leaves the build snapshot on screen "untouched" — and `make experience-open` opens
   `file://`. The designed fallback is the lying page.

The suite pins the defect rather than catching it: `tests/run-experience-tests.sh:422` asserts
`class="led live"` for a fixture whose `last_event_ts` is now ~11 h old, and gets more false every
day. Line 411 of that same file already treats `led live` as the marker of invented live state.

The stated blocker ("re-deriving staleness at build would make the fixtures wall-clock-nondeterministic")
is refuted inside this PR: `tests/run-desk-live-tests.sh:249-267` generates relative-time fixtures
precisely so staleness can be asserted honestly. Mechanism is the producer's call — not prescribing one.

## D2 — Ctrl-C never closes the stream (medium)

Law broken: `scripts/dispatch.sh:543` — *"Honest close-out even on Ctrl-C / early exit: the Floor
must never show a run that is still 'running' after the dispatcher is gone."*

`dispatch.sh:554` wires `fleet_close_dispatch` to `EXIT` only. A non-interactive bash script killed
by SIGINT dies from the signal without running its EXIT trap. Measured on a harness that replays
dispatch.sh's own trap line into a script shaped like the inter-wave gate (`dispatch.sh:1024`):

```
SIGINT  -> close-out: NONE - Floor keeps showing status=running forever
SIGTERM -> close-out: dispatch_end status=aborted
```

Ctrl-C at a wave gate is the ordinary way an operator stops a dispatch, so the common abort path is
the uncovered one. `dispatch_end` is then never written, `project()` leaves `status=running`, and
every seat keeps its in-flight pill (the `unknown` downgrade at `desk_live.py:337-341` is gated on
`out["status"] != "running"`, so it never fires). Staleness still degrades on a served floor — but
combined with D1 a rebuilt page shows a green live LED for a run the operator killed days ago.

## Surviving mutation

| # | Mutation | Suite result |
|---|----------|--------------|
| M1 | Delete `trap 'fleet_close_dispatch aborted' EXIT` (`dispatch.sh:554`) | **81/81 green — survives** |

Part C of `run-desk-live-tests.sh:292-315` is grep-only (`grep -qE "fleet_event $ev"` across
dispatch.sh + the emitter), so no assertion executes the dispatch close-out path. Load-bearing
controls verified by contrast: removing the `latest` pointer write, the `unknown` downgrade, the
`seat_log` basename, or the staleness thresholds each turns the suite RED.

## Verified good (no action)

- **Event stream** — JSONL envelope, monotonic `seq`, UTC-Z timestamps, numeric-key typing, 200-char
  cap, control-char flattening, non-snake keys dropped, plan as basename, logs as basenames. No
  transcript or task text: `grep 'fleet_event' scripts/dispatch.sh | grep -E 'TASK_DESC|\$task|\$desc'` -> empty.
- **`FLEET_EVENTS=0`** — `fleet_events_init` returns before `mkdir`; no dir, no file, no pointer.
  An unwritable dir degrades to a silent no-op instead of killing the dispatch.
- **Background-subshell safety** — measured: bash resets traps in `( ) &`, so the seat subshells at
  `dispatch.sh:766` do not each fire a spurious `dispatch_end`. `bash -n` clean.
- **`live/1` schema** — `waiting_on` (human gates first, then rate-caps, then the slowest running
  seat), `seats`, `mode`, `staleness` with published thresholds, counts, `wave`, redaction-safe tail.
  Atomic `os.replace` write. No absolute paths or token-shaped strings.
- **`make desk-live`** — smoke-tested on port 8791: `/live/` 200 text/html, `/data/live.json` ->
  `live/1 running offline seats=1` (the server recomputes staleness correctly — only the builder does
  not), `/events` streams `event: live`, bound to `127.0.0.1` only.
- **No fake agents** — no stream -> `status=idle`, `seats=[]`, `staleness.state=none`; no `live.json`
  -> Phase A teach shell restored verbatim; malformed or off-schema `live.json` -> shell, never half-chrome.
- **`index.json` untouched** — `scripts/experience_data.py` not in the diff; the built contract carries
  none of `live|seats|waiting_on|staleness|recent_events|dispatch_id|in_flight`; `join_rules`,
  `pmi_policy`, `critic_pairs` intact.

## What acceptance looks like

`bash tests/critic/phase-b-honesty-repro.sh` green without weakening its assertions, plus M1 killed
(the close-out path needs one executing assertion, not a grep). Then wire the repro into `make test`.
Both defects sit in `experience_build.py` staleness derivation and one trap line — no redesign, and
nothing in the data contract or the event schema needs to move.

Loop 1 of 2. One more batch after the revision, then CTO.


---

# CRITIC VERDICT - Fleet Desk v2 Phase B (loop 2)

**VERDICT: REVISE** - 1 blocking defect confirmed and still uncommitted, 1 new blocking regression
introduced by the in-flight fix, 3 surviving mutations. Loop-1 defect **D2 is withdrawn as a false
positive** (proof below); its follow-on comment in `dispatch.sh` now asserts something untrue about
bash and should be corrected.

Repro (both states measured):

```
bash tests/critic/phase-b-honesty-repro.sh
  committed tip ffb6c38          -> 2 passed, 4 failed     (R1 real)
  working tree (revision applied) -> 6 passed, 0 failed
```

## State of the branch when this review ran

`origin/feat/fleet-desk-v2-phase-b` = `ffb6c38`. The working tree carried **uncommitted** edits to
`scripts/dispatch.sh` and `scripts/experience_build.py` (the loop-1 revision, in flight). Nothing
below is a style opinion; every item is a measured failure or a surviving mutation.

## B1 - D1 confirmed, and the fix is not on the PR (blocking)

Loop-1 D1 is correct. Verified independently against the committed tip in a clean clone:

```
live.json written by desk_live.py during a run 3 days ago:
  staleness.state = live   staleness.seconds = 4   last_event_ts = 2026-07-26T21:29:12Z
rebuilt today at ffb6c38:
  <span class="led live" id="floor-led">      green LED
  last event 4s ago                            the last event was 3 days ago
  home teaser: <span class="st st-run">live</span> dispatch 20260726-...
```

The fix in the working tree (`_live_state()`, `experience_build.py:794-816`, deriving live/stale/
offline from `last_event_ts` against the projection's own published thresholds, stored state used
only as fallback when the timestamp is missing or unparseable) is the right shape: it mirrors
`floor.js:45-56` and it makes the teaser honest, which matters because the teaser has no poller.
Rebuilt with it, the same 3-day-old projection renders `led off` / `71h59m ago` / teaser `offline`.

**Blocking because it is uncommitted and unpushed.** A reviewer or merger of `ffb6c38` gets the
lying page. Commit it.

## B2 - The fix as written turns `make test` red (blocking, new)

Requirement "make test green including desk-live suite" fails once B1 lands. Measured in clean
clones of the same commit, differing only by the uncommitted files:

```
committed ffb6c38                      -> 290 passed, 0 failed
ffb6c38 + working-tree experience_build.py -> 287 passed, 3 failed
```

The three:

```
FAIL floor LED reads live from the projection
FAIL home teaser reflects live.json when present
FAIL conductor floor reads STALE chrome
```

Root cause: `tests/fixtures/live/wave.json` and `conductor.json` carry absolute `last_event_ts`
values plus a baked `staleness.state`, and the suite asserts the LED from that stored state. Once
the renderer derives state from wall-clock, every fixture ages into `offline`.

Do not resolve this by reverting the derivation. The producer's stated blocker in "Decisions"
("re-deriving staleness at build would make the fixtures wall-clock-nondeterministic") is a false
dichotomy: give `_live_state` an injectable `now` (default `datetime.now(timezone.utc)`) and have
the build honor a pinned value in tests, or generate the fixtures relative to now the way
`tests/run-desk-live-tests.sh:249-267` already does. Determinism and honesty are both available.
Mechanism is the producer's call.

## D2 withdrawn - Ctrl-C already closed the stream (false positive)

Loop-1 D2 claimed `dispatch.sh:554` (EXIT-only trap) never closes the stream on Ctrl-C. That is
wrong, and the loop-1 evidence table contains the tell: SIGTERM closed out while SIGINT did not. If
bash really skipped EXIT traps on signal death, SIGTERM would have failed too.

The real cause is the harness, not `dispatch.sh`. The loop-1 repro backgrounded the harness with `&`.
An async command in a non-interactive shell inherits SIGINT as `SIG_IGN` (POSIX 2.11), and bash
cannot trap a signal ignored at entry, so no handler can ever fire:

```
bash child started with &, then `trap ... INT`:
  trap -p INT  => trap -- '' SIGINT        <- ignored, untrappable
  trap -p TERM => trap -- 'echo ...' SIGTERM  <- real handler (hence the asymmetry)
```

Under real Ctrl-C conditions (foreground child, SIGINT at default disposition), replaying
`dispatch.sh`'s own trap lines:

```
                                  SIGINT during `read` gate   SIGINT during `wait`
  99e9fee (EXIT trap only)        EXIT trap RUNS, exit 130    EXIT trap RUNS, exit 130
  working tree (EXIT+INT+TERM)    EXIT trap RUNS, exit 130    EXIT trap RUNS, exit 130
```

Consequences to action:

1. `tests/critic/phase-b-honesty-repro.sh` R2 was structurally incapable of passing. **Fixed in this
   commit** (harness now runs in the foreground, with the measurement recorded inline). It passes on
   `99e9fee` and on the revision, so it is now a real regression guard rather than a permanent red
   landmine. It was never wired into `make test`; wire it once B1 and B2 are green.
2. `scripts/dispatch.sh:554-558` (working tree) now carries the comment *"A non-interactive bash
   killed by SIGINT/SIGTERM dies from the signal without running its EXIT trap"*. That is false on
   both counts, as measured above. Keep the `INT`/`TERM` traps if you want the close-out ordering
   explicit (they are harmless and make `exit 130/143` deliberate), but correct the comment. A false
   claim in a load-bearing script is worse than no comment: the next reader will build on it.
3. Loop-1's surviving mutation M1 still stands: deleting the close-out trap leaves the suite green,
   because Part C of `run-desk-live-tests.sh` is grep-only. The new `INT`/`TERM` traps are likewise
   unasserted. The corrected R2 block above is one executing assertion for that path.

## Surviving mutations (new this loop)

Ran against the committed tip; `desk_live.py` and `fleet-events.sh` are identical in both states.

| # | Mutation | Suite result |
|---|----------|--------------|
| M5 | Fabricate a seat when the stream has events but no seat events (`desk_live.py:334`) | **81/81 green - survives** |
| M8 | Drop `os.path.basename` on `seat_log` (`desk_live.py:302`) so an absolute path reaches `live.json` | **81/81 green - survives** |
| M9 | Remove the `latest`-pointer containment guard `"/" not in name` (`desk_live.py:110`) | **81/81 green - survives** |

All three are correct code with no test holding them down. M5 matters most: "no fake agents when no
stream" is an acceptance criterion, and the only assertion covering it (`no live seats invented`)
runs on a fixture that already has seats, so the events-without-seats path is unpinned. The honest
behavior does exist today (measured: a stream with `dispatch_start` + `wave_start` and no seats
projects `seats=0` and renders "Dispatch reported no seats yet"); it is simply unguarded.

Load-bearing controls verified by contrast (each turns the suite RED): staleness thresholds,
the `unknown` downgrade for a seat that never reported, the `FLEET_EVENTS=0` opt-out, the `latest`
pointer write, numeric-key typing, and leaking task text into a `fleet_event` call.

## Non-blocking

- **Offline snapshot still shows an in-flight seat.** With B1 applied, the 3-day-old projection
  renders ambient `stream offline` next to `<span class="st st-run">in flight</span>` and
  `timer 4s` in the same page. The page contradicts itself. `desk_live.py:337-341` already has the
  right idea (a `running` seat downgrades to `unknown` when the dispatch is not running); the
  build-time renderer could apply the same neutralization when `_live_state` returns `offline`.
- **Mirror drift is the root cause of B1, and it is structural.** The floor is rendered twice, once
  in Python for the build snapshot and once in JS for the poller: `_fmt_dur`/`fmtDur`,
  `_live_state`/`liveState`, `_time_of`/`timeOf`, `_seat_pill`/`seatPill`, `_seat_timer`/`seatTimer`,
  `_seat_lane`/`seatLane`, `_ghost_lane`/`ghostLane`, `_live_lanes`/`renderLanes`,
  `_live_spine`/`renderSpine`, `_live_events`/`renderEvents` (`experience_build.py:782-941` vs
  `templates/experience/floor.js:29-215`). Ten mirrored pairs, and the code admits it in comments at
  `experience_build.py:802,827`. D1 was exactly this drift: the JS derived staleness, the Python
  copied it. Two of the ten have now diverged and been re-synced by hand. Worth a follow-up task to
  pick one source of truth (either let `floor.js` own lanes/spine/tail and keep the build snapshot to
  ambient plus counts, or generate both from one description). Not a Phase B blocker, and explicitly
  not a redesign demand here.
- **`_live_shell_body` is 85 lines** (`experience_build.py:943-1027`), mostly one HTML literal, over
  the ~50-line guideline. Low priority while it stays a single flat template.

## Verified good (no action)

- **Event stream and opt-out.** Default run writes `logs/fleet-events/<id>.jsonl` plus a `latest`
  pointer holding the basename; `FLEET_EVENTS=0` produces no directory, no file, no pointer, and
  leaves `FLEET_EVENTS_FILE` empty so every later call is a silent no-op. Numeric keys typed, values
  capped and control-char stripped, non-snake keys dropped, empty values omitted, plan and logs as
  basenames only. No transcript or task text: injecting `task="..."` into the `seat_dispatch` call
  turns the suite RED.
- **`live/1` schema.** Both fixtures carry `schema`, `seats`, `mode`, `staleness` (with published
  `stale_after_s`/`offline_after_s`), `waiting_on`, `counts`, `status`, `last_event_ts`,
  `dispatch_id`. `waiting_on` orders human gates first, then rate-caps, then the slowest running
  seat. Written atomically via `os.replace`.
- **`/live/` honesty without a projection.** No `live.json` restores the Phase A shell verbatim:
  `led off`, "no live run in this build", "This is the empty shell", all four pipeline counts as
  em-dashes, zero occurrences of any agent or provider name, and the poller still attached so it
  lights up when a run starts. Malformed or off-schema `live.json` degrades to the same shell.
- **`make desk-live`** (`Makefile:37`), `experience-live` (`:40`), `desk-live-once` (`:42`) all exist
  and run; `desk-live-once` emitted a valid `live/1` projection end to end. The desk-live suite is
  wired into `make test` (`Makefile:105-107`).
- **`index.json` uncontaminated.** `scripts/experience_data.py` is not in the diff. The built
  contract contains none of `live/1`, `staleness`, `in_flight`, `waiting_on`, `fleet-events`, or
  `dispatch_id`, and `join_rules`, `pmi_policy`, `critic_pairs`, `companies`, `trails` are intact.
- **Background-subshell safety.** Measured: bash resets traps in `( ) &`, so the seat subshells emit
  no spurious `dispatch_end`. Exactly one close-out line per run.
- **Escaping.** Both renderers route interpolated stream values through `esc()`, and the event tail
  whitelists `ts`/`event`/`task_id`/`agent`/`provider` rather than dumping raw event objects.

## What acceptance looks like

1. Commit and push the `_live_state` derivation (B1).
2. Make `make test` green with the derivation in place, without weakening the honesty assertions:
   inject `now` or generate fixtures relative to now (B2).
3. Correct the `dispatch.sh` signal comment (D2 item 2).
4. Optional but cheap, and the reason the mutations survived: one assertion each for M5, M8, M9,
   then wire `tests/critic/phase-b-honesty-repro.sh` into `make test`.

Loop 2 of 2. The next pass goes to CTO for ship / redesign / kill, not to another critique round.


---

# PRODUCER REVISION — Fleet Desk v2 Phase B (loop 2, web-frontend seat)

Answers loop-2 acceptance B1–B2, D2-item-2, M1, and the optional M5/M8/M9 pins. Repro green,
`make test` green, critic repro now wired into `make test`.

## Built

| File | What |
|------|------|
| `scripts/experience_build.py` | **B1**: new `Renderer._live_state()` derives live/stale/offline from `last_event_ts` at build time against the projection's own `stale_after_s`/`offline_after_s` (default 120/900) — mirrors `floor.js liveState` and `desk_live.py`; stored `staleness.state` is only the fallback when the timestamp is missing/unparseable. `_live_floor_body` uses it for LED, `· stream <state>` note, and the `last event … ago` age (no longer `staleness.seconds`). `_home_live_teaser` uses it too (teaser has no poller — derivation is the whole product there). |
| `scripts/dispatch.sh` | **D2**: `fleet_close_dispatch` now wired to EXIT + INT + TERM (`exit 130`/`143` in the signal handlers; guard makes double-fire a no-op); success path clears all three. Comment corrected per loop-2 — it no longer claims bash skips EXIT traps on signal death (measured false on bash 3.2 and 5.3); the traps exist to make close-out ordering and exit codes explicit, not to fix a bash defect. |
| `tests/run-experience-tests.sh` | **B2**: Phase B block reworked. Fixtures keep their old absolute timestamps and now assert OFFLINE (`led off`, `· stream offline`, teaser `st-unk">offline`) — never `led live`. Live/stale chrome is pinned on wall-clock-shifted copies of the wave fixture generated at test time (last_event at now → `led live` + teaser live; now−200s → `led stale`), stored state deliberately left claiming `live` so green can only come from derivation. |
| `tests/run-desk-live-tests.sh` | **M1**: executing close-out tests in Part C — dispatch.sh's real trap lines replayed into a harness: (a) plain `exit 3` → exactly one `dispatch_end status=aborted` (kills "delete the EXIT trap": measured, suite goes 87/1 RED); (b) SIGINT at a `read` gate → exactly one close-out (foreground launch, see below); plus an explicit INT/TERM wiring grep pin. **M5/M8/M9**: stream with no seat events → `seats==[]`; `seat_log` with an absolute path → basename only in live.json; `latest` pointer containing `/` → not followed outside the events dir. |
| `Makefile` | `tests/critic/phase-b-honesty-repro.sh` wired into `make test` after the desk-live suite. |
| `docs/experience.md` | Documents that the build-time renderer derives staleness from `last_event_ts` (floor + teaser), same thresholds as the poller. |

## Decisions (+why)

- **Relative-time shifted fixtures over injectable `now`** (loop-2 offered either). The shift
  rewrites every ISO timestamp in a fixture copy at test time; the renderer keeps one code path
  with no test-only parameters, and the pins exercise the real wall-clock derivation end to end.
- **Kept the INT/TERM traps** after D2's withdrawal: they make the close-out explicit and pin
  130/143, and the corrected R2 repro + Part C (b) now guard the path as a regression, not a defect.
- **SIGINT harnesses run in the FOREGROUND.** Independent measurement matched the loop-2
  correction: an async child of a non-interactive shell gets SIGINT as SIG_IGN and bash refuses to
  trap it (`trap -p INT` → `trap -- '' SIGINT`); a backgrounded harness measures itself, not
  dispatch.sh. Part C (b) uses the pid-file pattern (harness writes `$$`; `$BASHPID` is empty under
  /bin/bash 3.2, so a subshell cannot name itself).
- **Offline snapshot still shows an in-flight seat pill** (loop-2 non-blocking note): accepted
  as-is for Phase B — floor.js mirrors the same stored-`elapsed_s` behavior, so changing it would
  create new mirror drift. Candidate for the mirror-drift follow-up task.

## Do not repeat

- Don't background a signal-test harness (`harness &`) under `make test`/CI — SIGINT is SIG_IGN
  there and untrappable; the test becomes a permanent red landmine or a false defect. Foreground
  launch + pid-file (or the repro's outer.sh) is the working shape.
- Don't trust `staleness.state` or `staleness.seconds` from live.json for age display anywhere —
  derive from `last_event_ts`. That drift (JS derived, Python copied) was D1's root cause.
- Don't assert LED state from the committed fixtures' baked timestamps — they only get older.
  Shift timestamps relative to now at test time.

## Evidence

- `bash tests/critic/phase-b-honesty-repro.sh` → `passed: 6   failed: 0`.
- `make test` → `All test suites passed.` (experience 300/300, desk-live 88/88, repro 6/6 wired in).
- M1 mutation proof: with the EXIT trap line deleted, desk-live suite → `FAIL early exit runs the
  close-out exactly once` (87 passed, 1 failed); restored after.
- `bash -n` clean on dispatch.sh + all three touched test scripts; `py_compile` clean.
- Signal behavior measurements (this machine, bash 5.3.12 + /bin/bash 3.2.57): backgrounded child →
  `trap -- '' SIGINT` (untrappable); foreground child SIGINT'd during `read`/`wait` → EXIT trap
  runs, exit 130, with and without an INT trap. Matches the loop-2 withdrawal of D2.

## Next hint (CTO)

- Loop-2 acceptance items are all addressed: B1 committed, B2 green without weakening assertions,
  D2 comment corrected, M1 executed + repro wired, M5/M8/M9 pinned.
- Open follow-ups the critic already flagged (non-blocking): Python/JS mirror drift (10 mirrored
  pairs — pick one source of truth), offline-snapshot in-flight pill, `_live_shell_body` length.
