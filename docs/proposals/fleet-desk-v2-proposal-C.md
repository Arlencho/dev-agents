# Fleet Desk v2 - Proposal C

**Seat:** C (independent design; not merged with A/B)  
**Date:** 2026-07-29  
**Brief:** [`fleet-desk-v2-BRIEF.md`](fleet-desk-v2-BRIEF.md)  
**Data law (atoms unchanged):** [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md)  
**Operator surfaces today:** [`docs/experience.md`](../experience.md), [`docs/experience-data.md`](../experience-data.md)  
**Session modes:** [`docs/session-modes.md`](../session-modes.md)  
**Status:** DESIGN ONLY - no product UI implementation in this wave

---

## 1. Name

| Field | Proposal C |
|-------|------------|
| **Product name** | **Fleet Desk** (keep) |
| **v2 moniker (internal)** | **Desk + Floor** - same product, two modes of attention |
| **Historical surface** | **Almanac** - settled projection (`make experience`) |
| **Live surface** | **Ops Floor** - motion while dispatch / Conductor runs |
| **Tagline** | *See the fleet move. Keep the record honest.* |
| **One-liner** | Almanac answers “what did we learn?”; Ops Floor answers “what is running, serial or parallel, and what am I waiting on?” |

**Why not rename.** Operators already know Fleet Desk, `make desk`, and schema v2. Renaming burns recognition for zero product gain. The missing product is a **second attention mode**, not a new brand.

---

## 2. North-star UX

### Who

The fleet owner (and later any co-pilot operator) who:

1. lives in **chat / CLI** as the control plane (Conductor, Wave, Auto session modes),
2. triggers `dispatch.sh` (or Conductor one-shots under `wave-plans/conductor/`),
3. currently gets only an opaque host status like “1 command still running”,
4. after waves, runs `make experience` to read trails, PMI, skills - the Almanac.

### 30-second story (happy path)

1. Chat: *Activate Conductor* → packet → human **go**.  
2. Operator runs `make desk-live` once (or has it already up). Browser opens **Ops Floor**.  
3. Floor shows a **single-lane chain**: role seat lighting up → optional critic → settle.  
4. Later: *Activate Wave* → multi-line plan → **trigger**. Floor flips to **wave lanes**: N seats concurrent, failover chrome when a provider cools, critic seats as paired tracks on shared branches.  
5. When the run ends, Floor freezes to **Settled** and links into Almanac trail pages (schema v2 JSON). No inventing mid-run outcomes.

### 30-second story (failure honesty)

Dispatch dies, SSH drops, or live stream goes quiet. Ops Floor does **not** keep animating green. Chrome becomes **STALE · last event 47s ago · source: run.json mtime** with a one-line next action: re-run `make desk-live` or check `./scripts/workers-status.sh`. Almanac is untouched until the next successful `make experience`.

### Operator questions → surface

| Question | Surface |
|----------|---------|
| What is running *right now*? | Ops Floor |
| Serial (Conductor) or parallel (Wave)? | Ops Floor mode glyph + layout |
| What am I waiting on? | Floor “blockers” strip |
| What did wave 19 ship? | Almanac Work (group-by-wave) |
| Is this role playbooked? | Almanac Roles + PMI |
| Can I promote a skill from the desk? | No (PR-only; About says so) |

---

## 3. Visual system

### Stance

**Dark-first ops theater** for Live; **paper/ink Almanac** for history. Same type scale and status grammar so the brain reuses habits; different ambient density so you never confuse a *prediction* with a *record*.

Reference peers (spirit, not clone):

| Peer | Take |
|------|------|
| **Linear** | Ruthless hierarchy, quiet motion, issue density without clutter |
| **Vercel dashboard** | Deployment “live → ready” honesty; status as first-class chrome |
| **Raycast** | Instant feel, keyboard, progressive panels |
| **Observability (Grafana-lite)** | Time axis + series lanes - adapted to roles, not hosts |
| **Aircraft PFD (conceptual)** | Primary flight display: mode, attitude, waiting-on - not a wall of tables |

Explicitly **not** cloned: neon cyberpunk dashboards, fake neural graphs, vanity “agent IQ” gauges.

### Palette (tokens)

