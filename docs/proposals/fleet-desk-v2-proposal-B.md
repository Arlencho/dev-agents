# Fleet Desk v2 — Proposal B: "Mission Control, Almanac Underneath"

**Seat:** B (independent — no other seat file was read before writing)
**Brief:** [`fleet-desk-v2-BRIEF.md`](fleet-desk-v2-BRIEF.md) (2026-07-29)
**Data law respected:** [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md) — trail = atom, wave = group, PMI gates, join rules all stay.
**Scope of this file:** design + wireframes + data gaps. No product UI implementation, no `experience_data.py` rewrite in this wave.

---

## 1. Name

| Layer | Name | Why |
|-------|------|-----|
| Product (unchanged) | **Fleet Desk** | Owner freeze. The almanac: what the fleet did, learned, knows. |
| Live surface (new) | **Fleet Desk · Flight Line** | The missing surface. A "flight line" is where you watch aircraft taxi, launch, recover — exactly the operator's ask: *watch work move while I orchestrate from chat*. It is a view inside Fleet Desk, not a second product, not a second orchestration stack. |

Tagline extension: *The almanac tells you what happened. The Flight Line shows you what is happening.*

Everything below keeps `Fleet Desk` as the product name and uses **Flight Line** for the live layer (routes `/live/…`).

---

## 2. North-star UX (1 page)

**Who:** the fleet operator (Arlen) and, later, anyone running `dispatch.sh`. One user, one screen, zero setup.

**30-second story:**

> I'm in my CLI chat. I tell the orchestrator "trigger it." It echoes `./scripts/dispatch.sh … olympus-platform-20260729.plan` and adds one new line: **watch: `make desk-live`**. I run it — or click the `fleet-desk://live` link the chat prints. A browser tab opens on a dark, calm screen.
>
> Top: the session banner — `wave-plans/olympus-platform-20260729.plan · 3 waves · 7 seats · started 14:02:11`.
> Middle: the **Flight Line** itself. Wave 1 has fanned into three parallel lanes — `go-backend`, `db-architect`, `web-frontend` — each lane a card with the seat's role, vendor (mechanical provenance), branch in mono, elapsed time ticking, and a breathing status glyph. `web-frontend`'s card pulses amber: **rate-capped on kimi — failover to claude in 42s** with a countdown ribbon. I can see the failover happen as a provider badge swap, stamped into the lane.
>
> Below: **"What am I waiting on?"** — the honest answer, always one line or a short list: `1 seat running · 1 in cooldown (42s) · wave 2 blocked on wave 1`.
>
> Wave 1 lands. The three lanes compress into the almanac — they are now **trails**, the same atoms the static desk has always shown. Wave 2 fans out. When everything is done, the Flight Line goes quiet and says so, and offers one button: **Open the wave in Work** — the static, evidence-first desk, one click away.
>
> Later, in the almanac, I scrub the same session back with a replay slider — the live view re-rendered from the recorded event stream. Live and history are the same component fed by the same events.

**The one rule above all:** the Flight Line only draws what the fleet actually emitted. No seat ever shows "thinking" because a spinner looks nice. If the event stream stops, the UI says **stale — last event 38s ago**, greys the lanes, and keeps the timestamps. Honesty is chrome, not a footnote (P7).

---

## 3. Visual system

### 3.1 Reference peers (inspiration, not clones)

| Peer | What we take | What we refuse |
|------|--------------|----------------|
| **Linear** | Type discipline, restrained palette, keyboard-first density | Its flatness — we need depth for live state |
| **Vercel dashboard** | Monochrome + one accent, deploy-log feel, mono font for IDs | Marketing-page gloss |
| **Raycast** | Command-first, instant feedback, compact rows | Hidden state behind hotkeys only |
| **Mission-control / launch-ops UI** (NASA-style, `htop`, Datadog live tail) | Ambient status you read from across the room; every glyph has a legend | Fake telemetry, decorative gauges |
| **Apple Music / Void-era arc.so** | Physics-lite motion that communicates *direction of change* | Motion that delays information |

### 3.2 Palette (dark-first, light theme derived — never inverted)

