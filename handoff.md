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
