# Fleet Desk v2 — Owner SYNTHESIS (implement freeze)

**Status:** OWNER-APPROVED freeze (chat 2026-07-29 after hybrid sketch)  
**Brief:** [`fleet-desk-v2-BRIEF.md`](fleet-desk-v2-BRIEF.md)  
**Proposals:** A [#53](https://github.com/Arlencho/dev-agents/pull/53) · B [#54](https://github.com/Arlencho/dev-agents/pull/54) · C [#55](https://github.com/Arlencho/dev-agents/pull/55)  
**Sketch:** `site/sketches/fleet-desk-v2-hybrid.html` (reference only; not law)  
**Data law (atoms unchanged):** [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md) schema v2

---

## 1. Product freeze

| Field | Decision |
|-------|----------|
| **Name** | **Fleet Desk** (keep) |
| **Attention modes** | **Almanac** (settled) · **Ops Floor** (live) |
| **Tagline** | See the fleet move. Keep the record honest. |
| **Not** | Second orchestrator, skill auto-promote, inventing live state |

### Hierarchy (normative)

```text
Global
 └── Company (1..N)          companies/*.md
      └── Repo (1..N)        github_repo / repo fields
           └── Mission       GitHub issue/PR (or plan-only campaign)
                └── Wave(s)  parallel batch OR Conductor serial chain
                     └── Task / Seat → Trail when settled
```

- **Simple:** Mission → 1 task → 1 seat → 1 trail  
- **Complex:** Mission → 2–5 waves → many seats/trails  
- **Unlinked** trails stay honest at Global when no company join  
- **Ops Floor** cross-cuts: shows current dispatch with hierarchy chrome

### Pipeline language (everywhere)

**Queued · In flight · Blocked · Settled** (map of TODO / WIP / blocked / DONE)

### Live visualization

| Mode | Layout |
|------|--------|
| **Wave** | Parallel seat lanes; ghost lanes for plan seats not yet started |
| **Conductor** | Serial spine; dashed future nodes; one hot pin |
| **Waiting-on** | First-class strip (not buried) |
| **Rate-cap / failover** | Honest chrome on the lane |

---

## 2. Hybrid taken from seats

| From | Keep |
|------|------|
| A | Floor as instrument; per-dispatch event files; cyan pulse craft |
| B | Waiting-on strip; three-tier liveness (SSE / poll / static); Flight Line metaphor as optional subtitle |
| C | Almanac \| Floor mode language; STALE chrome; matte Almanac vs live Floor |
| Sketch | Hierarchy strip; Missions portfolio; Issue run; simple 1:1 |

**Live surface name in UI:** **Ops Floor** (nav: Floor). Optional subtitle “Flight Line” in docs only.

---

## 3. Phase ship plan (implement in order)

### Phase A — Almanac restyle + hierarchy + mission shells (THIS WAVE)

**Goal:** Make the desk look and navigate like the approved sketch **using schema v2 + derived mission views**. No requirement for live dispatch yet.

Deliver:

1. **Visual system** — modern dark-first Almanac craft (tokens, density, pills, cards); keep a11y (text+color, reduced motion)  
2. **Hierarchy chrome** on all pages: Global › Company › Repo › Mission › Wave/Task when known  
3. **Global home** — pipeline strip (best-effort from trail statuses), companies, live teaser (empty → teach `make desk-live` or “no live run”)  
4. **Company page** — repos (1..N from manifest fields), missions derived for that company  
5. **Missions index** — portfolio cards with path `company / repo / #issue` when issue links exist; group trails by primary issue when possible  
6. **Mission / issue run page** — waves under that issue, seats/trails as tasks, pipeline counts, “around this mission” context from handoff/issue links  
7. **Work** — keep group-by-wave; show pipeline-ish status; link up to mission when issue known  
8. **`/live/` shell** — static page empty states for Wave + Conductor layouts (demo structure or empty teach); not fake running agents  
9. **Simple 1:1** — mission page collapses cleanly when only one trail  
10. Tests: HTML smokes for hierarchy, missions route, live shell, no secrets; `make test` green  
11. `docs/experience.md` walkthrough for v2 navigation  

**Data:** Prefer derive from `index.json` (issue_links, company_id, wave, status). Thin `experience_data.py` extensions allowed if needed (e.g. `missions[]` projection) — document in `experience-data.md`; bump schema only if required with migration honesty.

**Out of Phase A:** real `dispatch.sh` event stream, SSE server, process heartbeats.

### Phase B — Live Ops Floor

1. `dispatch.sh` append-only events → `logs/fleet-events/<dispatch_id>.jsonl` (+ `latest` pointer)  
2. `make desk-live` local watcher (stdlib): SSE and/or `live.json` for poll/`file://`  
3. Wire `/live/` to real events: lanes, spine, waiting-on, STALE/offline chrome  
4. Hierarchy context on Floor from plan/mission when known  
5. Never put live state into `index.json`  
6. Opt-out: `FLEET_EVENTS=0`  

### Phase C — Replay

1. Replay scrubber on settled runs  
2. Trail ↔ mission ↔ floor links  
3. Honesty watermark REPLAY  

---

## 4. Non-goals

- React/SPA required (static + tiny JS for Floor OK)  
- Paperclip required for core pages  
- Vendor branding on shared GitHub surfaces  
- Agent transcript bodies in browser  

---

## 5. Success criteria (Phase A done)

1. Operator understands hierarchy in &lt; 30s on Global  
2. Can open a mission and see waves/tasks when issue-linked trails exist  
3. Floor shell exists and teaches live path  
4. Visual craft matches sketch direction (not Phase 0 plain tables only)  
5. `make experience` / `desk` / tests green; schema v2 join/PMI law intact unless thin mission projection documented  

---

## 6. Implementation order

1. SYNTHESIS on main (this file)  
2. Phase A PR (web-frontend primary)  
3. Critic → merge  
4. Phase B (devops event emit + web-frontend Floor wire)  
5. Phase C  

**Next step after merge of this doc:** dispatch Phase A.
