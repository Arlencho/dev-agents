# Brief: Session modes — Conductor / Wave / Auto (on top of dev-agents)

**To:** Independent proposal authors (Claude, Grok, Kimi)  
**From:** Fleet owner (Arlen) via chat orchestrator  
**Date:** 2026-07-23  
**Repo:** `dev-agents` (AI orchestration toolkit)  
**Output:** Each author writes **one** proposal file (path assigned in your task). Do **not** edit other authors’ files. Do **not** implement product code beyond the proposal markdown.

---

## 1. Goal

Design how **session modes** sit on top of the existing multi-vendor fleet so that:

1. At session start (or mid-session), the human can activate one of:
   - **Conductor mode** — task-by-task: pin a defect → classify → brief → assign to the right **role seat** → verify. Chat agent does **not** implement product fixes.
   - **Wave mode** — brainstorm / plan sprints and multi-surface work; produce plan files; multi-agent dispatch only after explicit human go (“trigger”).
   - **Auto mode** — human mandates the chat agent to **choose** Conductor vs Wave (vs stay-in-chat) using a transparent decision table, announce the choice, then follow that contract.

2. The human should **not** have to name vendors (“use Kimi”) every time. Routing uses **role → seat map** (`workers.yaml` / `routing.yaml`).

3. Modes are **behavior contracts** injectable for **any** co-pilot vendor (Claude / Kimi / Grok chat), not a new daemon-first product.

4. Build **on top of** what exists: launchers, `dispatch.sh`, plan format, L1 charters, L2 skill inject, L3 preamble, learnings (no auto skill promote), handoffs, rate-cap failover.

**Motivating incident (must be handled well by Conductor):**

> Live legal copy rendered **“Pelops AI ABarranges”** because Next.js RSC dropped inter-node JSX whitespace after `</strong>`. Fix was front-end only (`{" "}`). Chat agent self-fixed instead of routing to `web-frontend` seat. No learning/skill was written. Owner wants: pin → conductor routes → expert owns fix + optional learning stub.

---

## 2. Current system (facts — do not invent)

### 2.1 Fleet (unchanged constraints)

- Subscription CLIs: `claude`, `kimi`, `grok` — zero API keys for fleet path.
- Launchers: `providers/<vendor>/launch.sh` + `providers/lib.sh`.
- Exit contract: `0` ok / `1` fail / `75` rate-capped / `69` unavailable (guardrails as documented).
- Seats: `config/workers.yaml` → `provider_preferences` (e.g. `web-frontend: kimi`, `plan-critic: grok`, `docs-writer: claude`).
- Failover: `config/routing.yaml` → `provider_failover` (e.g. `web-frontend: [kimi, claude]`).
- Multi-agent: `scripts/dispatch.sh` + `scripts/run-remote.sh` + plan files (`WAVE | AGENT | TASK | BRANCH` — see `docs/plan-file-format.md`).
- Skills: L1 charter → L2 packs via `scripts/skill-inject.sh` + `config/role-skills.yaml` → L3 case via `scripts/preamble.sh`. **Promotion of skills is PR-gated; not auto.** Freeze: `docs/proposals/skills-evolution-SYNTHESIS.md`.
- Today’s operator story (README): **Mode 1 co-pilot chat** vs **Mode 2 fleet dispatch**. Session modes must **extend** this, not replace git/fleet discipline.

### 2.2 What does NOT exist yet

- No first-class **Conductor / Wave / Auto** session contracts in repo.
- No durable **session-mode** inject into co-pilot or dispatch (beyond ad-hoc chat habit).
- No **single-seat dispatch** UX productized as “conductor one-shot” (dispatch can run 1-line plans, but no brief template + conductor policy).
- No automatic learning write from chat fixes (ABarranges stayed in chat memory only).

### 2.3 Related roles

- `roles/orchestrator.md` — already “tech lead / routes / plans / dispatches”; closest existing charter to Conductor+Wave.
- Producers/critics as today; seat map decides vendor.

---

## 3. Vocabulary (align proposals)

