# Brief: Experience Console — operator UI for fleet work, skills & learnings

**To:** Independent proposal authors (three seats — do not converge with each other)  
**From:** Fleet owner (Arlen) via chat orchestrator  
**Date:** 2026-07-29  
**Repo:** `dev-agents` (AI orchestration toolkit)  
**Output:** Each author writes **one** proposal file (path assigned in your task). Do **not** edit other authors’ files. Do **not** implement product UI beyond the proposal markdown (no app code in this wave).  
**Shared-doc rule:** In the proposal body prefer **Proposal seat A / B / C** language for multi-seat process. Filenames may follow existing `*-proposal-<seat>.md` convention. No Soft-live DD branding constraints beyond normal git-ship (no AI vendor marketing on commit/PR text if you open a PR).

---

## 1. Goal

Design an **Experience Console** (name open — propose better if needed): a great **UI/UX** for anyone running `dev-agents` so they can answer, at a glance:

1. **What repos / companies** has this toolkit worked on?
2. **What tasks / issues / PRs** did the fleet touch (per repo and global)?
3. **Which agent roles** were used most (and with what outcomes)?
4. **What skills** exist, which roles inject them, and how experience has **evolved** (version, promote path, “seniority” of the fleet playbooks)?
5. **What learnings** exist (project vs global), and which are still stubs vs promoted into skills?
6. **Global overview** and **per-repo / per-company** views — same dual scope as skills evolution.

This is **not** a replacement for GitHub Issues/Projects. GitHub = tickets assigned to humans.  
This console = **what the multi-seat fleet did, learned, and now knows how to do**.

**Owner context:** Product work on Olympus is paused (waiting on external partner feedback). Owner wants this console designed properly (three competing proposals) then built as the next `dev-agents` vertical.

---

## 2. Owner inspiration (must address)

From the owner (paraphrased — treat as product intent):

> I want an interface for `dev-agents` that shows which repos and tasks have been worked on, plus an overview of learnings, skills, and everything relevant for an engineer using the toolkit.  
> On GitHub I see tickets in my name and for the project(s). In `dev-agents` I want to see **what issues/tickets I have worked on using this tool** and **what skills I have acquired** — **per project and global**.  
> A view **per repo** and a **global overall**. It is a simple layer/dimension, but it unlocks more (promotion loop, seat quality, Conductor history, etc.).  
> Also: which agents have been **mostly used**, and how much they have **improved by skills** and evolved toward **more seniority** (playbook maturity, not fake “agent IQ” scores).

### Inspiration → design problems proposals must solve

| Inspiration | Design problem |
|-------------|----------------|
| GitHub-like “my work” but for fleet | Join handoffs / plans / PRs / optional issue numbers into a personal + fleet work feed |
| Skills acquired (project + global) | Dual-scope skill library with versions, roles, promote status |
| Learnings overview | Timeline + promote-to-skill status (raw → candidate → skill pack) |
| Per repo + global | Company/repo switcher + rollup home |
| Agents most used | Role frequency, success/fail, critic loops, vendor primary (from provenance) |
| Seniority / skill evolution | Honest metrics: skill versions, coverage of roles, learning→skill rate, critic bite, time-to-ship — **not** anthropomorphic “agent leveled up to senior” without evidence |

---

## 3. Current system (facts — do not invent)

### 3.1 Data that already exists

| Source | Location | Use |
|--------|----------|-----|
| Companies / repos | `companies/*.md` (frontmatter: name, repo, github, phase) | Repo catalog |
| Wave plans | `wave-plans/**/*.plan` | What was planned |
| Handoffs | `wave-plans/*/handoffs/*.{jsonl,md}` | Task outcomes, provenance, do-not-repeat |
| Evidence scorecard | `make evidence` / `scripts/wave-report.sh` → `logs/evidence*` (gitignored) | Quality aggregates |
| Provider scorecard | `make scorecard` | Rate-caps / cooldowns |
| Global skills | `skills/<id>/SKILL.md` + `config/role-skills.yaml` | L2 playbooks |
| Project skills | product repo `skills/` (when present) | Override global by id |
| Learnings | fleet `learnings/`; product repos may have `docs/qa/learning-*.md` | History |
| Session modes | `docs/session-modes.md`, `templates/task-packet.md`, `wave-plans/conductor/` | Conductor trails |
| Vendor auth | `scripts/vendor-auth-check.sh` | Preflight health |
| Freezes | `docs/proposals/*-SYNTHESIS.md` | Law for skills/modes |

