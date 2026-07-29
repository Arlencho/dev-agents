# Handoff — Fleet Desk v2 Phase B, DATA PATH (devops seat)

Task: implement the Phase B data path only ([SYNTHESIS §3](docs/proposals/fleet-desk-v2-SYNTHESIS.md)) —
dispatch event stream, live watcher + `live/1` projection, Makefile targets, tests, schema docs.
**No Almanac craft was redesigned.** Wiring the `/live/` page to `live.json` is the remaining
Phase B step (web-frontend seat).

Branch: `feat/fleet-desk-v2-phase-b-data`

## Built

| File | What |
|------|------|
| `scripts/fleet-events.sh` **(new)** | Append-only JSONL writer, schema `fleet-events/1`. Sourceable library (`fleet_events_init`, `fleet_event`) + CLI (`init` / `emit`). Writes `logs/fleet-events/<dispatch_id>.jsonl` and a `latest` pointer file (plain text basename, not a symlink). |
| `scripts/dispatch.sh` | Sources the writer and emits `dispatch_start` · `dispatch_plan` · `wave_start` · `seat_dispatch` · `seat_exit` · `ratecap` · `failover` · `human_wait` / `human_resume` · `wave_end` · `seat_log` · `dispatch_end`. EXIT trap closes an aborted run honestly. No behavior change otherwise. |
| `scripts/desk_live.py` **(new)** | Stdlib watcher: resolves the stream (`--dispatch-id` → `latest` → newest), folds it into `site/experience/data/live.json` (schema `live/1`), serves `site/experience/` on loopback with `/live.json` and SSE `/events`. Modes: serve (default), `--watch`, `--once`. |
| `Makefile` | `desk-live` (serve+watch, `PORT=`), `experience-live` (alias), `desk-live-once` (no server) — all with `##` help text. `make test` now runs the new suite. |
| `tests/run-desk-live-tests.sh` **(new)** | 81 assertions: writer shape, types, redaction, opt-out; projection over fixtures; dispatch wiring guards. Fully offline. |
| `tests/fixtures/fleet-events/{wave-run,conductor-run}.jsonl` **(new)** | Synthetic streams: parallel wave with ratecap → failover → retry, and a conductor chain blocked at a guardrail with an open human gate. |
| `docs/experience-data.md` | New section **Live event stream (Phase B)**: envelope, every event type + payload, redaction law, opt-out, full `live/1` table, run commands. |
| `docs/experience.md` | Short operator walkthrough of the live data path. |
| `.gitignore` | `logs/fleet-events/` (per-machine runtime truth). |
| `tests/run-experience-tests.sh` | Closes Phase A critic residual **R1** (mission task-table pill must carry text, not color alone). |

## Decisions

1. **Writer is a separate sourceable library, not inline in `dispatch.sh`.** Keeps the dispatch diff small, and the event shape is unit-testable without a fleet.
2. **Emission never fails a dispatch.** Every function returns 0; an unwritable events dir prints a warning and disables the stream (test: `unwritable events dir …`).
3. **Redaction is enforced at the writer, not at the reader.** Keys must be `lower_snake`; values are control-char stripped, newline-flattened, truncated to 200 chars; empty values are omitted; plans/logs travel as basenames. `TASK_DESC` is never passed to an event, and a test greps `dispatch.sh` for that regression.
4. **Typed values by key allowlist.** `exit` / `wave` / `duration_s` / counts emit as JSON numbers; `task_id` stays a string so an id or branch that looks numeric never changes type mid-stream.
5. **Mode is derived, then declared.** `conductor` when the plan path contains `conductor` **or** every wave holds exactly one seat in a multi-wave plan; otherwise `wave`. Written into `dispatch_start`, so the projector never has to guess.
6. **Honesty in the projection.** A seat still `running` after `dispatch_end` becomes `unknown` (no eternal spinner); staleness is time-based `live` (<120s) → `stale` (<900s) → `offline`; an empty events dir projects `idle` with a reason that teaches the next command; malformed lines are counted in `warnings`, never guessed at.
7. **`waiting_on` priority:** open human gates → rate-capped seats → else the longest-running seat. Never empty while something is actually blocking.
8. **Live state stays out of `index.json`** (SYNTHESIS §3 Phase B item 5). `live.json` is a sibling file, written atomically via `os.replace`.
9. **SSE is additive, not required.** `/events` pushes one `event: live` frame per projection change; poll `data/live.json` or use `--once` / `--watch` for `file://` desks.

## Do not repeat

- **Don't expect `make lint` to pass.** It already fails on a clean tree (roles/ ↔ providers/ drift, `11 file(s) out of sync`, exit 2) — verified by stashing this work. Unrelated to Phase B; the fix is `./scripts/sync-providers.sh` in its own PR.
- **Don't mutate `experience_build.py` with a naive `str.replace(..., 1)`** when checking the R1 pin: the identical pill string first appears at `:335` (`status_pill`) and that mutation is killed by an older assertion, which reads as "my pin didn't fire". Mutate **line 458** (`_static_status_pill`) explicitly — then the new pin is the only failure.
- **Don't make `task_id` a number** for tidiness; the writer's numeric-key allowlist deliberately excludes it and a test pins the type.
- **Don't add a `latest` symlink**: the pointer is a plain file so it survives copy/rsync/non-POSIX filesystems, and the reader refuses a pointer containing `/`.
- **Don't smoke-test the emitter under `set -u` without `${BASH_SOURCE[0]:-}`** — sourcing from a strict shell tripped `BASH_SOURCE[0]: parameter not set` before the guard was added.