```text
Ops Floor (dark default)
  --void        #0a0b0f
  --panel       #12141a
  --panel-2     #1a1d26
  --ink         #e8e6df
  --muted       #8b8d9a
  --line        #2a2d38
  --accent      #6ea8ff     /* electric blue - live only */
  --run         #5b8def     /* active seat pulse */
  --ok          #3ecf8e     /* settled success + label */
  --warn        #e0b44a     /* rate-cap / cooldown / waiting */
  --bad         #f07178     /* failed / blocked + label */
  --stale       #6b6e7a     /* offline / no heartbeat */

Almanac (keep Phase 1 paper/ink; polish only)
  --bg paper, --accent amber-brass (existing site.css)
  Live accent never appears on settled Almanac chrome
```

Light mode: invert panels; keep status hues with WCAG contrast. `prefers-color-scheme` + explicit toggle stored in `localStorage` for Live only.

### Type

| Role | Stack |
|------|-------|
| UI | `Inter` if present, else system UI sans |
| Identity / section | tight tracking, 600-700 weight |
| Data / SHAs / task ids / branches | `ui-monospace` / SF Mono / Menlo |
| Scale | 12 / 13 / 14 / 16 / 20 / 28 - no decorative display faces |

### Density

- **Home Almanac:** card + strip, scan in &lt; 10s.  
- **Work:** table-first (law).  
- **Ops Floor:** spatial first (lanes / chain), table second (event log disclosure).  
- Max two accent colors on screen at once (run + one of ok/warn/bad).

### Motion language

| Signal | Motion | Reduced motion |
|--------|--------|----------------|
| Seat active | soft breathing opacity 0.55→1 on border (1.6s) | static “ACTIVE” badge |
| Wave fan-out | lanes populate left→right stagger ≤ 120ms | instant populate |
| Serial step | vertical highlight moves to next node | arrow + “step n/m” |
| Rate-cap / cooldown | amber hash-shimmer on seat chip 1s then hold | “RATE-CAPPED” text |
| Settled | pulse stops; chip locks; checkmark + status word | same without fade |
| Stale source | freeze all motion; grey veil + STALE banner | banner only |

**Rule:** motion encodes *lifecycle*, never decoration. No particle fields, no continuous full-page parallax.

### Craft details (progressive)

1. **Glass panels only on Floor** (1px border + subtle blur); Almanac stays matte paper.  
2. **Mode ribbon** under nav: `ALMANAC · FLOOR` with keyboard `g then a` / `g then f` (Raycast-like chords; documented on About).  
3. **Empty Floor** teaches: diagram of “dispatch writes `logs/dispatch-live/current.json` → Floor tails it”.  
4. **Ambient run clock** top-right: wall time of run start + elapsed (honest; not ETA invent).  
5. **Depth:** z-layered panels on Floor only; Almanac flat for `file://` friendliness.

---

## 4. IA + wireframes

### 4.1 Routes

Keep Phase 1 Almanac routes. Add Live.

| Route | Mode | Purpose |
|-------|------|---------|
| `/` | Almanac | Global home (flow strip + recent + roles/skills) |
| `/company/<id>/` | Almanac | Company home |
| `/work/` · `/work/flat/` | Almanac | Work by wave / flat |
| `/trail/<task_id>/` | Almanac | Trail detail (evidence) |
| `/role/<role>/` | Almanac | Usage + PMI |
| `/skill/<id>/` · `/learning/<slug>/` | Almanac | Packs / learnings |
| `/conductor/` | Almanac | Settled conductor trails |
| `/about/` | Both | Sources, honesty, live data gaps |
| **`/live/`** | **Floor** | **Ops Floor - concurrent motion** |
| **`/live/run/<run_id>/`** | **Floor** | One run detail + replay when settled |
| **`/live/history/`** | **Floor** | Recent runs index (from live event archives) |

Nav always:

```text
Home · Work · Live · Skills · Learn · Roles · Conductor · About
scope: Global | olympus | …
mode: Almanac | Floor     ← only relevant chrome; Floor ignores company filter for active run
```

Click budget (brief P2): trail or skill ≤ 3 from global home; **active seat → event row → handoff (after settle)** ≤ 3 from Floor.

