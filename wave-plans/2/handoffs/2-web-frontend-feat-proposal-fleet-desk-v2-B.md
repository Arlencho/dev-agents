# Handoff — Fleet Desk v2 Proposal B (design only)

Branch `feat/proposal-fleet-desk-v2-B` → PR #54 (draft, "Fleet Desk v2 — Proposal B: Flight Line live observability"). Task was DESIGN PROPOSAL ONLY — no product UI, no `experience_data.py` changes.

## Built

- `docs/proposals/fleet-desk-v2-proposal-B.md` — all 10 required sections from the v2 brief: name (Fleet Desk kept; live layer named **Flight Line**), north-star, visual system, IA + ASCII wireframes (Home, Live/Flight Line wave + conductor modes, Work, Trail, others), live observability design, CLI bridge, data gaps, phased ship (A restyle / B live tail / C replay), risks, open questions.

## Decisions (+why)

- **Did not read** other `fleet-desk-v2-proposal-*.md` files (brief requires independence; none existed locally at write time anyway).
- **Live state stays OUT of `index.json`** (schema v2 untouched). Proposed new artifact: `logs/fleet-events.jsonl` append-only event stream written by `dispatch.sh`, plus gitignored `site/experience/data/live.json` projection with independent `live/1` schema. Rationale: renderer law says pages only show what the contract carries; mixing in-flight state into the almanac contract would force a v3 migration for a fundamentally different lifecycle.
- Claim "everything in the stream already exists in dispatch.sh" is grounded: session/seats from plan parse, `RESULT_STATUS`/`RESULT_PROVIDER` arrays, retry loop, cooldown logic at `dispatch.sh:272` (`logs/provider-state/*.cooldown`).
- Wave vs serial visual split is **structural** (stacked bands+lanes vs single spine), not just color — P5 + colorblind safety.
- Three liveness tiers (SSE watcher / file:// polling / static snapshot) so "static is a feature" survives; watcher is opt-in `make desk-live`, stdlib only.

## Do not repeat

- Branch `feat/proposal-fleet-desk-v2-B` already existed locally at origin/main tip — no need to create it.
- `/bin/bash` on this Mac is 3.2; `dispatch.sh` itself requires Homebrew bash 4+ (irrelevant for a docs wave, matters if someone instruments it).

## Evidence

- `git log --oneline -1` → `a09567f docs(proposals): Fleet Desk v2 Proposal B — Flight Line live observability`
- PR: https://github.com/Arlencho/dev-agents/pull/54
- Verified inputs read in full: brief, experience-console-SYNTHESIS, docs/experience.md, docs/experience-data.md, docs/session-modes.md; grepped dispatch.sh/fleet-status.sh, config/workers.yaml, ratecap-patterns.conf for live-data grounding.

## Open questions

- Six owner questions in proposal §10 (session id format, `seat_progress` granularity, event-log retention, sound, Paperclip overlay timing, auto-open browser). Owner SYNTHESIS decides after seats A/C land.

## Next hint

For the critic: check §7 (data gaps) against real dispatch.sh behavior — especially whether `cooldown_until` is actually computable from provider-state files today or only a cooldown *start* is recorded; and whether the claim that `file://` polling of `live.json` works without CORS issues holds in target browsers.
