# Brief: Skills + experience evolution for multi-vendor agents

**To:** Independent proposal authors (Claude, Grok, Kimi)  
**From:** Fleet owner (Arlen) via orchestrator  
**Date:** 2026-07-20  
**Repo:** `dev-agents` (AI orchestration toolkit)  
**Output:** Each author writes **one** proposal file (path assigned in your task). Do **not** edit other authors’ files. Do **not** implement code.

---

## 1. Goal

Design a system where:

1. Every agent role starts with a set of **basic (L2) skills** — actionable playbooks, not just identity.
2. Agents **evolve from real experience** (failures, critic findings, human corrections, production incidents).
3. Learning is **persisted and shipped** via **git commit + push**, in **two scopes**:
   - **Global** — shared across all products (lives in `dev-agents`)
   - **Project** — specific to one product repo (e.g. olympus, safeplace, black-aces)
4. **Learnings + retrospects** feed evolution at **fleet scale and speed** (faster than human-only process, but still trustworthy).

We want agents that become **experienced** over time the way humans do (pattern recognition, fewer repeated mistakes) — but with multi-vendor orchestration and durable artifacts.

---

## 2. Current system (facts — do not invent)

### 2.1 Multi-vendor fleet
- Agents run via **subscription CLIs**: `claude`, `kimi`, `grok` — **zero API keys**.
- Launchers: `providers/<vendor>/launch.sh` + `providers/lib.sh`.
- Exit codes: `0` ok, `1` fail, `75` rate-cap, `69` unavailable, `77` guardrails (as documented).
- Seats: `config/workers.yaml` → `provider_preferences` (e.g. `web-frontend: kimi`, critics mostly `claude`).
- Failover: `config/routing.yaml` → `provider_failover`.
- Dispatch: `scripts/dispatch.sh` + `scripts/run-remote.sh` (SSH workers).
- Plan format: `WAVE | AGENT | TASK | BRANCH` (see `docs/plan-file-format.md`).

### 2.2 What agents have today (L1, not L2 skills)
- **Charters:** `roles/*.md` (+ `providers/claude/agents/*.md` for Claude bootstrap).
  - Identity, scope, never-touch, commit gates, handoff rules, critic output discipline.
- **Tools:** Read/Write/Bash/Grep/etc. in frontmatter — not skill packs.
- **No unified** `skills/` tree or `role-skills.yaml` in this repo (yet).
- Vendor-native skill dirs exist **outside** this repo unevenly (e.g. Grok user skills under `~/.grok/skills`); **not** role-mapped by the fleet.

### 2.3 Experience capture that EXISTS
| Mechanism | Location | What it stores | Auto-promotes to skills? |
|-----------|----------|----------------|---------------------------|
| Learnings | `scripts/learnings.sh`, `learnings/*.jsonl` | Cross-session failures/norms | **No** |
| Handoffs (Phase 1) | `wave-plans/<wave>/handoffs/*.{jsonl,md}` | Per-task intent, do_not_repeat, evidence; orchestrator writes mechanical git fields | **No** |
| Dispatch/exec logs | `wave-plans/*.log`, agent logs on workers | Operational outcomes | **No** |
| Provider scorecard | `make scorecard`, `logs/provider-state/` | Rate-caps, cool-downs | **No** |
| Retros | `roles/retro.md`, retro scripts | Periodic synthesis | **Not wired to skills** |
| Preamble inject | `scripts/preamble.sh` | CLAUDE.md slice, learnings, git, handoffs (if enabled) | Injects history; does **not** evolve skills |

### 2.4 Important design decisions already made (handoff “brain”)
- Shared **project brain / handoffs** proposal: synthesis APPROVED for Phase 1; **A/B kill criterion triggered** (easy tasks → ceiling effect). **Phases 2–5 of that design are PARKED.**
- Handoffs remain useful as **human-audit + raw experience**, not as a finished auto-memory product.
- Cross-vendor handoffs are **untrusted claims** (verify against git); orchestrator owns mechanical fields.
- Multi-CLI orchestration **stays**; we are **not** killing the fleet.