### 4.2 Global home (Almanac restyle - progressive disclosure)

```
┌─ Fleet Desk ──────────────────── ● Global | olympus | … ──── ALMANAC | Floor ─┐
│  generated <ts> · make experience · read-only                                  │
│                                                                                │
│  ┌ Flow (glance) ──────────────────────────────────────────────────────────┐   │
│  │  [Companies n] ──► [Waves n] ──► [Trails done%] ──► [Critic pairs]      │   │
│  │  hover any node → counts only; click → deep page                         │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                │
│  ┌ Live teaser (if run.json fresh < 120s) ──────────── Open Ops Floor → ───┐   │
│  │  WAVE 21 · 3/5 seats active · serial? no · waiting: frontend-critic     │   │
│  │  else: “No live run · make desk-live after dispatch”                    │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                │
│  Recent work (compact rows) · Roles strip · Skills · Learn · Watchlist         │
└────────────────────────────────────────────────────────────────────────────────┘
```

**P1 fix:** Flow strip replaces “wall of tables” as the first scan; tables remain one click down.

### 4.3 Ops Floor - Live (primary new surface)

```
┌─ Fleet Desk · OPS FLOOR ───────── LIVE · source ok · age 1.2s ──── Almanac | ●Floor ─┐
│  Run 2026-07-29T18:04Z · wave-plans/19-foo.plan · mode: WAVE                         │
│  Elapsed 04:12 · seats 5 · active 3 · done 1 · failed 0 · waiting 1                  │
│                                                                                      │
│  ┌ Mode: WAVE (parallel) ─────────────────────────────────────────────────────────┐  │
│  │  time →                                                                        │  │
│  │  web-frontend     ████████████● running · kimi · mac-mini-1 · 3m12s            │  │
│  │  go-backend       ████████████● running · claude · localhost · 2m58s           │  │
│  │  db-architect     ███████✓ done · 1m40s                                        │  │
│  │  frontend-critic  ····· waiting on producer branch feat/…                      │  │
│  │  docs-writer      ████● running                                                │  │
│  └────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                      │
│  Blockers: frontend-critic ← shared branch not head-complete yet                     │
│  Caps: kimi cooldown 12m left · workers: mac-mini-1 3/4 agents                       │
│                                                                                      │
│  ▾ Event log (newest first)                                                          │
│    18:08:02  ratecap  web-frontend  kimi → failover claude                           │
│    18:07:11  start    go-backend    pid 4421                                         │
│    18:07:11  start    web-frontend  pid 4419                                         │
│    18:07:10  run_start wave=19 plan=…                                                │
│                                                                                      │
│  [Open plan] [Workers status] [Provider scorecard] [Settle → rebuild Almanac]        │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.4 Ops Floor - Conductor (serial) contrast (P5)

```
┌─ OPS FLOOR · mode: CONDUCTOR (serial chain) ─────────────────────────────────────────┐
│  Plan: wave-plans/conductor/fix-abarranges.plan · single seat expected               │
│                                                                                      │
│         ┌──────────────┐      ┌──────────────┐      ┌──────────────┐                 │
│  Pin ──►│ web-frontend │ ───► │ (critic if   │ ───► │ Verify /     │                 │
│         │ ● ACTIVE     │      │  planned)    │      │  human merge │                 │
│         │ 2m14s        │      │  dim         │      │  dim         │                 │
│         └──────────────┘      └──────────────┘      └──────────────┘                 │
│                                                                                      │
│  Waiting on: seat exit + handoff jsonl                                               │
│  Not a wave: only one task_id in this run - layout forces chain, never lanes         │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

**Distinctiveness rule:** WAVE always uses **horizontal time lanes**. CONDUCTOR always uses **vertical step chain**. Layout alone answers serial vs parallel without reading labels (labels still required for a11y).

### 4.5 Work index (Almanac - polish only)

Keep SYNTHESIS normative group-by-wave. v2 adds:

- Wave section header shows **settled** lane mini-spark (n seats, done/fail) from Almanac data only.  
- Link “Replay motion” → `/live/run/<id>/` when a matching archived run exists; else hidden (no fake).

### 4.6 Trail detail

Unchanged atoms. v2 chrome:

- If trail belongs to a known live run: breadcrumb `← Floor run · wave N · trail`.  
- Status pills stay text+color.  
- No live polling on trail pages (settled only).

### 4.7 Roles / Skills / Learn / Conductor / Company / About

| Page | v2 delta |
|------|----------|
| Roles | Density polish; PMI expand stays; optional “last seen on Floor” timestamp if role appeared in live archive (honest null) |
| Skills / Learn | Visual restyle only; still no promote button |
| Conductor (Almanac) | List settled conductor trails; link to Floor history filtered `mode=conductor` |
| Company | Same dual-scope grammar; Floor global-only for active run (company filter does not invent per-company live state) |
| About | Dual-source diagram: Almanac JSON vs live stream; redaction law; how to open Floor after dispatch |

---

## 5. Live observability design

### 5.1 Product law

| Law | Meaning |
|-----|---------|
| **Control plane stays chat/CLI** | Floor never dispatches, never promotes skills, never merges PRs |
| **Observe, don’t invent** | Every seat state maps to a written event or derived timeout |
| **Transcripts stay off-page** | Only log *filenames*, durations, exit codes, provider names - never agent bodies |
| **Paperclip optional** | Existing `fleet-status.sh` heartbeats may enrich; core Floor works without Paperclip |
| **Almanac remains source of post-hoc truth** | Handoffs + schema v2; live is *ephemeral motion* |

### 5.2 Data sources (grounded in this repo)

| Source | Exists today | Floor use |
|--------|--------------|-----------|
| `scripts/dispatch.sh` WAVE_PIDS / RESULT_* | Yes (in-memory) | **Must emit** live events (gap today) |
| `wave-plans/**/*.plan` | Yes | Run identity, mode hint (conductor path vs wave path) |
| `wave-plans/**/handoffs/*.{jsonl,md}` | Yes | Settle events; join to Almanac trails |
| `logs/provider-state/*.cooldown`, `ratecap.log` | Yes | Cap chrome |
| `scripts/workers-status.sh` / SSH pgrep counts | Yes | Worker load strip (optional poll) |
| `scripts/provider-scorecard.sh` | Yes | Linked CLI; optional JSON export later |
| `scripts/fleet-status.sh` / Paperclip API | Optional | Heartbeat ON/OFF badge only if reachable |
| `~/dev/agent-logs/*.log` | Yes | **Filename + mtime only** - never tail body into browser |
| schema v2 `index.json` | Yes | Almanac + “settled” merge after run |

### 5.3 Proposed live artifact (schema addition - see §7)

**Directory (gitignored):** `logs/dispatch-live/`

| File | Writer | Reader |
|------|--------|--------|
| `current.json` | `dispatch.sh` (atomic rewrite) | Ops Floor poll / SSE |
| `events.jsonl` | `dispatch.sh` append-only | Floor event log + replay |
| `archive/<run_id>.json` | dispatch on run end | `/live/run/<id>/`, history |

**`current.json` shape (illustrative):**

```json
{
  "schema": "fleet-live/1",
  "run_id": "20260729T180710Z-19-foo",
  "status": "running",
  "mode": "wave",
  "plan_path": "wave-plans/19-foo.plan",
  "wave": 19,
  "started_at": "2026-07-29T18:07:10Z",
  "updated_at": "2026-07-29T18:08:02Z",
  "seats": [
    {
      "task_idx": 0,
      "role": "web-frontend",
      "branch": "feat/x",
      "state": "running",
      "provider": "kimi",
      "worker": "mac-mini-1",
      "pid": 4419,
      "started_at": "...",
      "duration_s": 192,
      "last_event": "start"
    }
  ],
  "blockers": [
    {"kind": "waiting_on_producer", "role": "frontend-critic", "detail": "branch feat/x"}
  ],
  "caps": [{"vendor": "kimi", "cooldown_remaining_s": 720}],
  "honesty": {
    "source": "dispatch.sh",
    "stale_after_s": 30,
    "notes": []
  }
}
```

**Event types (jsonl):** `run_start` · `seat_start` · `seat_exit` · `ratecap` · `failover` · `unavailable` · `blocked` · `handoff_written` · `run_end` · `stale_mark` (watcher only).