### 3.2 Laws that already freeze (obey)

- Skills evolution SYNTHESIS: **promotion is PR-only**; global skills human-merge always; no producer auto-merge; no vector daemon as source of truth.
- Session modes Phase 0: modes are contracts; Conductor does not implement product code; Session Auto ≠ `dispatch.sh --auto`.
- Delivery face: no AI/vendor branding on commits/PRs (`git-ship`).
- Experience inputs do **not** auto-write `skills/*/SKILL.md`.

### 3.3 What does NOT exist yet

- No first-class **operator console / dashboard** for experience.
- No unified **“work I ran through the fleet”** index (only raw handoffs + CLI evidence).
- No **skill maturity / seniority** visualization.
- No **learning → skill** pipeline UI.
- No permanent join of GitHub issues to fleet tasks (only free-text issue refs in plan lines when present).

---

## 4. Vocabulary (align proposals)

| Term | Meaning |
|------|---------|
| **Experience Console** | Working name for the UI (rename OK) |
| **Global scope** | Cross-company fleet artifacts under `dev-agents` |
| **Project scope** | One product company (`companies/*.md`) + its product repo artifacts when available |
| **Work trail** | One dispatch/task: plan line → seat → handoff → branch/PR (optional issue) |
| **Skill pack** | Versioned L2 playbook (`skills/<id>/SKILL.md`) |
| **Learning** | Historical note / incident / stub; not automatically a skill |
| **Promotion** | Learning or candidate → skill pack via PR |
| **Role seat** | Role → vendor CLI map (`workers.yaml`) |
| **Seniority (fleet)** | Evidence-backed maturity of playbooks + outcomes for a role — **not** a personality score |
| **Critic loop** | Producer → critic REVISE/APPROVE budget (e.g. 2 loops) |

---

## 5. Requirements (MUST)

### R1 — Dual views

- **Global home:** all companies, recent work trails, skill library summary, learning summary, role usage.
- **Per company/repo:** same cards filtered to that product; project skills + project learnings when discoverable.

### R2 — Work trails

Show fleet work with enough to answer “what did we do with the tool?”:

- company/repo, role, wave/plan, branch, status (from handoff), timestamps if present  
- optional issue/PR links when parseable from task text or handoff  
- Conductor paths under `wave-plans/conductor/` first-class when present  

### R3 — Skills

- List global packs + versions + which roles inject them (`role-skills.yaml`)  
- Show project overrides when scannable  
- Make **promotion status** visible (active pack vs `_candidates/` vs “learning only”)  
- No auto-edit of skills from the UI in Phase 0–1 (read-only or links to open PR)  

### R4 — Learnings

- Index fleet `learnings/` and known product learning paths (propose discovery rules; do not invent private paths)  
- Status model: raw / documented / promoted (into skill) / superseded  

### R5 — Role usage & “seniority”

Must include **honest** analytics, e.g.:

- tasks per role (n, success/fail if known)  
- primary vendor mix from provenance when present  
- critic involvement rate if detectable  
- skill coverage: does this role have dedicated packs beyond defaults?  
- evolution: skill version bumps over time (git history optional Phase 1+)  

**Forbidden:** fake “Agent is Senior III” badges without a transparent formula. If you propose a seniority model, it must be **explainable and evidence-cited**.

### R6 — UX quality bar

This is a **product UI**, not a dump of JSON:

- Clear information hierarchy (home → company → trail → artifact)  
- Fast scan for a busy founder/engineer (≤ 3 clicks to a handoff or skill)  
- Empty states that teach (“no handoffs yet — run dispatch”)  
- Works on laptop; mobile optional  
- Dark/light: propose; prefer system-friendly defaults  
- Accessibility: keyboard, contrast, semantic headings  

### R7 — Architecture constraints

- Prefer **read-only projection** of git-tracked (and explicitly local) artifacts.  
- **No new always-on daemon** required for Phase 0. Optional local static server or `make experience` is fine.  
- Do not require cloud SaaS or API keys for core views.  
- Secrets must never appear (redact tokens if scanning logs).  
- Coexist with CLI: `make evidence`, `make scorecard`, `make vendor-auth` remain source of some aggregates.  

### R8 — Phasing

Propose phases with a shippable **Phase 0** (days, not months):

- Phase 0: usable overview from existing data (even if imperfect joins)  
- Phase 1: richer joins (PR/issue), skill evolution timeline  
- Phase 2+: only if Phase 0 is loved (optional automation, push notifications, etc.)  

---

## 6. Requirements (SHOULD)

- Search/filter: role, company, status, skill id  
- “Do not repeat” themes aggregated from handoff md  
- Link out to GitHub PRs/issues when URL or `owner/repo#n` is present  
- Export: optional static HTML checked in or generated under `docs/experience/` / `site/`  
- Multi-user later: Phase 0 may assume single operator (Arlen)  

---

## 7. Requirements (MUST NOT)

- Replace GitHub Projects / issue tracking  
- Auto-promote skills from the UI  
- Invent metrics without defining inputs  
- Store secrets or full agent transcripts in a public static site by default  
- Hard-depend on Paperclip heartbeat for core views (Paperclip may be a later optional panel)  

---

## 8. Success criteria (for SYNTHESIS later)

A good proposal set lets the owner freeze something that:

1. An engineer can open and **understand fleet work in < 2 minutes**  
2. Shows **global vs project** skills/learnings without confusion  
3. Shows **role usage** with transparent stats  
4. Defines a credible **maturity/seniority** story or explicitly rejects vanity scores  
5. Ships a **Phase 0** that is beautiful enough to use daily, not a prototype dump  

---

## 9. Proposal deliverable shape (each author)

Write markdown only. Suggested sections:

1. Product name + one-sentence pitch  
2. User journeys (global home, company page, skill, learning, work trail)  
3. Information architecture + wireframes (**ASCII or structured component inventory** — high fidelity in prose is OK; mock screens welcome as markdown/HTML sketches)  
4. Data model / joins from existing files  
5. Metrics: role usage + skill evolution / seniority model  
6. UX principles + visual system (type, color, density)  
7. Phase 0 ship list (concrete files/commands)  
8. Risks, non-goals, open questions  
9. Why this design is better than “just `make evidence` + README”  

**Length:** thorough but scannable. Prefer sharp decisions over exhaustive research.

---

## 10. Evaluation criteria (owner will use)

| Weight | Criterion |
|--------|-----------|
| High | Dual-scope clarity (global / project) |
| High | Phase 0 shippability on real artifacts |
| High | UX hierarchy and daily usability |
| High | Honest role/skill maturity model |
| Med | Beauty / craft of the interface concept |
| Med | Fit with Session Modes + skills freezes |
| Low | Clever tech stack (stack is secondary to product) |

---

## 11. Related reading (in-repo)

- `docs/proposals/skills-evolution-SYNTHESIS.md`  
- `docs/session-modes.md` + `docs/proposals/session-modes-SYNTHESIS.md`  
- `docs/operator-guide.md` (Ground Truth, Evidence, vendor auth)  
- `skills/README.md`, `config/role-skills.yaml`  
- `companies/*.md`  
- `scripts/wave-report.sh`  

---

## 12. Explicitly out of this proposal wave

- Implementing the UI (separate wave after SYNTHESIS)  
- Changing dispatch/runtime behavior except as optional thin generators  
- Olympus product features  
- Multi-tenant SaaS productization  