```
Canvas        #0B0D10   near-black, slight blue
Surface 1     #12151A   cards / lanes
Surface 2     #1A1E26   raised (active seat)
Hairline      #262B34   1px borders, no shadows below md
Ink           #E6E9EF   primary text
Ink dim       #9AA3B2   secondary
Ink faint     #5C6572   metadata

Signal        #4FD1C5   teal — "fleet healthy / active" (the ONE accent)
Attention     #F5B544   amber — waiting, cooldown, failover (paired with text)
Danger        #F2555A   red — failed, exit≠0 (paired with text)
Done          #7CB87C   muted green — completed (paired with text)
Stale         #4A4F58   grey — no data / degraded
```

Status is **always** word + glyph + color, never color alone (SYNTHESIS §6.7 carries forward). `prefers-color-scheme` supported; light theme maps Signal to a darker teal for contrast ≥ 4.5:1.

### 3.3 Type

- **Sans:** system stack (`-apple-system, Inter, Segoe UI`) — zero font downloads, `file://`-safe.
- **Mono:** `ui-monospace, SF Mono, JetBrains Mono` — SHAs, branches, task ids, plan lines, timestamps, event payloads. If it came from a machine, it renders in mono.
- **Scale:** 12 / 13 / 14 / 16 / 20 / 28 — nothing else. Live timestamps and elapsed counters always tabular-nums so ticking doesn't jitter layout.

### 3.4 Density

Two densities, one grammar:
- **Almanac density** (static pages): table-first, 32–36px rows, matches today's desk.
- **Flight Line density**: lane cards ~64px, one screen = one full wave of ~8 seats without scrolling. Nothing truncates a branch name or task id — they wrap in mono.

### 3.5 Motion language

Motion is a *channel for change*, not decoration. Four allowed motions, that's the whole vocabulary:

| Motion | Duration / easing | Meaning | Reduced-motion fallback |
|--------|-------------------|---------|--------------------------|
| **Fan** | 240ms, spring (no overshoot beyond 2%) | wave dispatching: one spine node splits into parallel lanes | instant layout, "wave N dispatched" text flash |
| **Pulse** | 1.6s breath, opacity 1→0.55→1 on a 3px glyph | seat actively emitting events | static glyph + `running 42s` text |
| **Ribbon** | linear progress, left→right | cooldown / countdown (rate-cap reset, retry timer) | numeric countdown text only |
| **Settle** | 180ms fade + 8px rise | event lands in the lane log / trail completes | instant append |

`prefers-reduced-motion` kills all four and is also a manual toggle in the header (persists to `localStorage`). Nothing auto-plays on the almanac pages. No parallax, no scroll-jacking, no blur behind text.

### 3.6 Depth & ambient status

- Depth via **surface steps + hairlines**, not drop shadows (Vercel, not Material).
- The header carries an **ambient status line**: one dot + one sentence — `● live — 3 seats in wave 2, next event <1s ago` / `◌ stale — last event 38s ago` / `○ offline — no watcher running (make desk-live)`. Readable from across the room; conveys liveness without watching the lanes.
- **Empty states teach**: every empty page names the exact next command (`make experience`, `dispatch.sh …`, `make desk-live`) — carried forward from SYNTHESIS §6.6.

---

## 4. IA + wireframes

Route map (v2 additions in **bold**):

```
/                     Global home (almanac, restyled)
/live/                **Flight Line — current/most recent session**
/live/<session_id>/   **specific session (deep link from CLI)**
/work/  /work/flat/   Work index (group-by-wave law unchanged)
/trail/<task_id>/     Trail detail (+ "view in Flight Line replay" when session known)
/role/<role>/  /skill/<id>/  /learning/<slug>/
/conductor/           Conductor index (+ live affordance when conductor session running)
/company/<id>/        Company home
/about/               Sources, schema, joins, PMI glossary, **event-stream spec**
```

Nav: `Home · Live · Work · Skills · Learn · Roles · Conductor · About` + scope chip `Global | <company>…` (law unchanged). **Live** gets a dot: `Live ●` when a session is active — visible from every page, so the operator in the almanac learns the fleet is moving.

