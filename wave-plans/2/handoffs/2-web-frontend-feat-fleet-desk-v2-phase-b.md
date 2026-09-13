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