### 5.4 Update cadence

| Channel | Cadence | When |
|---------|---------|------|
| **A. File poll** (Phase B default) | 1s browser fetch of `current.json` via local static/SSE server | Zero new deps; works offline |
| **B. SSE** (Phase B+) | push on each jsonl append | Smoother; still local-only |
| **C. Watcher CLI** | `make desk-live` runs tiny Python/stdlib HTTP on `127.0.0.1:8766` serving Floor + live JSON | Operator one command |
| Stale rule | if `updated_at` age &gt; 30s while `status=running` → UI **STALE** | Honesty (P7) |

No cloud relay in v2 proposal. No always-on daemon beyond the operator-started local server.

### 5.5 Serial vs wave visualization (P4 / P5)

| Signal | Conductor (serial) | Wave (parallel) |
|--------|--------------------|-----------------|
| Detection | plan under `wave-plans/conductor/` **or** single task in run | multi-task same wave number / multi seat concurrent |
| Layout | vertical step chain | horizontal swimlanes (role × time) |
| Motion | one ACTIVE node; predecessors check; successors dim | multiple ● concurrent |
| Critic | next step when plan lists critic seat | paired lane; “waiting on producer” blocker if branch pairing law |
| Failover | amber chip on same node (provider swap) | same, per lane |
| End | chain complete → Settled | all lanes terminal → Settled |

### 5.6 “What am I waiting on?”

Blockers strip priority (first match wins display rank):

1. Human gate (if ever recorded) - rare on Floor; usually pre-dispatch  
2. Rate-cap / cooldown vendor  
3. Worker at `max_agents`  
4. Critic waiting on producer branch  
5. Seat running with no event &gt; N seconds (soft wait, labeled *quiet*, not failed)  
6. Run STALE  

### 5.7 History replay (Phase C)

Archived `run_id` replays events on the same layout at 4× / 1× / step. Replay banner: **REPLAY · not live**. Never mixes with `current.json`.

---

## 6. CLI ↔ Desk bridge

Exact operator steps (P6).

### 6.1 One-time / session start

```bash
# Terminal A - live view (blocks; Ctrl-C stops server only)
make desk-live
# → builds static Floor shell if needed
# → serves http://127.0.0.1:8766/live/
# → tails logs/dispatch-live/current.json
# → opens browser if make desk-live-open
```

### 6.2 Conductor path

```text
Chat: Activate Conductor → packet → plan under wave-plans/conductor/
Human: go
CLI:  ./scripts/dispatch.sh <repo> wave-plans/conductor/<name>.plan
UI:   Ops Floor auto-detects current.json → CONDUCTOR layout
After: make experience-open   # Almanac refresh for trail evidence
```

### 6.3 Wave path

```text
Chat: Activate Wave → plan → human trigger
CLI:  ./scripts/dispatch.sh <repo> wave-plans/<plan>.plan
      # optional: --auto between waves
UI:   Floor shows WAVE lanes; wave N header tracks CURRENT_WAVE
After each wave: Floor may show “wave complete - next wave armed/auto”
After full run:  make experience-open
```

### 6.4 Companion CLIs (unchanged roles)

| Command | Role next to Floor |
|---------|---------------------|
| `make scorecard` | Provider caps detail (Floor shows summary only) |
| `./scripts/workers-status.sh` | SSH/disk truth |
| `make fleet-status` | Paperclip/Ollama optional strip |
| `make evidence` | Quality scorecard - Almanac-adjacent |
| `make experience` | Rebuild settled Almanac |

### 6.5 Bridge rules

1. Chat remains control plane; Floor never requires focus to “approve” dispatch.  
2. If Floor is not open, dispatch still works (live files are side effects).  
3. If dispatch predates live emitters, Floor shows empty + “upgrade dispatch for live events”.  
4. `file://` Almanac still works offline; Floor **requires** local server (fetch/SSE). About documents this honestly.

### 6.6 Suggested Make targets (proposal only)

```make
desk-live:        ## Serve Ops Floor + poll dispatch-live (stdlib)
desk-live-open:   ## desk-live + open browser
desk:             ## keep = Almanac build (make experience)
```

---

## 7. Data / API gaps