| Term | Meaning |
|------|---------|
| **Session mode** | Contract for how the *current chat agent* behaves for this session (or until switched) |
| **Conductor** | Chat agent classifies, writes brief, assigns by role seat, verifies; **does not** implement in-scope product code |
| **Wave** | Chat agent plans multi-role / multi-PR work; may draft plan files; fleet execute only after human trigger |
| **Auto** | Chat agent picks Conductor vs Wave vs stay-in-chat per decision table; announces choice; obeys chosen contract |
| **Role seat** | Mapping role → primary vendor CLI (config), not human-named vendor |
| **Task packet / brief** | One-screen assignment for a single expert (shared DNA with plan task lines) |
| **Stay-in-chat** | Discussion, legal posture, prioritization — no fleet, no product code unless human overrides |
| **Escape hatch** | Human override for one turn (“fix here”, “don’t dispatch”, “switch to Wave”) |
| **Single-seat dispatch** | One role, one task line (or thin plan), not a multi-wave pack |

---

## 4. Requirements (MUST)

### R1 — Three modes only (MVP)

Support exactly:

1. **Conductor**
2. **Wave** (with sub-states: *planning* vs *armed for dispatch* — not four top-level modes)
3. **Auto**

No additional top-level modes in MVP.

### R2 — Activation

- Human can activate at session start with clear phrases and/or a slash-like convention, e.g.  
  `Activate Conductor` / `Activate Wave` / `Activate Auto`  
  and/or `/mode conductor|wave|auto`.
- Mid-session switch must be allowed without restarting the chat product.
- Mode must be **visible** (agent acknowledges mode on activation and when relevant).

### R3 — Conductor contract (hard rules)

When Conductor is active and human **pins a concrete product defect** or asks to fix in-scope product code:

1. **Diagnose lightly** (enough to classify role + write brief) — not full implementation.
2. **Classify** surface → **role** (e.g. legal JSX / Next page → `web-frontend`).
3. **Write task packet** with at least: what user saw, likely root class, scope, done-when, out-of-scope, learning expectation (yes/no stub).
4. **Assign** via role seat map (config). Do **not** require human to name Kimi/Claude/Grok.
5. **Do not implement** product code in the conductor chat (no drive-by fix of the expert’s job).
6. **Verify** after expert returns (e.g. live check, pattern scan) — verification OK; re-authoring the fix is not.
7. **Escape hatches:** “fix here” / “quick” / pure docs-or-chat → may self-do; “don’t dispatch” → brief/issue only.

### R4 — Wave contract

- Default behavior: clarify, advise, produce **wave plan** artifacts compatible with `docs/plan-file-format.md`.
- **No silent multi-agent shipping.** Dispatch only after explicit human trigger (existing operator habit: plan → “trigger” → `dispatch.sh`).
- Suitable for sprints, Soft-live multi-surface, architecture, multi-PR.

### R5 — Auto contract

- Auto must use a **documented decision table** (not vibes). Owner strawman (proposers may refine):

| Signal | Auto picks |
|--------|------------|
| One surface, clear bug, one role | **Conductor** |
| Multi-role, multi-PR, milestone, sprint planning | **Wave** |
| Pure discussion / policy / prioritization | **Stay-in-chat** |
| Ambiguous | **Ask once**, then lock |

- On every gear choice or switch, Auto **announces** one line:  
  `Auto → Conductor: single legal JSX defect → web-frontend seat.`
- Auto must not thrash mid-task; lock for the current pin/task unless human switches or a new distinct pin arrives.

### R6 — Default when mode unset

**Owner strawman (challenge if wrong):** global default = **Auto**.  
Proposers must specify: where default lives, how product-specific override works (e.g. Soft-live week → Conductor), and how “forgot to activate” is handled.

### R7 — Co-pilot + fleet both in scope

Modes apply to:

- **Co-pilot chat** (Claude Code / Kimi / Grok Build interactive sessions) — primary UX for Conductor.
- **Fleet path** — Wave still produces plans for `dispatch.sh`; Conductor may emit single-line plans or a thin “one-shot” path without inventing a second orchestration product.

Do not require Paperclip as MVP dependency (Paperclip may be mentioned as future consumer only).

### R8 — Shared brief DNA

Conductor task packets and wave plan task descriptions share field DNA (goal, done-when, out-of-scope, evidence, learning?). Prefer one template doc under `docs/` or `templates/`.

### R9 — Learnings / skills policy (do not break freeze)

- Novel platform quirks (RSC whitespace class): Conductor brief may **require** expert to add a **learning stub** (project or global `learnings/`) when pattern is reusable.
- **Skill pack updates still only via promotion PR** (skills-evolution freeze). Modes must not auto-write `skills/*/SKILL.md`.
- Session chat memory alone is insufficient for fleet-wide lessons.

