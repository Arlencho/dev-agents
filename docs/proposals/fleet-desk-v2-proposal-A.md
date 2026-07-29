# Fleet Desk v2 — Proposal A: "Desk & Floor"

**Seat:** A (independent — written without reading seats B/C)
**Brief:** [`fleet-desk-v2-BRIEF.md`](fleet-desk-v2-BRIEF.md)
**Data law respected:** [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md) — trail = atom, wave = group, PMI gates, redaction, no auto-promote
**Status:** Design proposal only. No UI code, no `experience_data.py` changes in this wave.

---

## 1. Name

**Keep the product name: Fleet Desk.** It has operator muscle memory, docs, and a make target. Renaming the product to fix a visual problem is churn, not craft.

What v2 adds is a second *room* inside Fleet Desk:

| Room | Route | Nature | Mood |
|------|-------|--------|------|
| **The Almanac** | `/` and everything Phase 0/1 ships today | Record. Static, rebuilt on demand, honest history | Paper & ink, calm |
| **The Floor** | `/live/` | Motion. What the fleet is doing *right now* while dispatch runs | Dark ops room, ambient |

One product, two rooms, one data spine. The tagline extends:

> *What the fleet is doing, did, learned, and now knows how to do.*

"Desk & Floor" is the internal design name for this proposal, not user-facing chrome.

---

## 2. North-star UX (the 30-second story)

**Who it is for:** one operator (the fleet owner) driving multi-seat dispatch from a chat CLI, plus occasionally a collaborator being shown "what this fleet actually is."

**The story:**

You are in chat. You say `go`. The orchestrator runs `dispatch.sh`. Today your only feedback is *"1 command still running."*

In v2: a browser tab you opened once this morning (`make desk-live`) wakes up by itself. The Floor shows **wave 2 fan out**: four seat lanes slide in from the left — `web-frontend`, `api-designer`, `docs-writer`, `frontend-critic` — each with a breathing activity pulse, elapsed timer, vendor chip, and the branch it owns. One seat hits a rate-cap: its lane flashes amber, shows `ratecap · cooldown 22m · failing over →`, and a new lane forks below it with the fallback provider. Three lanes converge into green `done` caps; the critic lane keeps running. You glance for **four seconds**, know exactly what you are waiting on, and go back to chat.

When the wave ends, the Floor's lanes freeze into a timeline card with a **"Open in Almanac →"** link. You run `make experience`; the same tasks are now trails on the Work page, grouped by wave, with handoff evidence — the record the Floor just watched being written.

**Three promises:**

1. **Glance answers "what is moving and what am I waiting on?"** in ≤ 5 seconds, zero clicks.
2. **Depth is ≤ 3 clicks:** Floor lane → trail detail → handoff evidence. Almanac home → wave → trail. Back is always a visible breadcrumb.
3. **The UI never claims what the files don't prove.** A lane is "running" only because an event said so and a heartbeat is fresh; staleness is loud chrome, not silence.

---

## 3. Visual system

### 3.1 Direction

Two moods, one system. The Almanac stays close to the Phase 0 freeze (paper/ink, `prefers-color-scheme`) but gets real typographic and spatial craft. The Floor is **dark-first always** — an ops room is dark; it also makes ambient motion readable without being loud.

**Reference peers (study, do not clone):**

| Peer | Take | Leave |
|------|------|-------|
| Linear | Density, keyboard-first, restrained motion (150–200 ms), crisp dark surfaces | Their brand purple, SaaS chrome |
| Vercel deploy view | The live build-step tail: rows that stream state changes with timestamps | Their global nav weight |
| Raycast | Command palette as primary navigation; instant filtering | macOS-only styling assumptions |
| Grafana | Honest degraded/stale states as first-class visuals | Dashboard-grid sprawl |
| Datadog trace waterfall | Horizontal spans with duration encoded as length | Enterprise clutter |

### 3.2 Tokens