### 7.1 What schema v2 already gives (do not break)

Trails, waves, critic_pairs, PMI P0-P3, gh enrichment, join rules, redaction, skill history. **v2 proposals must not casually destroy this contract** (brief). Almanac continues to read `site/experience/data/index.json` only.

### 7.2 Gaps (why Floor cannot ship on v2 alone)

| Gap | Why it hurts |
|-----|--------------|
| No mid-run seat state in git artifacts | Handoffs appear **after** task exit; during run Almanac is blind |
| `dispatch.sh` RESULT_* is process-local | Nothing on disk for a browser to poll today |
| No `run_id` linking plan → seats → handoffs | Replay and “open trail from Floor” need a stable id |
| Provider cooldown is CLI-shaped | Floor needs JSON projection of `logs/provider-state` |
| Worker load is SSH-on-demand | Optional; not in schema v2 |
| Conductor vs Wave mode not a first-class field on handoffs | Inferable from path; should be explicit on live run |
| No event log | Cannot replay motion or audit failover timing |

### 7.3 Proposed additions

**A. Live schema `fleet-live/1`** (files under `logs/dispatch-live/`, gitignored) - §5.3.  
**B. dispatch.sh emitters** (small, fail-open): write/update `current.json` on seat start/exit/ratecap/run_end; never abort dispatch if write fails (log warning).  
**C. Optional Almanac additive fields** (schema_version stays **2** if additive; bump only on break):

| Field | Where | Purpose |
|-------|-------|---------|
| `trails[].run_id` | handoff/jsonl when present | Join Floor archive → trail |
| `trails[].dispatch_mode` | `conductor` \| `wave` \| `unknown` | Almanac filters |
| `fleet_live` stub in index.json | `{supported, last_run_id, last_run_status}` | Home live teaser without reading logs |

**D. SSE endpoint** (local server only): `GET /api/live/stream` reads jsonl, never exposes transcript paths beyond basename.

**E. Migration honesty**

| Phase | Behavior |
|-------|----------|
| Pre-emitter dispatch | Floor empty state; Almanac unchanged |
| Emitter shipped, old runs | No archive; no fake replay |
| Emitter + archive | Replay works; Almanac gains run_id when handoffs include it |
| Breaking live schema | bump `fleet-live/N`; Floor refuses unknown with chrome message |

**Not proposed:** replacing schema v2, cloud event bus, embedding `~/dev/agent-logs` bodies, skill write APIs.

---

## 8. Phased ship plan

Rough effort: **S** &lt; 1 day · **M** 1-3 days · **L** 3-7 days · **XL** &gt; 1 week (one focused engineer familiar with this repo).

### Phase A - Visual restyle on static Almanac only (no live yet)

| Item | Effort | Outcome |
|------|--------|---------|
| Token refresh (type scale, dark polish, flow strip on home) | M | Glanceable flow (P1) without new runtime |
| Work wave headers mini-stats from existing JSON | S | Wave as visual group, not only `<h2>` |
| Live nav item → placeholder page “Phase B” with CLI bridge docs | S | Sets expectation; honesty |
| A11y pass (focus, reduced motion already partial) | S | Non-regression |
| Tests: existing experience fixtures still green | S | |

**Exit:** `make experience` looks modern; still fully static; no dispatch changes.

### Phase B - Live tail (Ops Floor MVP)

| Item | Effort | Outcome |
|------|--------|---------|
| `fleet-live/1` writer hooks in `dispatch.sh` (fail-open) | M | Source of truth mid-run |
| `logs/dispatch-live/` gitignore + docs | S | |
| `make desk-live` stdlib server + poll `/live/` | M | CLI bridge (P6) |
| WAVE lanes + CONDUCTOR chain layouts | L | P4/P5 |
| Caps from provider-state + blockers strip | M | Waiting-on (P5/P7) |
| STALE chrome | S | P7 |
| Home live teaser if `current.json` fresh | S | Bridge Almanac↔Floor |
| Tests: synthetic current.json fixtures; no secret leakage | M | |

**Exit:** During a real wave, operator sees concurrent seats without reading chat status line alone.

### Phase C - History replay + enrichment