### R10 — Trust & hygiene

- Mode is **behavior**, seats remain config; no vendor branding on commits/PRs (`git-ship` / guardrails).
- Untrusted prior: expert claims and handoffs remain verify-against-git.
- No invented CLI flags or auth paths.
- Prefer **bash + git + inject files + existing dispatch** over new daemons.

### R11 — Non-goals (MVP)

- Full autonomous CEO agent that spends money without human go for waves.
- Auto-merge of skills from conductor outcomes.
- Replacing `dispatch.sh` or killing multi-vendor.
- Deep revival of handoff-brain Phases 2–5.
- Per-vendor proprietary mode systems that diverge forever (one contract, multi inject).

---

## 5. Owner strawman defaults (use or improve — mark changes)

| Topic | Strawman |
|-------|----------|
| Default mode | **Auto** |
| Conductor dispatch | Prefer **propose assignment + wait for “go”** for first ship; optional later “auto single-seat when confidence high” |
| Wave execute | Always wait for explicit **trigger** |
| Mode persistence | Session-scoped file or preamble inject (e.g. under wave-plans or `logs/session-mode`); not only chat lore |
| Activation syntax | Both natural language + `/mode …` |
| Learning on Conductor | Expert PR includes learning stub if novel; skill only via promote |
| Who can be conductor | Any co-pilot vendor running with mode inject + orchestrator skill/charter slice |

---

## 6. What your proposal MUST cover

Write a **design proposal** (markdown), not implementation.

### Required sections

1. **Executive summary** (≤15 lines)
2. **Mode contracts** — Conductor / Wave / Auto hard rules; Wave sub-states
3. **Activation & persistence** — phrases, slash command, mid-session switch, where state lives, multi-vendor inject path
4. **Decision table (Auto)** — full table + thrash prevention
5. **Conductor runtime path** — from pin → brief → assign → expert → verify (files/scripts touched; single-seat vs issue-only)
6. **Wave runtime path** — plan authoring → human trigger → `dispatch.sh` (reuse plan format)
7. **Role routing** — how surface maps to role; how seat map is read; human never names vendor
8. **Brief / task packet template** — concrete fields; example filled for ABarranges
9. **Integration with L1/L2/L3** — charter vs new skill pack(s) vs case inject; what is mode vs skill
10. **Learnings policy** — conductor outcomes → learnings; never silent skill promote
11. **Phased rollout** — MVP in ~1–2 weeks vs later; what ships first (docs/skill only vs scripts)
12. **Success metrics** — e.g. % pin-points self-fixed by conductor (should fall); brief quality; time-to-expert-PR
13. **Failure modes** — kimi unavailable, wrong role, conductor still codes, Auto thrash, mode not injected
14. **Explicit non-goals**
15. **Open questions for the owner**

### Quality bar

- Ground in **current system facts** (§2); mark speculation.
- Prefer mechanisms that fit **bash + git + existing scripts**.
- Name concrete paths under `dev-agents/` where possible.
- Divergence from other vendors is valuable; do not converge for politeness.
- Example-driven: ABarranges must appear as a worked Conductor example.

### Output file

Your task assigns the exact path, e.g. `docs/proposals/session-modes-proposal-<vendor>.md`.

### Forbidden

- Implementing launchers, dispatch changes, or skills (proposal markdown only)
- Editing other vendors’ proposal files
- Inventing CLI flags / auth paths not in repo
- Claiming session modes already ship
- Killing multi-vendor orchestration
- Auto-promoting skills from experience

---

## 7. Prompt for your opinionated angle

You are one of three independent designers. Optimize for **correctness and implementability on this fleet**. After all three exist, the owner will compare and synthesize (same pattern as skills-evolution).

Suggested lean angles (optional, not mandatory):

- **Claude seat:** policy clarity, trust, human gates, anti-thrash.
- **Grok seat:** implementability on bash/git/dispatch; inject path; single-seat UX.
- **Kimi seat:** operator UX, activation friction, co-pilot day-to-day feel.

---

## 8. Acceptance for proposal task

- [ ] File exists at assigned path
- [ ] All required sections present
- [ ] ABarranges worked example under Conductor
- [ ] No other proposal files touched
- [ ] Commit + push branch; draft PR if `gh` works else note in handoff
- [ ] `handoff.md` at repo root before exit (Built / Decisions / Do not repeat / Evidence)

---

*End of brief.*