## Evidence

```
$ ./tests/run-desk-live-tests.sh | tail -3
  passed: 81   failed: 0

$ make test | grep -E "passed|All test"
== 17 passed, 0 failed ==   (launcher)     == 9 passed, 0 failed ==  (failover)
== 22 passed, 0 failed ==   (routing)      == 6 passed, 0 failed ==  (autoplan)
== 5 passed, 0 failed ==    (evidence)     == 9 passed, 0 failed ==  (vendor-auth)
== 266 passed, 0 failed ==  (experience — was 265, +1 R1 pin)
  passed: 81   failed: 0    (desk-live)
All test suites passed.
```

End-to-end through the **real** `dispatch.sh` (throwaway repo copy, one unreachable
worker, `run-remote.sh` deliberately absent so seats fail fast — no agent was ever launched):

```
$ /opt/homebrew/bin/bash scripts/dispatch.sh <repo> plan.txt --auto --retries 0 --skip-auth-preflight
$ cat logs/fleet-events/*.jsonl
{"schema":"fleet-events/1","seq":1,...,"event":"dispatch_start","mode":"conductor","repo":"dev-agents","plan":"plan.txt"}
{"schema":"fleet-events/1","seq":3,...,"event":"wave_start","wave":1,"seats":1,"mode":"conductor"}
{"schema":"fleet-events/1","seq":4,...,"event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/ghost-a","wave":1,"provider":"claude","model":"opus","worker":"ghost-worker","attempt":1}
{"schema":"fleet-events/1","seq":5,...,"event":"seat_exit","task_id":"0",...,"status":"failed","exit":127,"duration_s":0,"attempt":1}
{"schema":"fleet-events/1","seq":11,...,"event":"dispatch_end","status":"completed","total":2,"succeeded":0,"failed":2,"duration_s":0}
$ cat logs/fleet-events/latest
20260729-203420-dev-agents.jsonl

$ FLEET_EVENTS=0 … scripts/dispatch.sh … ; test -d logs/fleet-events
OK: FLEET_EVENTS=0 wrote nothing

$ python3 scripts/desk_live.py --once --events-dir <tmp>/logs/fleet-events --out <tmp>/live.json
live.json written (status=settled, seats=2, staleness=live)
  mode=conductor  wave={current:2,total:2}  counts={blocked:2,total:2}  last_event_ts=2026-07-29T20:34:20Z
```

Server routes (loopback, 3s run):

```
$ curl -s http://127.0.0.1:8791/live.json | head -c 60   → {"schema": "live/1", "generated_at": ...
$ curl -s -m 2 http://127.0.0.1:8791/events | head -c 20 → event: live\ndata: {...
$ curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8791/index.html → 200
```

R1 mutation proof (the new pin is load-bearing):

```
$ # line 458 _static_status_pill → <span class="st st-{kind}"></span>
$ ./tests/run-experience-tests.sh | grep -E "FAIL|passed,"
  FAIL mission task-table pill carries text, not color alone
== 265 passed, 1 failed ==
$ git checkout -- scripts/experience_build.py   # reverted → 266 passed, 0 failed
```

Syntax/lint: `bash -n` clean on `dispatch.sh` + `fleet-events.sh`; `shellcheck -S error` exit 0 on both;
`python3 -m py_compile scripts/desk_live.py` clean (3.9-compatible, stdlib only, loopback bind only).

## Open questions

1. **Concurrent dispatches** share `logs/fleet-events/latest` — last writer wins. Per-run files are unaffected (`--dispatch-id` selects any of them). If the fleet ever runs two dispatchers at once, the pointer should become a list; not needed today.
2. `recent_events` is capped at 50. If the Floor wants a full replay feed, Phase C's scrubber should read the JSONL directly rather than growing the projection.
3. Staleness thresholds (120s / 900s) are constants in `desk_live.py` and published in `live.json`. If long single-seat runs make 120s feel twitchy, raise `STALE_AFTER` rather than teaching the UI to lie.

## Next hint (web-frontend seat, Phase B remainder)

Render `/live/` from `data/live.json` — the file already carries everything the SYNTHESIS asks for:
`mode` (`wave` lanes vs `conductor` spine), `seats[]` with `pipeline` + `elapsed_s` + `failovers[]` + `ratecapped`,
the `waiting_on[]` strip, `staleness.state` for STALE/OFFLINE chrome, and `status` for the settled/aborted watermark.
Prefer SSE `/events` when served by `make desk-live`, fall back to polling `data/live.json`, and keep the
Phase A static empty states for the idle case (`status == "idle"` carries a `reason` string built to be shown).