| Item | Effort | Outcome |
|------|--------|---------|
| Archive on run_end + `/live/history/` | M | |
| Replay scrubber | M | |
| Optional workers-status JSON snapshot into live | M | |
| Optional Paperclip badge (degraded if down) | S | |
| handoff `run_id` / `dispatch_mode` additive fields | M | Join Floor→Almanac |
| SSE instead of poll | M | Polish |

**Exit:** “Show me how wave 19 moved” works offline from archive.

### Sequencing note

Ship A before B so Almanac craft is not blocked on dispatch instrumentation. B is the owner’s #1 gap; protect it from scope creep (no React rewrite required: progressive enhancement on static shell + small JS for Floor only is enough).

---

## 9. Risks & non-goals

### Risks

| Risk | Mitigation |
|------|------------|
| Live UI invents “running” after crash | STALE timer; status from files only |
| dispatch write overhead / permission errors | fail-open emitters; never block seats |
| Parallel conflict: experience_build vs live server | separate ports; live does not write `site/experience/data/index.json` |
| Operator confuses Floor with control plane | copy + disabled actions; no buttons that look like Dispatch |
| Secrets in events | reuse redactor; never copy transcript bodies; test fixtures |
| Motion a11y | `prefers-reduced-motion`; status words always present |
| Scope explosion into second orchestrator | hard non-goal below |
| Paperclip coupling | optional strip only |

### Non-goals (v2 proposal)

- Replacing GitHub Issues / Projects  
- Skill auto-promote or dispatch-from-UI  
- Cloud SaaS ops dashboard  
- Embedding full agent transcripts  
- New orchestration stack beside `dispatch.sh` / session-modes  
- Changing PMI gates or join law in this wave  
- Requiring React/Next for Phase A-B (optional later if Almanac loves it)  
- Multi-operator multi-tenant auth  

---

## 10. Open questions for owner

1. **Emitter placement:** Is fail-open write from `dispatch.sh` into `logs/dispatch-live/` acceptable as the sole live source for Phase B, or do you want a side-car wrapper first?  
2. **Port / command:** Prefer `make desk-live` on `8766` beside optional Almanac `8765`, or one server with `/` Almanac + `/live/` Floor?  
3. **Critic waiting:** Should Floor infer “critic waits on producer” only from plan order, or only after branch pairing exists (handoff-time)? Mid-run pairing is weak without plan topology.  
4. **Conductor multi-step:** Today conductor is often one plan line. Should Floor show a **synthetic** verify step (human), or only seats that dispatch actually runs?  
5. **Retention:** How many archived runs under `logs/dispatch-live/archive/` (e.g. last 50 / 14 days)?  
6. **Home teaser:** Show live teaser on Almanac home when Floor server is **down** but `current.json` is fresh (read file via build), or only when desk-live is up?  
7. **Mobile:** Is Ops Floor desktop-only for v2 (recommended), or must lanes reflow to phones?  
8. **Vendor labels:** Live chrome will show mechanical provider names already in handoffs (`kimi` / `claude` / `grok`). Confirm that remains allowed on local Floor (not GitHub PR face).  

---

## 11. Evaluation self-check (brief §5)

| Criterion | Proposal C answer |
|-----------|-------------------|
| Progressive disclosure | Flow strip → Work/Floor → trail/events; ≤3 clicks |
| Live fleet motion | Ops Floor + dispatch emitters + serial/parallel layouts |
| Modern craft without vacuity | Dark Floor, motion = lifecycle, paper Almanac preserved |
| Feasibility | Builds on dispatch, provider-state, handoffs, stdlib server |
| A11y + honesty | Reduced motion, STALE, text+color status, no transcript dump |

---

## 12. Summary for SYNTHESIS

Proposal C keeps **Fleet Desk** and the Almanac data law, then adds **Ops Floor**: a local-first live surface that makes Conductor serial chains and Wave parallel lanes impossible to confuse, fed by a new fail-open `fleet-live/1` stream written by `dispatch.sh`. Phase A restyles static glanceability; Phase B ships the owner’s missing motion dashboard; Phase C replays history. Fancy motion is allowed only as lifecycle signal; degraded states are first-class chrome.

**Next:** owner SYNTHESIS across seats A/B/C → implementation waves (visual + live).