### 2.5 Known failure modes to account for
- Docs agents **confabulate** infra paths (e.g. invented Codeium auth path).
- Plan `|` delimiter bugs; branch checkout for critics; Claude Keychain vs non-interactive SSH (`~/.claude/.credentials.json`).
- Skills that invent CLI flags or file paths will poison the fleet.

---

## 3. Vocabulary we use (align your proposal)

| Term | Meaning |
|------|---------|
| **L1 Charter** | Role identity and hard laws (`roles/*.md`) |
| **L2 Skill pack** | Versioned playbook (`SKILL.md` + optional refs) for a class of work |
| **L3 Case file** | This task’s preamble, issue, git, handoff |
| **Global skills** | Live in `dev-agents`, apply to all products |
| **Project skills** | Live in product repo (or `companies/<product>.md` + product `skills/`), apply to one product |
| **Promotion** | Turning repeated experience into an updated skill (or charter) via review + git |

---

## 4. What your proposal MUST cover

Write a **design proposal** (markdown), not implementation.

### Required sections
1. **Executive summary** (≤15 lines)
2. **Basic skills catalog approach** — how to define the starter set per role (inventory, not 100 packs on day one)
3. **Runtime model** — how a launch loads charter + global skills + project skills + case file (multi-vendor: claude / kimi / grok)
4. **Experience capture** — what gets written on success/fail/critic REVISE (reuse vs extend learnings/handoffs/retros)
5. **Promotion / evolution mechanism** — how experience becomes skill updates; who approves; how spam is prevented
6. **Global vs project split** — ownership, conflict resolution (project overrides global? merge?), commit/push paths for both
7. **Trust & safety** — anti-hallucination, untrusted self-report, don’t auto-merge poison into global skills
8. **Retros at scale** — how fleet retros feed promotion without human bottleneck only
9. **Phased rollout** — MVP → scale; what ships in 2 weeks vs later
10. **Success metrics** — how we know agents are “more experienced” (rework rate, repeated do_not_repeat, etc.)
11. **Explicit non-goals**
12. **Open questions for the owner**

### Quality bar
- Ground claims in the **current system facts** above; mark speculation as speculation.
- Prefer mechanisms that fit **bash + git + existing scripts** (no mandatory new daemon unless you justify it).
- Prefer **human or critic gate** before global skill changes (fleet-wide blast radius).
- Name concrete paths/files where possible under `dev-agents/` layout.
- If you recommend automation, specify **triggers, inputs, outputs, failure modes**.

### Output file
Your task assigns the exact path, e.g. `docs/proposals/skills-evolution-proposal-<vendor>.md`.

### Forbidden
- Implementing code or editing other vendors’ proposal files
- Inventing CLI flags or auth paths you cannot verify from this brief or repo scripts
- Claiming the auto-evolution loop already exists (it does not)
- Killing multi-vendor orchestration as a solution

---

## 5. Prompt for your “opinionated” angle

You are one of three independent designers. Optimize for **correctness and implementability on this fleet**, not for agreement with the other two. Divergence is valuable.

After all three proposals exist, humans will compare them (similar to the multi-vendor context transparency review).

---

## 6. Roles in this repo (for catalog thinking)

Producers: `web-frontend`, `go-backend`, `db-architect`, `api-designer`, `devops`, `mobile`, `docs-writer`, `test-engineer`, `investigate`  
Critics: `frontend-critic`, `backend-critic`, `database-critic`, `api-critic`, `plan-critic`  
Gates/meta: `security-reviewer`, `cto`, `orchestrator`, `pr-sentinel`, `retro`

Starter skills should be **few and shared** (packs reused across roles), not 50 unique novels.

---

*End of brief.*
