# Handoff — Fleet Desk v2 design, Proposal A (seat A)

Branch `feat/proposal-fleet-desk-v2-A`. Design proposal only — no product UI code, no `experience_data.py` changes, per brief.

## Built

- `docs/proposals/fleet-desk-v2-proposal-A.md` — full v2 design covering all 10 required brief sections:
  - Name: keep **Fleet Desk**; two rooms — **Almanac** (static record, Phase 0/1 pages restyled) + **The Floor** (`/live/`, new live ops surface).
  - Visual system: token sheet (one cyan accent, status hues always paired with words), system sans + dominant mono on the Floor, three-job motion budget with `prefers-reduced-motion` parity.
  - Wireframes: Home, Floor (wave fan-out lanes vs conductor serial chain — distinct silhouettes for P5), Work with wave summary chips + Replay, Trail with timeline strip, plus Roles/Skills/Learn/Conductor/Company/About deltas.
  - Live design: new append-only `logs/fleet-events/<dispatch_id>.jsonl` emitted by `dispatch.sh` (closed v1 event set incl. `task_ratecap`, `dispatch_heartbeat`), on-demand `scripts/desk-live.sh` stdlib server, 2 s polling, staleness/offline/replay honesty rules; handoff JSONL stays authoritative over events.
  - CLI bridge: `make desk-live` once; Floor auto-follows new dispatches via `latest` pointer; chat/CLI stays the only control plane.
  - Phased ship: A restyle (static only) → B live tail → C replay + additive `timeline[]` (no schema bump); rough seat-day estimates + kill criteria.

## Decisions

- Kept product name; renamed nothing user-facing. Live surface is a room inside Fleet Desk, not a second product.
- Events stream over `fleet-status.json` snapshot: client reduces events; a derived snapshot file is a second thing to go stale.
- Polling over SSE for Phase B (debuggable with `curl`); SSE deferred to C only if laggy.
- Activity = agent-log byte growth, explicitly labeled `proxy`, never a progress percent; remote lanes default to no bar (owner Q5).
- Hard non-goal restated: no dispatch/promote buttons in any browser surface; Floor is read-only glass.

## Do not repeat

- Do not read/copy `fleet-desk-v2-proposal-B.md` / `-C.md` (independence rule) — not read here.
- Do not propose a schema v2 bump for live: Phase C additions are additive per `docs/experience-data.md` change rules.
- Do not source liveness from plan parsing alone — lanes exist only from events; planned tasks render `queued`.

## Evidence

- Grounding checks run before writing (all in this session):
  - `ls scripts/ config/` → `dispatch.sh`, `fleet-status.sh`, `provider-scorecard.sh`, `run-remote.sh` etc. exist.
  - `grep -n "provider-state" scripts/dispatch.sh` → cooldown file written at `dispatch.sh:272` (`logs/provider-state/<vendor>.cooldown`).
  - `grep -n "wave\|wait" scripts/dispatch.sh` → wave grouping ~L437–494, per-wave PID wait/retry loop ~L756–857, exit codes 75/69/77 handled.
  - `ls logs/provider-state/` → directory exists; `ls ~/dev/agent-logs | tail` → per-task log files exist.
- Read fully: brief, `experience-console-SYNTHESIS.md`, `docs/experience.md`, `docs/experience-data.md`, `docs/session-modes.md`.

## Open questions

- Owner questions §10 of the proposal (events retention, auto-open, idle Floor, chime, remote proxy, Almanac theme default).

## Next hint

- After seats B/C land: owner SYNTHESIS, then Phase A (pure restyle of `templates/experience/site.css` + build templates) is safely implementable independent of the live-events decision.
