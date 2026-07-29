# Brief: Fleet Desk v2 — modern AI-native visual system + live fleet observability

**To:** Independent proposal authors (three seats — do **not** converge with each other)  
**From:** Fleet owner (Arlen) via chat orchestrator  
**Date:** 2026-07-29  
**Repo:** `dev-agents`  
**Output:** Each author writes **one** proposal markdown (path in task). Do **not** edit other seats’ files. Do **not** implement product UI or rewrite `experience_data.py` in this wave (design + wireframes + data gaps only).  
**Shared-doc rule:** Prefer **Proposal A / B / C** in body. No AI vendor marketing names in commit/PR titles/bodies if you open a PR (seat labels only). Filenames may use historical `*-proposal-*.md` seat stems.

---

## 1. Goal

Redesign **Fleet Desk** so it feels:

1. **Super intuitive** — progressive disclosure: see the flow at a glance, dig deeper only when needed  
2. **Super modern + AI-native** — fanciness and cool effects welcome (motion, depth, ambient status, live graphs) as long as **honesty and scan-first** survive  
3. **Simple hierarchy** — Global ↔ company, Work by wave, trail detail, roles/PMI, skills/learnings remain first-class  

And add a **missing product surface** the owner cares about as much as aesthetics:

4. **Live fleet / Conductor observability** — when the operator is in CLI/chat and triggers Conductor (or a wave), the desk (or a companion live view) should show **how work is moving**: which roles/agents are active, single-task chain vs multi-agent wave parallelism — not just the chat CLI status line (“1 command still running”).

**What already exists (must not ignore):**

- Phase 0/1 shipped: static `make experience` / `make desk`, schema v2 JSON, dual-scope, PMI P3, critic pairing, gh enrichment, `companies/dev-agents.md`  
- Law freeze: [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md) for **data atoms** (trail = atom, wave = group, join rules, PMI gates). v2 proposals may **evolve UX chrome** and **add live surfaces**; they should not casually destroy the data contract without a migration story.

**What is broken / inadequate today (owner):**

- Visual system feels weak / not modern enough  
- Operator cannot **see fleet motion** while orchestrating: chat shows opaque “command still running”; no dashboard of concurrent seats, wave fan-out, failover, critic loops, or conductor steps  

---

## 2. Owner intent (paraphrased — treat as product law for this brief)

> I want something super intuitive and super modern that is simple to see flow and dig deeper if needed. All fanciness or cool effects are welcome. Modern, AI-native, super intuitive.  
> I also want a dashboard visualization of how things are moving — when I work in the CLI and trigger Conductor, agents/sub-agents/roles are solving tasks either **task-by-task** or as a **wave** with multiple active at once. That is critical. Right now I only see “1 command still running” from the CLI while talking to the orchestrator chat.

### Design problems every proposal must solve

| # | Problem |
|---|---------|
| P1 | **Glanceable flow** — what is the fleet doing / did / knows, without a wall of tables |
| P2 | **Progressive depth** — home → wave → trail → handoff evidence in ≤3 clicks; back always obvious |
| P3 | **Modern AI-native craft** — type, color, motion, density, empty states that teach; dark-first OK |
| P4 | **Live motion** — visualize concurrent roles during Conductor / wave dispatch (and history replay) |
| P5 | **Serial vs parallel modes** — make Conductor single-chain vs multi-seat wave visually distinct |
| P6 | **Bridge CLI ↔ Desk** — how the operator opens/refreshes live view while chat is the control plane |
| P7 | **Honesty** — live UI must not invent state; degraded/stale/offline must be first-class chrome |
| P8 | **Compatibility** — Phase 1 JSON still powers historical desk; live layer may need new streams/files |

---

## 3. Constraints

- **Static Phase 0 desk stays shippable** until v2 is approved; proposals may keep dual-mode (static almanac + live ops).  
- **No second orchestration stack** — still `dispatch.sh` / Conductor law / session-modes.  
- **No skill auto-promote** from the UI.  
- **Secrets / agent transcripts** never dump into the browser (filename-only, redaction law from schema v2).  
- **Prefer local-first** (file://, local server, optional lightweight watcher). Cloud SaaS optional later only.  
- **Accessibility** remains non-optional (motion reducible, status not color-only).  
- **Shared GitHub hygiene:** no vendor brand names in PR titles/bodies.

---

## 4. Required proposal sections

Each seat’s proposal must include:

1. **Name** for the v2 experience (keep Fleet Desk or rename).  
2. **North-star UX** (1 page): who it is for, 30-second story.  
3. **Visual system** — palette, type, density, motion language, reference peers (Linear / Vercel / Raycast / etc.) without cloning.  
4. **IA + wireframes** — Home, Live Ops (or equivalent), Work, Trail, Roles, Skills/Learn, Conductor, Company, About. ASCII or structured wireframes OK.  
5. **Live observability design** — data sources (dispatch logs, agent-logs metadata, provider-state, wave-plans handoffs, process heartbeats?), update cadence, serial vs wave visualization, failover/rate-cap as chrome, “what am I waiting on?”.  
6. **CLI ↔ Desk bridge** — exact operator steps after `dispatch.sh` / Conductor go.  
7. **Data / API gaps** — what schema v2 lacks; proposed additions (events stream? `fleet-status.json`? SSE?). Migration honesty.  
8. **Phased ship plan** — Phase A visual restyle on static only; Phase B live tail; Phase C history replay — with effort rough order.  
9. **Risks & non-goals**.  
10. **Open questions for owner**.

---

## 5. Evaluation criteria (for later SYNTHESIS)

- Intuitive progressive disclosure  
- Live fleet motion clarity (the owner’s #1 gap)  
- Modern craft without vacuous decoration  
- Feasibility on existing fleet artifacts  
- A11y + honesty under failure  

---

## 6. Out of scope for this wave

- Implementing HTML/CSS/React  
- Changing production PMI gates or join law  
- Merging the three proposals (owner SYNTHESIS comes after)  

---

## 7. Paths

| Seat | Proposal path (write only yours) |
|------|----------------------------------|
| A | `docs/proposals/fleet-desk-v2-proposal-A.md` |
| B | `docs/proposals/fleet-desk-v2-proposal-B.md` |
| C | `docs/proposals/fleet-desk-v2-proposal-C.md` |

Read before writing:

- This brief  
- [`experience-console-SYNTHESIS.md`](experience-console-SYNTHESIS.md) (data law)  
- [`docs/experience.md`](../experience.md), [`docs/experience-data.md`](../experience-data.md)  
- [`docs/session-modes.md`](../session-modes.md) (Conductor / Wave / Auto)  

---

**Next after three PRs land:** owner SYNTHESIS → implementation waves (visual + live).