Click budget: home → trail ≤ 3 clicks (law); chat → live session ≤ **1 command**.

### 4.1 Global home (restyled almanac)

```
┌─ Fleet Desk ────────────────────────── ● Global | olympus | safeplace ─┐
│  Home Live● Work Skills Learn Roles Conductor About                    │
│  ──────────────────────────────────────────────────────────────────    │
│  ┌─ Flight Line ──────────────────────────────── open live → ────────┐ │
│  │  ● wave 2 running · 3 seats · last event 1s ago   [mini lanes ▮▮▯]│ │
│  └───────────────────────────────────────────────────────────────────┘ │
│  Companies: [olympus n=41] [safeplace n=12] [aegis °placeholder]       │
│  ┌ Recent work ─────────────────────────────── view all Work → ─────┐ │
│  │ ✓ web-frontend   black-aces   wave 9   done    14:02             │ │
│  │ ✓ frontend-critic black-aces  wave 9   done    13:58             │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│  Roles (top) · Skills · Learnings · Watchlist                         │
└───────────────────────────────────────────────────────────────────────┘
```

The only structural change vs Phase 1: the **Flight Line banner** on top. If no session has ever run, it is an empty state that teaches: *"Nothing live yet — trigger a dispatch and run `make desk-live`."*

### 4.2 Flight Line — wave mode (the core screen)

```
┌─ Fleet Desk · Flight Line ─────────────────────────────── ● live ─────┐
│ session: olympus-platform-20260729 · 3 waves · 7 seats · ▶ 00:12:41    │
│ mode: WAVE (multi-seat parallelism)            motion: on · sound: off │
│────────────────────────────────────────────────────────────────────────│
│  WAVE 1 ─ settled ✓ 3/3 · 4m 12s                        [replay ▸]     │
│   ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ │
│  WAVE 2 ─ live · 2 running · 1 cooldown                                  │
│  ╭ go-backend ─ claude ─ feat/payments-svc ─────────── 02:41 ● running ╮│
│  │ ▸ event: tests green, opening commit…              attempt 1/3      ││
│  ╰─────────────────────────────────────────────────────────────────────╯│
│  ╭ web-frontend ─ kimi⇒claude ─ feat/payments-ui ──── 01:05 ◔ cooldown ╮│
│  │ ▰▰▰▰▰▰▰▱▱▱ rate-cap on kimi · failover to claude in 42s · attempt 2/3││
│  ╰─────────────────────────────────────────────────────────────────────╯│
│  ╭ db-architect ─ claude ─ feat/payments-db ────────── 00:58 ● running ╮│
│  │ ▸ event: migration up on sandbox                                    ││
│  ╰─────────────────────────────────────────────────────────────────────╯│
│  WAVE 3 ─ queued · test-engineer · 1 seat · blocked on wave 2           │
│─────────────────────────────────────────────────────────────────────────│
│  WAITING ON: 2 seats running · 1 failover (42s) · wave 3 gated by wave 2│
│  stream: logs/fleet-events.jsonl · last event 1s ago · schema live/1    │
└──────────────────────────────────────────────────────────────────────────┘
```

Design notes:
- **Waves are horizontal bands**, newest active wave visually raised (Surface 2). Settled waves compress to a one-line summary with a replay affordance — progressive disclosure: the past collapses, the present breathes.
- **One lane = one seat = one future trail.** The lane card IS the trail being born; when the seat exits, the card's content is literally the handoff fields (`role, branch, status, provenance, exit`). Live and almanac share the atom.
- **Provider badge shows failover as history** (`kimi⇒claude`), never silently swaps — the failover event is stamped in the lane's event ticker.
- **Cooldown ribbon** is a real countdown from the `cooldown_until` field in the event, not an animation guess.

### 4.3 Flight Line — serial / Conductor mode (P5: visually distinct, not a degraded wave)