```css
/* One token sheet, two themes. Floor forces .theme-floor (dark). */
--ink:        light-dark(#16181d, #e8eaf0);   /* text */
--paper:      light-dark(#fafaf8, #0e1015);   /* bg — Almanac */
--floor-bg:   #0a0c11;                        /* bg — Floor, always dark */
--surface:    light-dark(#ffffff, #151821);   /* cards */
--hairline:   light-dark(#e4e4e0, #23262f);
--accent:     #4cc2ff;      /* one signal color: electric cyan; links, focus, live pulse */
--ok:         #3fb96c;      /* always paired with the word "done" */
--fail:       #e5534b;      /* always paired with the word "failed" */
--warn:       #d9a03c;      /* ratecap / retry / stale — always with text */
--muted:      light-dark(#6b7280, #8b91a0);
```

- **Status is never color-only** (a11y law): every pill carries its word — `done` `failed` `ratecap` `stale`.
- **One accent.** Cyan is "live/interactive." Everything else is grayscale + the three status hues.

### 3.3 Type

- **UI text:** system sans stack (unchanged from freeze — zero webfont weight, instant paint).
- **Data:** system mono for SHAs, branches, task ids, timers, event lines. On the Floor, mono is the *dominant* voice — timers, lane labels, event tail — which reads "instrument," not "brochure."
- Scale: 13 px dense tables / 15 px body / 20–28 px page titles. Tabular numerals (`font-variant-numeric: tabular-nums`) on all timers and counts so nothing jitters as it ticks.

### 3.4 Density & space

- Almanac: current table-first density kept; add a consistent 8 px spatial grid, 1 px hairline dividers instead of boxed borders, and a max-width column (~1100 px) so wide screens don't smear tables.
- Floor: full-bleed. Lanes are the layout; chrome is a thin top bar + right event tail.

### 3.5 Motion language

Motion has exactly **three jobs** here; anything else is decoration and gets cut.

| Job | Motion | Spec |
|-----|--------|------|
| **"This is alive"** | Breathing pulse on active lane dot; subtle 2 px progress shimmer on the lane bar | 2.4 s ease-in-out loop, opacity 0.5→1.0; CSS only |
| **"Something changed"** | New event row slides into the tail; lane state cap snaps in with a 180 ms scale-fade | ≤ 200 ms, `ease-out`, no bounce |
| **"You navigated"** | Cross-page: none (MPA, instant). In-page disclosures: 150 ms height ease | Never block reading |

- `prefers-reduced-motion: reduce` → pulses become static filled dots, slides become instant appearance, shimmer removed. **State is always also encoded in text + shape, so motion carries zero exclusive information.**
- **Fancy allowed, honesty first:** the wave fan-out animation (lanes sliding out from the dispatch spine) is the one "wow" moment, and it is driven purely by real `task_start` events — it can never animate a task that didn't start.

### 3.6 Empty states teach (kept and extended)

Every empty surface names the next command. New for the Floor:

```
The Floor is quiet.
No dispatch events since 2026-07-29 14:02 (last: wave 19 · done).
▸ Start one:  chat → "Activate Wave" → go
▸ Or replay:  [Replay wave 19 →]
```

---

## 4. IA + wireframes

### 4.1 Sitemap

```
Fleet Desk
├── /               Home (Almanac)          ── global; scope chip
├── /live/          The Floor (Live Ops)    ── NEW; auto-follows newest dispatch
│   └── /live/replay/<dispatch_id>/         ── NEW Phase C; history replay
├── /work/          Work index (by wave | flat)
├── /trail/<id>/    Trail detail
├── /role/<role>/   Role + PMI
├── /skill/<id>/    Skill detail
├── /learning/<slug>/
├── /conductor/     Conductor trails + (NEW) last conductor chain strip
├── /company/<id>/  Company home
└── /about/         Sources, join rules, PMI, event schema, honesty rules
```

Nav (always): `Home · Floor · Work · Skills · Learn · Roles · Conductor · About` + scope chip `Global | olympus | …`. The **Floor** nav item carries a live dot when events are fresh — visible from any Almanac page.

Keyboard: `g h` home, `g f` floor, `g w` work, `/` filter, `⌘K` command palette (Phase A nice-to-have, palette is progressive enhancement — every target is also a plain link).

### 4.2 Home (Almanac, restyled — same data contract)