```
┌─ Fleet Desk · Flight Line ─────────────────────────────── ● live ─────┐
│ session: conductor/fix-abarranges-space · CONDUCTOR (single chain)     │
│────────────────────────────────────────────────────────────────────────│
│   diagnose ✓ 0:38 ──▶ packet ✓ 0:12 ──▶ human go ✓ ──▶                │
│                                                                        │
│   ╭ web-frontend ─ kimi ─ feat/fix-abarranges-space ── 01:12 ● running╮│
│   │ ▸ event: space restored in legal copy, screenshot captured        ││
│   ╰────────────────────────────────────────────────────────────────────╯│
│                                                                        │
│   ──▶ verify ○ pending ──▶ done                                        │
│─────────────────────────────────────────────────────────────────────────│
│  WAITING ON: web-frontend seat (running 1m 12s)                         │
└──────────────────────────────────────────────────────────────────────────┘
```

Serial mode is a **horizontal spine**: a left-to-right chain of stage nodes (`diagnose → packet → human go → seat → verify → done`), exactly one active node. The grammar difference is structural, not just color: wave = **stacked bands fanning into parallel lanes**; conductor = **single spine with one hot node**. The operator never confuses the two, even colorblind, even from across the room.

### 4.4 Work index (restyled, law intact)

Group-by-wave sections, flat toggle, unlinked-last ordering — all unchanged from SYNTHESIS §4.2. v2 changes are chrome only: density tokens, status pills with glyphs, mono for ids, and on wave section headers a small `▸ replay` link **iff** an event stream for that wave exists on disk (honesty: no stream, no button).

### 4.5 Trail detail (one addition)

```
┌─ Trail wave9-web-frontend-black-aces ────────────── ● done ───────────┐
│ ← Work · Global · wave 9 · session experience-console-… ▸ replay      │
│  (existing Phase 1 detail: meta grid, plan line, sections, raw JSONL) │
└────────────────────────────────────────────────────────────────────────┘
```

The `▸ replay` breadcrumb jumps to `/live/<session>/?t=<trail-start-ts>` — the trail seen in the context of the motion that produced it. Missing session id (older trails) → no link, and the page says nothing. Never a dead button.

### 4.6 Roles / Skills / Learn / Conductor / Company / About

Unchanged in structure from Phase 1; restyle only (§3 tokens). Two honest additions:

- **Conductor index**: rows gain a live dot when a conductor session is active; empty state teaches the conductor flow (`Activate Conductor` in chat → go → `make desk-live`).
- **About**: new section *"Live data (Flight Line)"* documenting the event-stream schema version, where the file lives, and the staleness rules — the live layer is auditable like everything else.

---

## 5. Live observability design

### 5.1 Data sources (in order of preference)

| # | Source | What it gives | Exists today? |
|---|--------|----------------|----------------|
| 1 | **Event stream: `logs/fleet-events.jsonl`** (new, append-only, written by `dispatch.sh`) | session start/end, wave boundaries, seat dispatch/exit, attempts, failover, rate-cap + `cooldown_until`, waiting-on-human | **No — the core gap (§7)** |
| 2 | `wave-plans/**/handoffs/*.jsonl` | Seat completion records (already the trail atom) | Yes — the Flight Line's "settle" trigger even without events |
| 3 | `logs/provider-state/*.cooldown` | Rate-cap class + reset time per vendor | Yes (`dispatch.sh:272` writes these) |
| 4 | `logs/*.log` (per-task logs, metadata only) | mtime growth = seat heartbeat proxy; filename only, **transcripts never read** | Yes |
| 5 | The plan file itself (`wave-plans/**/*.plan`) | Wave structure, seat list, branches — the Flight Line pre-renders the full skeleton *before* the first event | Yes |
| 6 | Paperclip API (`127.0.0.1:3100`) | Optional governance overlay when running | Optional; never required (SYNTHESIS law) |

### 5.2 Update cadence