```
┌ Fleet Desk ────────────────────────── ● Global | olympus | safeplace ┐
│ generated 14:02 · make experience · read-only        ● Floor: quiet │
│                                                                      │
│  19 trails   89% done · n=18   4 critic pairs   7 waves   3 vendors  │  ← stat strip
│                                                                      │
│  ┌ Latest wave ── wave 19 · 4 tasks · all done ──── [Work →] ─────┐  │
│  │ ✓ done  web-frontend    feat/…-A     14:01   reviewed ✓        │  │
│  │ ✓ done  frontend-critic feat/…-A     14:02                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  Companies  [olympus n=6] [safeplace n=2] [aegis ° placeholder]      │
│  Roles      web-frontend P2 n=8 · docs-writer P3 n=5   [Roles →]     │
│  Skills 12  Learnings 7 (2 promoted)  Watchlist 3      [Learn →]     │
└──────────────────────────────────────────────────────────────────────┘
```

Changes vs Phase 1: stat strip promoted to the top as the glance layer; "Latest wave" card replaces the flat recent-trails list (wave is the operator's mental unit); Floor status chip in the header. All fields already exist in schema v2.

### 4.3 The Floor (Live Ops) — the new surface

**Wave mode (parallel fan-out):**

```
┌ THE FLOOR ─────────────── dispatch d-20260729-1831 · wave 2 of 3 ────┐
│ ● LIVE  heartbeat 4s ago      plan: wave-plans/checkout.plan          │
│                                                                       │
│  spine ┬─ fan-out ────────────────────────────────── convergence ─┐   │
│        │                                                              │
│  ▶ web-frontend   ●●● 04:12  feat/checkout-ui      [claude-seat]      │
│    ████████████████████▒▒▒░ activity (log bytes, proxy)               │
│  ▶ api-designer   ●●● 03:58  feat/checkout-api     [seat-2]           │
│    ██████████▒░░░░░░░░░░░░░                                           │
│  ⚠ docs-writer    ratecap → failover                                  │
│    └─▶ docs-writer ●● 00:41  feat/checkout-docs    [seat-3, retry 1]  │
│  ✓ frontend-critic done 02:10 · exit 0 · reviewed feat/checkout-ui    │
│                                                                       │
│  WAITING ON: web-frontend, api-designer, docs-writer(retry)  ETA: —   │
│                                                                       │
│  Event tail ────────────────────────────────────────────────────────  │
│  18:35:41 task_exit    frontend-critic exit=0 dur=130s                │
│  18:35:02 task_start   docs-writer (failover seat-3, retry 1)         │
│  18:34:58 task_ratecap docs-writer seat-2 cooldown→19:04              │
│  ▸ older…                                                             │
└───────────────────────────────────────────────────────────────────────┘
```

**Conductor mode (serial chain) — deliberately a different silhouette:**

```
┌ THE FLOOR ────────────── conductor c-20260729-1840 · single chain ───┐
│ ● LIVE  heartbeat 2s ago   plan: wave-plans/conductor/abarranges.plan│
│                                                                       │
│   packet ──▶ dispatch ──▶ ▶ web-frontend ──▶ (critic?) ──▶ handoff    │
│                            ●●● 01:22                                  │
│                            feat/fix-abarranges-space                  │
│                            activity ███████▒░░  log 48 KiB ↑          │
│                                                                       │
│  WAITING ON: web-frontend (1 seat, serial)                            │
└───────────────────────────────────────────────────────────────────────┘
```

The visual grammar makes **P5** unmistakable: *waves are vertical stacks of horizontal lanes (many at once); conductor is one horizontal chain of steps (one at a time)*. You know which mode you are in before you can read a single label.

**Lane anatomy** (each maps to fields the events stream carries — §6):

- State glyph + word: `▶ running` `✓ done` `✗ failed` `⚠ ratecap` `↻ retry` `◌ queued` `? stale`
- Role name (bold), elapsed mono timer, branch (mono), seat/vendor chip (mechanical provenance — allowed; it is already in handoffs)
- Activity bar: **agent-log byte growth**, explicitly labeled `proxy` — it shows the process is producing output, it does *not* claim progress percent. Tooltip: "log size, not progress."
- Failover fork: rate-capped lane stays visible (amber, struck), fallback lane forks beneath it — failure history is chrome, not erased.
- Click lane → after handoff lands: `/trail/<task_id>/`. Before it lands: a lane sheet with the event history for that task + log *filename* (never content).

**"What am I waiting on?"** is a permanent single line — the set-difference of `task_start` minus `task_exit`, plus queued waves remaining. This one line is the whole reason the surface exists; it is never scrolled away.

### 4.4 Work index (restyled, same contract)

```
┌ Work ── scope: Global ── filter: role ▾ status ▾ wave ▾ ── by wave|flat ┐
│ ── Wave 19 · 4 tasks · 4 done · 1 pair ──────────────── [Replay ▶] ── │
│  ✓ done   web-frontend    black-aces  feat/…  14:01  reviewed ✓        │
│  ✓ done   frontend-critic black-aces  feat/…  14:02                    │
│ ── Wave 17 · 2 tasks · 1 done · 1 failed ────────────── [Replay ▶] ── │
│  ✗ failed api-designer    olympus     feat/…  (exit 1)                 │
└────────────────────────────────────────────────────────────────────────┘
```

Additions: per-wave summary chips in the section header (done/failed/pairs at a glance) and a **Replay ▶** affordance (Phase C) that opens `/live/replay/<dispatch_id>/` when an events file exists for that wave — history replay uses the *same* Floor renderer at a chosen speed.

### 4.5 Trail detail (restyled, plus timeline strip)

```
┌ Trail 20260729-1831-web-frontend ──────────── ✓ done ───────────────┐
│ ← Work · Global · wave 2 · dispatch d-20260729-1831                  │
│ role web-frontend · seat vendor (provenance) · exit 0 · 04:12        │
│ branch feat/checkout-ui · a1b2c3d4e5f6 → 9f8e7d6c5b4a · PR #47 open  │
│                                                                      │
│ timeline  start ──██ retry ──███████ exit ─ (from events, if present)│
│                                                                      │
│ PLAN LINE  2 | web-frontend | Build checkout UI … | feat/checkout-ui │
│ ▸ Built  ▸ Decisions  ▸ Do not repeat  ▸ Evidence  ▸ raw JSONL       │
└──────────────────────────────────────────────────────────────────────┘
```

New: a thin per-task timeline strip rendered from the events file when one exists for this `task_id` (retries and failovers become visible on the record, not just in dispatch stdout that scrolled away). When no events file exists (pre-v2 trails): the strip is simply absent — no fake reconstruction.

### 4.6 Roles / Skills / Learn / Conductor / Company / About

These pages keep their Phase 1 information architecture (it is good and it is law-adjacent); they receive only the Phase A restyle: token sheet, stat-strip pattern, hairline tables, disclosure motion. Two additions:

- **Conductor page** gains a "last chain" strip (the serial silhouette from §4.3, frozen) above the trail index.
- **About** gains an **Honesty** section: the event schema, the staleness thresholds, what "activity proxy" means, and what replay can and cannot show.

---

## 5. Live observability design

### 5.1 Sources — verified against the repo, gaps marked

| Source | Exists today? | Live use |
|--------|---------------|----------|
| `dispatch.sh` stdout + per-task logs `~/dev/agent-logs/<repo>-<branch>-<ts>.log` | ✅ (verified: `ls ~/dev/agent-logs` shows per-task logs) | Log **byte size + mtime** as activity proxy. Filenames only; transcript content never reaches the browser (redaction law) |
| `dispatch.sh` internals: wave loop, per-wave PIDs, `wait`, exit codes `0/77/75/69`, retry/failover, `notify.sh` hooks | ✅ (verified in `scripts/dispatch.sh` — wave grouping ~L437–494, wait loop ~L756–857) | **The event emitter lives here** — dispatch already knows every transition; today it only `echo`s them |
| `logs/provider-state/<vendor>.cooldown` | ✅ (verified: `logs/provider-state/` exists; written at `dispatch.sh:272`) | Rate-cap chrome: cooldown-until per vendor |
| `wave-plans/**/handoffs/*.jsonl` | ✅ | Terminal truth per task — the Floor reconciles against it when it lands |
| `wave-plans/**/*.plan`, `wave-plans/conductor/` | ✅ | Queued (not yet started) tasks; serial-vs-wave classification before the first event |
| `config/workers.yaml`, `config/routing.yaml`, `config/ratecap-patterns.conf` | ✅ | Seat labels, failover order for the fork rendering |
| `scripts/fleet-status.sh` (Paperclip health, heartbeats, `--watch`) | ✅ | Optional "control plane" chip on the Floor header; **never required** (SYNTHESIS: no Paperclip dependency for core pages) |
| **Events stream** | ❌ does not exist | The one new artifact this proposal adds — §6 |
| Process heartbeats | ❌ | Derived: a `dispatch_heartbeat` event every 30 s from the dispatch loop; no new daemon |

### 5.2 Architecture — one new file, one on-demand server, zero daemons

```
dispatch.sh ──emit──▶ logs/fleet-events/<dispatch_id>.jsonl   (append-only)
                          │                    ▲
                          │              latest symlink/pointer
                          ▼
scripts/desk-live.sh  (runs only while the operator wants the tab)
  = stdlib static server for site/experience/**
  + GET /live/events?since=<n>  → tail of the events file (JSON)
  + GET /live/activity          → {task_id: {log_bytes, log_mtime}} via stat()
                          │
                          ▼
        /live/ page: small vanilla-JS poller, 2 s interval
        (Almanac pages stay zero-JS-required, unchanged)
```

- **Local-first**: `file://` still works for the whole Almanac. The Floor needs the tiny server (browsers can't tail files); it is started and killed by the operator, not a daemon.
- **No second orchestration stack**: dispatch stays the only thing that runs agents; the Floor only *watches* files dispatch writes.
- Polling (2 s) over SSE for Phase B: dumbest thing that works, trivially debuggable with `curl`. SSE is a Phase C upgrade *if* polling feels laggy — same event schema either way.

### 5.3 Update cadence

| Signal | Cadence | Freshness rule |
|--------|---------|----------------|
| Events poll | 2 s | New events animate in |
| `dispatch_heartbeat` | emitted every 30 s by the wave wait-loop | > 75 s without one → banner `⚠ STALE — dispatch may have died; check terminal` and all `running` glyphs become `? stale` |
| Activity proxy (log stat) | 5 s | Byte delta drawn; flatline > 120 s on a running lane → lane gets a quiet `no output 2m` note (fact, not judgment) |
| Handoff reconcile | on `task_exit` event | Floor links the lane to `/trail/<task_id>/` once the JSONL exists |

### 5.4 Serial vs wave (P5)

Classification is mechanical, not guessed:

- `dispatch_start` event carries `plan_path` and `mode`: plans under `wave-plans/conductor/` **or** single-task single-wave ⇒ `serial`; otherwise `wave`.
- Serial ⇒ chain silhouette (§4.3 bottom). Wave ⇒ lane fan-out (§4.3 top). Multi-wave plans show `wave 2 of 3` with queued waves as ghost sections below the active one.

### 5.5 Failover and rate-cap as chrome (P7)

- Exit 75 ⇒ `task_ratecap` event with vendor + cooldown-until (read from the cooldown file dispatch already writes). Lane turns amber, keeps its history, forks the retry lane.
- Exit 69 ⇒ `task_unavailable`, same fork treatment.
- Cooldowns strip on the Floor header: `seat-2 ⏳ 19:04` — sourced from `logs/provider-state/`, so it is also correct when you open the Floor *between* dispatches.

### 5.6 Honesty rules (P7 — normative for any implementation)

1. **A lane exists only if an event created it.** No lanes from plan-parsing alone are ever shown as running — planned-but-unstarted tasks render as `◌ queued`, explicitly.
2. **`running` requires a fresh heartbeat.** No heartbeat ⇒ `? stale`, loudly.
3. **The activity bar is labeled a proxy** in-place, not just in About.
4. **Replay is replay**: `/live/replay/` carries a permanent `REPLAY` watermark and the original timestamps; it can never be mistaken for live.
5. **Degraded is designed**: server down ⇒ the `/live/` page (it is still a static file) renders an offline card with the exact restart command. Events file missing ⇒ quiet-floor empty state (§3.6). Never a blank page, never a spinner-forever.
6. **Terminal truth wins**: if an event says `done` but the handoff JSONL says `failed`, the Almanac (handoff) is authoritative and the trail page says so; the events file is a *courtesy log*, the handoff is the record.

---

## 6. Data / API gaps and proposed additions

Schema v2 (`index.json`) is a **batch snapshot** — correct for the Almanac, structurally wrong for live (rebuilding the world every 2 s to learn one transition). Gap analysis:

| Need | v2 today | Gap |
|------|----------|-----|
| Task started / exited now | Only after handoff lands + rebuild | **New: events stream** |
| Retry / failover / ratecap moments | Lost in dispatch stdout | **New: event types** |
| Dispatch aliveness | Nothing | **New: heartbeat event** |
| Queued waves | Plans parsed only at build time | Events `dispatch_start` carries plan summary |
| Per-task timeline on trail page | Nothing | Almanac build (Phase C) reads events files if present |

### 6.1 New artifact: `logs/fleet-events/<dispatch_id>.jsonl` (event schema v1)

Append-only, one JSON object per line, written by a small `emit_event()` in `dispatch.sh` (a `printf >>` — no new dependency). Gated by `FLEET_EVENTS=1` (default on) so it is trivially disableable.

```json
{"v":1,"ts":"2026-07-29T18:34:58Z","dispatch_id":"d-20260729-1831","event":"task_ratecap",
 "wave":2,"task_id":"20260729-1831-docs-writer","role":"docs-writer","branch":"feat/checkout-docs",
 "vendor":"seat-2","cooldown_until":"2026-07-29T19:04:00Z","log":"dev-agents-feat-checkout-docs-….log"}
```

Event types (closed set for v1):
`dispatch_start` (plan_path, mode, waves[], tasks[] with role/branch/wave) · `wave_start` · `task_start` · `task_ratecap` · `task_unavailable` · `task_retry` · `task_exit` (exit, duration_s) · `wave_end` · `dispatch_heartbeat` · `dispatch_end` (summary counts).

Rules: filenames only for logs; branch/role/task_id are the join keys to trails; **no free text from agents ever enters an event** (nothing to redact by construction, but events still pass the existing redactor before any server response, belt and braces). `logs/fleet-events/latest` pointer file names the newest dispatch so the Floor auto-follows.

### 6.2 Explicit non-additions

- **No `fleet-status.json` snapshot file**: the client reduces events; a second derived file is a second thing to be stale.
- **No schema v2 bump**: `index.json` is untouched in Phases A–B. Phase C adds *additive* per-trail `timeline[]` (from events files) — additive keeps `schema_version: 2` per the documented change rules in [`experience-data.md`](../experience-data.md).
- **No Paperclip requirement**, no cloud, no websocket infra.

### 6.3 Migration honesty

Trails older than v2 have no events ⇒ no timeline strip, no replay — shown as absent, never reconstructed. Events files are operator-local telemetry: **gitignored** by default (like `site/experience/`), and their retention is an owner call (§10).

---

## 7. CLI ↔ Desk bridge (exact operator steps)

**One-time per working session:**

```bash
make desk-live        # builds Almanac if stale, starts scripts/desk-live.sh,
                      # opens http://127.0.0.1:8765/live/  — Ctrl-C to stop
```

**Then the daily loop — chat remains the only control plane:**

1. Chat: `Activate Wave` → plan → `go` (or Conductor → `go`). Orchestrator runs `dispatch.sh` exactly as today.
2. `dispatch.sh` appends events; the already-open Floor tab notices `latest` changed within 2 s and **auto-switches to the new dispatch** — the operator touches nothing.
3. Glance at the Floor whenever chat says "still running": lanes, WAITING ON line, cooldowns.
4. `dispatch_end` ⇒ Floor shows the frozen summary card with per-task links + a one-line nudge: `record it: make experience`.
5. `make experience` (or `experience-open`) → Almanac now has the trails; Floor links resolve into trail pages.

Fallbacks: no browser/server running ⇒ nothing changes vs today (dispatch never depends on the Floor); terminal-only check stays `scripts/fleet-status.sh --watch` and `tail -f ~/dev/agent-logs/<log>`. Optional: `notify.sh` gains a link to `http://127.0.0.1:8765/live/` in its message — zero-effort deep link on failure notifications.

---

## 8. Phased ship plan

| Phase | Scope | Touches | Effort (rough) |
|-------|-------|---------|----------------|
| **A — Restyle** | Token sheet, type/density/motion pass on all existing Almanac pages; stat strip + latest-wave Home; wave summary chips on Work; keyboard nav; a11y re-audit. **Static only, zero data changes, `file://` preserved.** | `templates/experience/site.css`, `experience_build.py` templates only | ~2–4 seat-days |
| **B — Live tail** | `emit_event()` in `dispatch.sh` (+ heartbeat in the wait loop); `scripts/desk-live.sh`; `/live/` page (lanes, chain, event tail, WAITING ON, cooldown strip, stale/offline chrome); `make desk-live`; tests: event emission fixture, staleness, no-transcript-content guarantee | `dispatch.sh` (additive), new script, new page | ~4–6 seat-days |
| **C — Replay + record merge** | `/live/replay/<dispatch_id>/` reusing the Floor renderer at 10–60×; **Replay ▶** on Work wave headers; additive `timeline[]` on trails in `index.json`; trail-page timeline strip; SSE upgrade only if polling proves laggy | `experience_data.py` (additive), Floor JS | ~3–5 seat-days |

Each phase ships and is useful alone; Phase 0/1 static desk remains shippable throughout (brief constraint honored). Kill criteria: if Phase A doesn't make the owner *want* to open the desk, stop and rethink before B.

---

## 9. Risks & non-goals

### Risks

| Risk | Mitigation |
|------|------------|
| `dispatch.sh` is load-bearing bash; event emission bugs could break dispatch | `emit_event()` is `|| true`-guarded and `FLEET_EVENTS=0` kills it entirely; dispatch exit codes and flow untouched |
| Events file and handoffs disagree | Precedence law §5.6.6: handoff wins, Almanac says so |
| Motion becomes noise | Motion budget (§3.5): three jobs only; reduced-motion parity is a test, not a hope |
| Activity proxy read as progress bar | In-place `proxy` label + tooltip + About; never a percent |
| Scope creep toward a control panel (dispatch buttons in the browser) | **Non-goal, hard**: the Floor is read-only glass; chat/CLI stays the only control plane |
| Localhost server left running | It serves static files + two read-only endpoints on 127.0.0.1; still: Ctrl-C lifecycle, prints its own stop instructions, no auto-start anywhere |

### Non-goals

- No dispatch/promote/retry **buttons** in any browser surface (freeze law upheld).
- No agent transcript content in the browser — ever; filenames and byte counts only.
- No always-on daemon, no cloud, no SaaS, no React requirement (vanilla JS on `/live/` only; Almanac stays JS-optional).
- No second source of truth: handoffs remain the record; events are telemetry.
- No PMI / join / wave-law changes.

---

## 10. Open questions for owner

1. **Events retention:** gitignore `logs/fleet-events/` and prune (e.g. keep last 50 dispatches), or commit them as part of the record? (My default: gitignore + prune; the handoff is the record.)
2. **Auto-open:** should `dispatch.sh` print the Floor URL (and optionally `open` it) when it detects the desk-live server is up, or is the always-open tab enough?
3. **Floor while idle:** between dispatches, should `/live/` show the last dispatch frozen (my default) or the quiet-floor empty state?
4. **Sound:** one optional, off-by-default completion chime on `dispatch_end` — worth having at all, or is any audio out of character for this product?
5. **Remote workers:** when dispatch runs tasks on a remote worker via `run-remote.sh`, is per-task log-size proxy worth fetching (adds ssh stat calls), or do remote lanes simply run without an activity bar (my default: no bar, honest `remote — no activity proxy` note)?
6. **Phase A palette check:** dark-first Floor is fixed; should the Almanac *default* stay `prefers-color-scheme` (my default) or go dark-first too for one consistent mood?