- **Watcher mode (default):** `make desk-live` starts a stdlib-Python local server (`http://127.0.0.1:8766`) that tails the event stream and handoffs dir, serving **SSE** (`/events`). UI updates on event, heartbeat from server every 5s so staleness is measured, not guessed.
- **Polling fallback (file://):** a small JS poller re-fetches `live.json` every 2s. Works over `file://` with zero daemons; slightly coarser.
- **Static fallback:** if neither is running, `/live/` renders the *last known* session from the most recent build, stamped `static snapshot — not live`. Three tiers, all honest, no dead ends.

### 5.3 Serial vs wave visualization (P5 recap)

| | Wave | Conductor |
|---|------|-----------|
| Shape | Stacked horizontal bands; band fans into N parallel lanes | One horizontal spine; stages as nodes; one hot node |
| Parallel signal | Lane count + simultaneous pulses | Never more than one active stage |
| Failover/rate-cap | Lane-level ribbon + badge history | Spine node gets the same ribbon treatment |
| "Waiting on" | Aggregates across lanes | Single current stage |

### 5.4 Failover & rate-cap as chrome (P4/P7)

- **Rate-cap:** event `seat_ratecap {vendor, class, cooldown_until}` → lane flips to `◔ cooldown`, amber ribbon counts down **to the emitted timestamp**, provider badge keeps the capped vendor struck through. If `cooldown_until` is absent, the ribbon shows `cooldown (unknown duration)` — never a fake countdown.
- **Failover:** event `seat_failover {from, to, reason}` → badge becomes `kimi⇒claude`, ticker line `failover: kimi → claude (ratecap)`. Attempt counter increments: `attempt 2/3` (from `--retries`).
- **Auth failure / unavailable (exit 69):** distinct from rate-cap — red hairline, `unavailable: auth` text, no countdown.
- **Waiting on human:** conductor `human go` gate and wave `armed` state are first-class: spine node `awaiting human: "trigger"` pulses amber. The desk never auto-advances it — it reflects the gate, it doesn't lift it.

### 5.5 "What am I waiting on?" (the owner's real question)

A persistent one-to-three-line strip, recomputed from the last event state on every tick. Priority order:

1. `waiting on human: wave 2 armed — say "trigger"` (human gates outrank machine waits)
2. `n seats running (longest: go-backend 4m 12s)`
3. `n in cooldown (next reset 0:42)`
4. `wave N+1 gated by wave N (k of m settled)`
5. idle: `fleet quiet — last session ended 2h ago`

No notifications, no sound by default — the strip is the answer; ambient sound is an opt-in toggle only.

---

## 6. CLI ↔ Desk bridge (P6) — exact operator steps

**Conductor path:**

1. Operator in chat: `Activate Conductor` → diagnose → packet → plan line under `wave-plans/conductor/`.
2. Orchestrator proposes; operator says **go**.
3. Orchestrator runs `dispatch.sh` and prints one extra line (new, tiny change): `watch live: make desk-live`.
4. Operator runs `make desk-live` in a second terminal (or clicks the printed `http://127.0.0.1:8766/#/live/<session_id>` — macOS `open` handles it).
5. Flight Line opens directly on this session in **serial spine** view.

**Wave path:** identical, but step 5 renders **wave bands**; with `--auto`, wave transitions fan automatically; without it, `awaiting human` nodes appear between waves.

**Design decisions:**
- **`make desk-live` is the only new operator habit.** It reuses the existing `site/experience/` tree; the watcher server is a stdlib Python script, killed with Ctrl-C, no launchd, no daemon.
- `dispatch.sh` accepts `--session-id` (default: slugified plan name + start ts) and echoes the deep link. The chat orchestrator surface stays the control plane; the desk never dispatches (SYNTHESIS rejection list holds).
- If the operator never opens the desk, nothing is lost — the event stream is on disk and replayable later.

---

## 7. Data / API gaps

### 7.1 What schema v2 (`index.json`) lacks — and should keep lacking

Schema v2 is the **almanac contract**: settled trails, PMI, joins, critic pairs. It has no notion of an in-flight session, seat attempt, cooldown, or human gate — and per the renderer law ("the renderer never scans the repo"), it shouldn't grow them. **Do not put live state into `index.json`.** Live needs a *separate* stream; the almanac contract stays the settle point.

### 7.2 Proposed addition 1 — event stream (the gap that matters)

`logs/fleet-events.jsonl`, append-only, one JSON object per line, written by `dispatch.sh` (and nothing else in v2):

```jsonl
{"v":1,"ts":"…","session":"olympus-20260729-140211","type":"session_start","mode":"wave","plan":"wave-plans/olympus-platform-20260729.plan","waves":[1,2,3],"seats":7}
{"v":1,"ts":"…","session":"…","type":"wave_start","wave":2,"seats":["go-backend","web-frontend","db-architect"]}
{"v":1,"ts":"…","session":"…","type":"seat_dispatch","wave":2,"seat":"web-frontend","role":"web-frontend","provider":"kimi","branch":"feat/payments-ui","attempt":1,"task_id":"…"}
{"v":1,"ts":"…","session":"…","type":"seat_ratecap","seat":"web-frontend","provider":"kimi","class":"ratecap","cooldown_until":"…"}
{"v":1,"ts":"…","session":"…","type":"seat_failover","seat":"web-frontend","from":"kimi","to":"claude","reason":"ratecap","attempt":2}
{"v":1,"ts":"…","session":"…","type":"seat_progress","seat":"go-backend","note":"tests green"}   // optional, from log-mtime/heartbeat proxy or explicit echo
{"v":1,"ts":"…","session":"…","type":"seat_exit","seat":"web-frontend","status":"success","exit":0,"duration_s":231,"task_id":"…"}
{"v":1,"ts":"…","session":"…","type":"wave_complete","wave":2,"settled":"3/3"}
{"v":1,"ts":"…","session":"…","type":"waiting_human","gate":"wave_3_trigger"}
{"v":1,"ts":"…","session":"…","type":"session_end","status":"done","duration_s":761}
```

Field provenance: `session/mode/waves/seats` from the plan parse; `provider/attempt/exit/duration` from arrays dispatch.sh already maintains (`RESULT_STATUS`, `RESULT_PROVIDER`, retry loop); `cooldown_until` from the provider-state logic at `dispatch.sh:272`; `waiting_human` from the wave-continue prompt. **Everything in the stream already exists inside dispatch.sh at runtime — it is today written to the terminal and thrown away.** The stream is capture, not invention.

### 7.3 Proposed addition 2 — `live.json` projection

`site/experience/data/live.json` (gitignored, beside `index.json`): the last-N-events window + computed `waiting_on` + `staleness` marker, regenerated by the watcher on each event. This is what the `file://` polling fallback reads. Schema `live/1`, versioned independently of `index.json`.

### 7.4 Migration honesty

- **Old sessions have no events.** Replay for pre-v2 sessions can only re-animate *trail settle order and timestamps* from handoffs — the UI labels that mode **`reconstructed replay (settles only)`** vs **`full replay (event stream)`**. The distinction is printed on the replay bar. Never blur it.
- `index.json` schema stays at v2. If trail records later want a `session_id` back-reference, that is **additive** (no bump per experience-data.md rules).
- Event-stream versioning: `v` field per line; the watcher tolerates unknown `type`s by rendering them as raw ticker lines, so the stream can grow additively without a UI release.
- If `dispatch.sh` instrumentation ships later than the UI, the Flight Line works degraded from sources 2–5 (§5.1) and says so: `live events unavailable — showing settle order from handoffs`.

---

## 8. Phased ship plan

| Phase | Contents | Rough effort | Depends on |
|-------|----------|--------------|------------|
| **A — Visual restyle (static only)** | New tokens/type/motion CSS on existing `templates/experience/`; header ambient line; Live nav slot with honest "no session" empty state; restyle Home/Work/Trail/Roles/Skills/Conductor/About. No new data. | 2–4 days | Nothing; pure template/CSS wave. Static desk stays shippable the whole time. |
| **B — Live tail** | `logs/fleet-events.jsonl` writer in `dispatch.sh` (~40 lines, guarded `FLEET_EVENTS=off` opt-out); `scripts/desk_live.py` stdlib SSE server + `live.json` projection; `/live/` route with wave-band + spine renderers, cooldown ribbons, waiting-on strip; `make desk-live`; deep-link echo in dispatch output. | 4–6 days | Phase A tokens. No orchestration changes — `dispatch.sh` gains a writer, not new behavior. |
| **C — History replay** | Replay scrubber on `/live/<session>/` (slider over event stream; reconstructed-replay mode for pre-stream sessions with the honesty label); trail↔session breadcrumb links; Home Flight Line banner fed by last session. | 2–3 days | Phase B stream format frozen. |

Effort is order-of-magnitude for one engineer; A and B can overlap by a day (B's server work is independent of CSS).

---

## 9. Risks & non-goals

**Risks**

| Risk | Mitigation |
|------|------------|
| **Live UI invents state** (the P7 nightmare: spinner where truth should be) | Every animated element binds to a stream field; staleness banner is computed, not assumed; `reconstructed` mode is labeled. About page documents the stream schema. |
| **SSE/watcher becomes "a daemon"** — violates static-is-a-feature | Watcher is opt-in (`make desk-live`), stdlib only, dies with Ctrl-C. `file://` polling and static-snapshot tiers keep the desk fully usable with zero processes. |
| **Instrumenting dispatch.sh couples UI to orchestrator internals** | Writer is additive, env-guarded, fails open (`|| true`); dispatch behavior unchanged. Event stream is a *product* of dispatch, not an input to it. |
| **Motion bloat / craft over clarity** | Four-motion vocabulary cap (§3.5); reduced-motion + manual off; every effect has a text fallback that conveys the same fact. |
| **Log-file heartbeat reads transcripts by accident** | Metadata only: mtime + size + filename. Redaction law and the existing test (`run-experience-tests.sh` secret scan) extend to `live.json`. |
| **Scope creep: desk becomes a control surface** | Non-goal (below). No dispatch buttons, no kill switches, no human-gate bypass. |

**Non-goals (v2, explicitly)**

- No dispatch/trigger/kill from the browser. Chat + `dispatch.sh` remain the only control plane.
- No second orchestration stack, no new agent runtime.
- No agent transcript viewing (filename-only law stands).
- No skill auto-promote UI; promotion stays PR-only.
- No cloud/SaaS sync, no multi-operator presence, no auth layer.
- No GitHub Issues/Projects replacement.
- No changes to PMI gates, join law, or `index.json` schema v2 semantics.

---

## 10. Open questions for the owner

1. **Session identity:** is slugified-plan-name + start-ts an acceptable session id, or do you want dispatch to mint UUIDs (more robust, uglier deep links)?
2. **Event granularity:** is `seat_progress` (mid-run notes) worth a small agent-side convention (e.g. seats echo `FLEET_EVENT: …` lines the writer scrapes), or is dispatch/exit/rate-cap enough for v2? My recommendation: ship B without it; add in C if the lanes feel mute.
3. **Retention:** cap `logs/fleet-events.jsonl` (rotate per session file vs one append-only log)? Per-session files (`fleet-events/<session>.jsonl`) make replay routing trivial; one file makes tailing trivial. I lean per-session.
4. **Sound:** opt-in ambient tick on settle/failover — delightful or annoying? Default off either way.
5. **Paperclip overlay:** when the governance server is up, should heartbeats overlay the lanes (source 6) in v2, or stay out until a later wave? My lean: later wave — keep B's dependency list at zero.
6. **Home banner vs dedicated tab:** is a Flight Line banner on Home enough ambient awareness, or do you want the watcher to optionally `open` the browser automatically on `session_start`? (I'd not auto-open; the CLI prints the link.)

---

## Appendix A — Consistency with the freeze

| SYNTHESIS law | This proposal |
|----------------|---------------|
| Trail = atom, wave = group | Live lane **is** a trail pre-settle; settles into the same atom. No wave-object store invented. |
| Dual scope one grammar | Flight Line is global-first; company scope filters lanes by joined trails only after settle (live seats are pre-join). |
| Static is a feature | Three-tier liveness; file:// always works. |
| Honesty as chrome | Staleness, degraded, reconstructed-replay are first-class UI states with words, not just color. |
| No daemon / no SaaS | Watcher is opt-in stdlib; cloud deferred. |
| Redaction law | `live.json` passes the same redactor; tests extended. |
| `make experience` / `make desk` | Unchanged; `make desk-live` added. |
