# Skills + Experience Evolution — Grok seat proposal

| Field | Value |
|-------|-------|
| **Status** | Independent design proposal (Grok seat) |
| **Author** | Grok (systems designer seat, multi-vendor fleet) |
| **Date** | 2026-07-20 |
| **Repo** | `dev-agents` |
| **Brief** | `docs/proposals/skills-evolution-BRIEF.md` |
| **Audience** | Fleet owner + synthesis reviewer (post three-vendor comparison) |
| **Depends on (facts)** | `roles/*.md`, `providers/*/launch.sh`, `providers/lib.sh`, `scripts/dispatch.sh`, `scripts/run-remote.sh`, `scripts/preamble.sh`, `scripts/learnings.sh`, `scripts/retro-data.sh`, `roles/retro.md`, Phase-1 handoffs as raw audit (Phases 2–5 parked) |

> **Independence note.** This document is written without reading the Claude or Kimi proposal files. Divergence is intentional. Optimize for **correctness and implementability on bash + git + existing launchers**, not for novelty.

---

## 1. Executive summary

Agents today have **L1 charters** (`roles/*.md`) and **L3 case files** (preamble: git, learnings slice, handoffs). They lack **L2 skill packs** — short, versioned playbooks that encode *how* to do a class of work. Experience *is* captured (learnings JSONL, handoff intent, retro reports) but **never promotes** into durable procedure. That gap is why the same mistakes reappear across waves and vendors.

This proposal adds:

1. A **small shared catalog** of global L2 skill packs under `skills/` in `dev-agents`, mapped to roles by `config/role-skills.yaml`.
2. A **uniform injection path**: launchers already inject the charter for non-Claude vendors; extend that path (and Claude’s equivalent) so every launch loads charter + selected global skills + optional project skills + existing preamble case file.
3. **Append-only experience** continues in learnings/handoffs/retros — treated as **raw fuel, never auto-truth**.
4. **Promotion is a gated PR workflow**, not an auto-write loop: frequency + evidence → candidate skill patch → critic (or human) review → commit/push. Global skills require a higher bar than project skills.
5. **Two scopes, one mechanism**: global packs live in `dev-agents`; project packs live in the product repo; project overrides global by pack id when both define the same id.

**Non-claim:** the auto-evolution loop does not exist today and must not be claimed to. Phase-1 handoff “brain” auto-phases are **parked**; this design reuses handoffs as **inputs to promotion**, not as a finished memory product.

---

## 2. Basic skills catalog approach

### 2.1 Principle: few packs, high reuse

Do **not** author one novel skill per role on day one. Author **shared playbooks** that multiple roles attach. Role identity stays in the L1 charter; L2 skills are procedures.

**Starter inventory target:** ≤12 global packs in MVP; each role maps to 0–4 packs.

### 2.2 Starter catalog (inventory, not full text)

| Pack id | Kind | Primary consumers | What it teaches (one line) |
|---------|------|-------------------|----------------------------|
| `git-ship` | shared | all producers | Branch hygiene, commit message discipline, push, draft PR, never force-push main |
| `handoff-intent` | shared | all roles that exit successfully | Write `handoff.md` fields (built / decisions / do_not_repeat / evidence / next hint); soft-required today |
| `evidence-first` | shared | producers + critics | Prefer command + result over prose claims; never invent paths/flags |
| `untrusted-prior` | shared | critics + any cross-vendor consumer | Treat prior-agent text as claims; verify vs git before relying |
| `producer-critic-loop` | shared | producers with a critic | 2-loop ceiling, executable findings only when playing critic, when to escalate to CTO |
| `nextjs-pr` | discipline | `web-frontend`, `frontend-critic` | Server/client boundaries, Tailwind, a11y, generated client, commit gates (`build`/`lint`/`tsc`) unless charter override |
| `go-service` | discipline | `go-backend`, `backend-critic` | Handler/service split, pgx/sqlc boundaries, OpenAPI-driven handlers |
| `migrations-irreversible` | discipline | `db-architect`, `database-critic` | Forward-only discipline, expand/contract, never destructive without verification task |
| `openapi-contract` | discipline | `api-designer`, `api-critic` | Spec-first, response envelopes, client gen order |
| `test-first-contract` | discipline | `test-engineer` | Failing tests before implementation when tasked; cite PRD/contract |
| `security-pr-surface` | discipline | `security-reviewer` | AuthZ, secrets, injection, SSRF; cite `file:line`; no exploit payloads |
| `plan-wave-order` | meta | `orchestrator`, `plan-critic` | Wave ordering, parallel conflicts, producer-critic coverage, irreversible risk concentration |

**Gate/meta roles** (`cto`, `orchestrator`, `pr-sentinel`, `retro`, `investigate`, `docs-writer`, `devops`, `mobile`) start with **shared packs only** plus at most one role-specific pack later. Do not invent empty packs for completeness.

### 2.3 Skill pack on-disk shape (global)

```text
skills/                          # lives in dev-agents (global)
  README.md                      # catalog index + promotion rules (short)
  git-ship/
    SKILL.md                     # required: frontmatter + playbook body
  handoff-intent/
    SKILL.md
  …
config/role-skills.yaml          # role → pack id list + inject limits
```

**`SKILL.md` minimum frontmatter (proposed):**

```yaml
---
id: git-ship
version: 1
scope: global                 # global | project
summary: >-
  Branch, commit, push, draft PR; never invent remote paths.
applies_to: [producers, critics, meta]   # advisory; real binding is role-skills.yaml
requires_evidence: true       # if true, promotion patches must cite learnings/handoffs/retros
max_lines: 120                # hard budget for injection (body after frontmatter)
---
```

Body is **actionable steps and anti-patterns**, not identity. Soft max ~120 lines after frontmatter so multi-pack injection stays under a fixed token budget (see §3.3).

### 2.4 How the starter set is chosen (process, not magic)

1. Mine existing charters for **repeated procedure blocks** (commit gates, handoff rules, never-touch) → extract to packs; leave identity in charter.
2. Mine `learnings/` prose notes + any future `learnings/*.jsonl` for **repeated failures**.
3. Mine handoff `do_not_repeat` across `wave-plans/*/handoffs/*.md` for **cross-task dead ends** (raw claims — count frequency, do not auto-trust content).
4. Stop when packs cover the **top failure classes**, not when every role has a unique novel.

---

## 3. Runtime model (charter + global skills + project skills + case file)

### 3.1 Layer stack (every launch)

```text
┌──────────────────────────────────────────────────────────┐
│ L1  Charter     roles/<role>.md  (identity + hard laws)  │
│ L2  Skills      global packs + project packs (playbooks) │
│ L3  Case file   preamble: project notes, learnings,      │
│                 git, issue, provider continuity,         │
│                 prior handoffs (UNTRUSTED delimiter)     │
│ Task            plan-line task text                      │
└──────────────────────────────────────────────────────────┘
```

**Authority order when instructions conflict:**

1. Hard laws in L1 charter (never-touch, commit gates unless task charter-override)
2. **Project skill** with same pack `id` overrides **global skill** body
3. Global skill
4. L3 case file (learnings / handoffs are **advisory**)
5. Task text for *this* job’s acceptance criteria

Handoffs and learnings **never outrank** a skill or charter. That is the core lesson from Phase-1 trust design: self-reports are fuel, not law.

### 3.2 Multi-vendor load path (concrete, reuse existing code)

Today (verified):

| Vendor | Charter injection | Preamble | Skills |
|--------|-------------------|----------|--------|
| Claude | `claude --agent "$ROLE"` (resolves agent md under provider agents dir) | `preamble.sh` via `run-remote.sh` prepended to task | **none** |
| Kimi | `providers/kimi/launch.sh` prepends stripped `roles/$ROLE.md` | same | **none** |
| Grok | `providers/grok/launch.sh` prepends stripped `roles/$ROLE.md` | same | **none** |

**Proposed injection owner:** a new helper (name illustrative) `scripts/skill-inject.sh` (or a function in `providers/lib.sh`) that:

**Inputs:** `ROLE`, product `REPO_PATH` (for project skills), optional `DEV_AGENTS_ROOT`.  
**Reads:** `config/role-skills.yaml`, `skills/<id>/SKILL.md`, and if present `$REPO_PATH/skills/<id>/SKILL.md` or `$REPO_PATH/.agent-skills/<id>/SKILL.md` (pick **one** project path in Phase 0 freeze; recommend `skills/` at product root for symmetry with global).  
**Outputs:** markdown block:

```text
## Skill packs (L2)
### <id> v<version> [global|project]
<body truncated to max_lines>
…
```

**Call sites:**

1. **Kimi / Grok launchers** — after charter, before task (same prompt composition they already do).
2. **Claude** — either:
   - **Preferred for fleet parity:** prepend the same skills block into the task string in `run-remote.sh` (alongside preamble), so Claude does not depend on a vendor-native skill registry; or
   - Optionally *also* sync packs into Claude’s agent-adjacent dirs later — **not required for MVP**.
3. **Preamble stays L3 only** — do **not** fold skills into `preamble.sh`. Skills are stable playbooks; preamble is session/case. Mixing them recreates “prompt soup” and makes caching/budgets harder.

**Ship of skills to workers:** same precedent as charter + launcher scp in `run-remote.sh` — ship `skills/` + `role-skills.yaml` into `~/dev/agent-runtime/` (or resolve from a checked-out `dev-agents` clone on the worker if already present). Do not invent a new daemon.

### 3.3 Budget and selection

`config/role-skills.yaml` (proposed shape):

```yaml
# role-skills.yaml — pack attachment + inject limits
defaults:
  max_packs: 4
  max_total_lines: 400

roles:
  web-frontend:
    packs: [git-ship, handoff-intent, evidence-first, nextjs-pr]
  frontend-critic:
    packs: [untrusted-prior, evidence-first, nextjs-pr, producer-critic-loop]
  plan-critic:
    packs: [plan-wave-order, untrusted-prior, evidence-first]
  # …
```

If a role lists more than `max_packs`, **truncate by list order** (operator-controlled priority). Never silent “smart” ranking by model.

### 3.4 Vendor-native skill directories (explicit non-source-of-truth)

Grok user skills under `~/.grok/skills`, Claude marketplace/bundled skills, and any Kimi-local packs are **operator conveniences for interactive co-pilot mode**. They are **not** the fleet’s role-mapped L2 store. Fleet learning that only lands in one vendor’s home directory is invisible to the other two seats and to SSH workers. **Source of truth for fleet skills is git in `dev-agents` / product repos.**

---

## 4. Experience capture (success / fail / critic REVISE)

### 4.1 Reuse what exists (do not replace)

| Event | Existing mechanism | Change for skills evolution |
|-------|--------------------|-----------------------------|
| Task fail (exit ≠ 0, ≠ 75) | `run-remote.sh` → `learnings.sh add … failure` | Keep; optionally add structured fields later (§4.3) |
| Rate-cap 75 | learnings high + provider cooldown | Keep; **not** a skill-promotion signal |
| Success exit 0 | handoff.md pull → `wave-plans/<wave>/handoffs/*.md` + JSONL mechanical | Keep; mine `do_not_repeat` / decisions in promotion jobs |
| Critic REVISE/BLOCK | critic output in logs + (if present) handoff | Parse **VERDICT** lines from critic log as a promotion *signal source*, not as auto-edit |
| Human correction | currently ad hoc (chat / PR comments) | New learning type `correction` (optional MVP+) |
| Retro | `scripts/retro-data.sh` + `roles/retro.md` → `docs/retros/` | Retro **must emit promotion candidates** (§5, §8) |

**Handoffs remain raw experience.** Phase-1 A/B killed “auto-brain” phases; this proposal does **not** resurrect silent memory promotion from handoffs. It only allows **humans/critics** to promote *after* pattern evidence.

### 4.2 What gets written when (agent vs orchestrator)

Same inversion as Phase-1 handoffs:

| Writer | May write | Must not write |
|--------|-----------|----------------|
| **Orchestrator** (`run-remote` / dispatch) | Mechanical learnings on fail/ratecap; skill *candidate stubs* with git SHAs, exit, files_touched | Skill body text “what we learned” invented by scripts |
| **Agent** | `handoff.md` intent; optional `scripts/learnings.sh add` for discovery/pattern when charter says so | Direct edits to `skills/**` on the product task branch **unless the task is an explicit skill-promotion task** |
| **Retro agent** | Retro report + `docs/proposals/` or `skills/_candidates/*.md` drafts | Force-merge to global `skills/` without PR |

### 4.3 Minimal learning schema extension (optional, MVP-compatible)

Today’s JSONL fields (`ts, project, agent, type, summary, severity`) are enough for injection. For promotion analytics, **optional** additive fields (ignore if absent):

```json
{
  "ts": "…",
  "project": "black-aces",
  "agent": "web-frontend",
  "type": "failure",
  "summary": "…",
  "severity": "medium",
  "pack_hint": "nextjs-pr",
  "source": "run-remote|agent|retro|human",
  "task_id": "9-web-frontend-feat-ab-T05-jsonld-org",
  "evidence_ref": "wave-plans/9/handoffs/….md"
}
```

Do **not** block MVP on schema migration. Additive only; `learnings.sh` already uses line-oriented JSON.

### 4.4 Critic REVISE → experience

On critic tasks, when log matches `VERDICT: REVISE` or `VERDICT: BLOCK` (or PASS with findings — product-specific):

- Orchestrator may append a learning: `type=pattern` or `failure`, summary = first finding line, `agent` = producer role if known from branch pairing, else critic role.
- Full findings stay in the log path recorded in handoff JSONL — **do not** dump multi-KB critic prose into learnings inject.

---

## 5. Promotion / evolution mechanism

### 5.1 Core rule

```text
experience (append-only)  →  candidate (reviewable patch)  →  skill (git main)
                              ▲
                              └── human OR designated critic gate
```

**Never:** agent success path auto-commits to `skills/` on the same branch as product work.  
**Never:** “summary of handoffs” rewritten by a model becomes global law without a diff review.

### 5.2 Promotion triggers (any one is enough to *open a candidate*, not to merge)

1. **Frequency:** same normalized `do_not_repeat` / learning summary appears ≥ **N times** across tasks or projects (default N=3 for global, N=2 for project).
2. **Severity:** single `high` learning with orchestrator evidence (e.g. repeated migration footgun) + human flag.
3. **Retro action item** explicitly labeled `PROMOTE:` with pack id and evidence links.
4. **Human correction** (“never invent X path”) filed as learning type `correction`.

### 5.3 Candidate artifact

```text
skills/_candidates/<date>-<pack-id>-<slug>.md
```

Contents:

- Target pack id + scope (global|project)
- Proposed diff (or full replacement body if new pack)
- Evidence table: learning lines / handoff paths / retro section (paths must exist in repo)
- Author (retro|human|agent-task-id)
- Blast radius note (which roles inject this pack)

Candidates are **not injected** at runtime.

### 5.4 Approval matrix

| Scope | Who can open candidate | Who can merge to mainline skills |
|-------|------------------------|----------------------------------|
| **Project** | Producer on explicit skill task; retro; human | Human **or** product-area critic on a **skill-only PR** (e.g. frontend-critic for `nextjs-pr` project override) |
| **Global** | Retro; human; orchestrated skill-evolution task | **Human required** for v1. Optional later: `plan-critic` or `security-reviewer` *advisory* review on skill PRs — still human merge |

Spam prevention:

- Max **1 open candidate per pack per week** unless human overrides.
- Candidate without ≥1 **existing path** evidence ref is rejected by a dumb check (`test -f`).
- Pack body growth: reject candidate if new body exceeds `max_lines` without a split proposal.
- Auto-generated candidates land on branch `skill/<pack-id>-<date>`, never direct push to main.

### 5.5 Commit / push paths

**Global (dev-agents):**

```bash
# on branch skill/nextjs-pr-2026-07-20
# edit skills/nextjs-pr/SKILL.md and/or config/role-skills.yaml
git add skills/ config/role-skills.yaml
git commit -m "skill(nextjs-pr): promote repeated a11y dead-end"
git push -u origin HEAD
gh pr create --title "skill(nextjs-pr): …" --body "Evidence: …"
```

**Project (product repo):**

```bash
# product repo
git add skills/<id>/SKILL.md   # or chosen project path
git commit -m "skill(project): …"
git push && gh pr create …
```

Orchestration view: `companies/<product>.md` may **link** to project skill policy in prose; it is not the skill store.

### 5.6 Demotion / expiry

- Packs carry `version` integer; breaking guidance bumps version and notes `supersedes`.
- Retro may open **demote** candidates when a skill causes measured rework increase (A/B or before/after window).
- Stale candidates (>30 days, no activity) deleted or archived under `skills/_candidates/_expired/`.

---

## 6. Global vs project split

### 6.1 Ownership

| Scope | Location | Owners | Applies to |
|-------|----------|--------|------------|
| Global | `dev-agents/skills/<id>/` + `config/role-skills.yaml` | Fleet owner; promotion via PR | All products using the fleet |
| Project | **Product repo** `skills/<id>/` (recommended) | Product engineers + domain critic | That product only |
| Company manifest | `dev-agents/companies/<product>.md` | Orchestration metadata only | Does **not** hold skill bodies |

**Why product repo for project skills:** they travel with the code, survive Paperclip downtime, and are reviewable by the same people who own the product. Storing project-only playbooks only under `companies/*.md` mixes orchestration manifests with procedural text and does not ship to workers checking out the product repo.

### 6.2 Conflict resolution

1. Same pack `id`: **project body replaces global body** for that launch (override, not deep merge).
2. Project may **add** pack ids not in global; `role-skills.yaml` may eventually support per-project overlays — **MVP:** put project-only pack ids in a product file `skills/role-skills.overlay.yaml` read if present; if absent, use global map only and load project bodies only when id matches.
3. Project **cannot** weaken L1 charter hard laws (e.g. security never-touch) via skill text. Charters win.
4. If project skill invents flags/paths that fail verification in a later retro, demote project pack first (smaller blast radius).

### 6.3 Sync to workers / providers

- Global skills ship with agent-runtime scp (or checkout of dev-agents).
- Project skills load from the product worktree already cloned for the task (`WORK_DIR`).
- `scripts/sync-providers.sh` continues to sync **roles only**. Do **not** overload it to copy skills into every vendor agents dir unless a later phase proves Claude native discovery needs it.

---

## 7. Trust & safety

### 7.1 Threat model (skills-specific)

| Threat | Failure mode | Mitigation |
|--------|--------------|------------|
| Hallucinated procedure | Skill invents CLI flags / infra paths → fleet-wide poison | Evidence refs required; critic/human gate on global; `evidence-first` pack; kill bad packs via demote PR |
| Self-report as law | Handoff `do_not_repeat` auto-merged into skill | **Forbidden.** Candidates only; handoffs stay UNTRUSTED at inject |
| Cross-vendor prompt injection | Malicious text in handoff becomes skill | Same delimiter discipline; skills authored under review, not from raw handoff paste without edit |
| Scope creep | 50 novel packs, prompt bloat | `max_packs` / `max_total_lines`; shared-pack bias |
| Silent main mutation | Agent “helpfully” edits `skills/` during feature work | Charter hard law + guardrail optional path deny on product tasks; skill edits only on `skill/*` branches / explicit tasks |
| Confabulated learnings | Fail tail noise becomes pattern | Frequency threshold; severity floors for global; human merge |

### 7.2 Anti-hallucination rules for skill authors (charter-level for skill-evolution tasks)

1. Every imperative that names a path, script, or flag must appear in **this repo** or the **product repo** at proposal time (`test -f` / `rg`).
2. No “should exist” infrastructure. If unsure, write the skill as a **checklist question**, not a command.
3. Prefer linking to existing scripts (`scripts/learnings.sh add …`) over re-describing them.
4. Skills must not instruct agents to skip security or guardrails.

### 7.3 Untrusted inputs stay untrusted

Prior handoffs continue to inject under the existing delimiter in `preamble.sh`. Skills that teach critics to **verify before trust** (`untrusted-prior`) are the durable form of that lesson; the delimiter remains for L3.

### 7.4 No auto-merge to global

Even if frequency thresholds fire, automation may only open a PR or write `skills/_candidates/`. Merge is human for global v1. This is intentional friction proportional to blast radius.

---

## 8. Retros at scale (fleet speed without human-only bottleneck)

### 8.1 Current state

- `scripts/retro-data.sh` aggregates plans, logs, learnings, git/PR signals.
- `roles/retro.md` writes `docs/retros/<date>-retro.md` with action items.
- **Not wired to skills.**

### 8.2 Wire-up (no new daemon)

**Trigger options (pick in rollout; all are cron/launchd or manual):**

1. After each milestone dispatch (human or orchestrator task line).
2. Weekly scheduled job on the dispatcher host:  
   `scripts/retro-data.sh all | … launch retro …`
3. When learnings count since last retro exceeds threshold (scriptable).

**Retro output extension (required for this design):**

In addition to today’s three sections, retro **must** include:

```markdown
## Promotion candidates
| Pack id | Scope | Signal | Evidence | Action |
|---------|-------|--------|----------|--------|
| nextjs-pr | global | do_not_repeat ×4 | wave-plans/…/….md | PROMOTE draft |
| git-ship | project/olympus | fail learnings ×3 | learnings/olympus.jsonl | OPEN candidate |

## Demotion candidates
| Pack id | Why | Evidence |
```

Optionally write machine-readable stubs under `skills/_candidates/` in the **dev-agents** worktree when retro runs with write permission there.

### 8.3 Human bottleneck relief (not removal)

| Step | Automated | Human |
|------|-----------|-------|
| Collect retro-data | Yes | No |
| Cluster repeated learnings / do_not_repeat | Semi (script counts + retro LLM) | Spot-check |
| Draft candidate skill patch | Yes (retro or skill-evolution task) | Edit for truth |
| Merge global skill | No (v1) | Yes |
| Merge project skill | Critic-optional | Yes or domain critic |

Fleet speed comes from **batching** (one retro → many candidates) and **parallel project merges**, not from unsupervised global writes.

### 8.4 Cross-project synthesis

Retro with `project=all` is the fleet-scale lens. Global pack promotions should prefer **multi-project** evidence. Single-project pain stays project-scoped until it appears elsewhere or the owner elevates it.

---

## 9. Phased rollout

### Phase 0 — Freeze conventions (1–2 days, docs only)

- Land this design (or synthesis) agreement on: project skill path (`skills/` vs `.agent-skills/`), `role-skills.yaml` shape, candidate dir.
- Add `skills/README.md` promotion rules (short).
- **Kill criterion for the whole program** written before Phase 1 code (see §10).

### Phase 1 — MVP (≈2 weeks)

**Ship:**

1. Create 4–6 global packs: `git-ship`, `handoff-intent`, `evidence-first`, `untrusted-prior`, plus 1–2 discipline packs for the active pair (`nextjs-pr` if frontend remains flagship).
2. Add `config/role-skills.yaml` for roles actually seated in `workers.yaml`.
3. Implement skill text assembly in `providers/lib.sh` (or `scripts/skill-inject.sh`) and call from **kimi + grok** launchers; inject via **run-remote task prefix** for claude parity.
4. Ship skills tree to workers with existing scp pattern.
5. Charter one-liner: product tasks must not edit `skills/` unless task says so.
6. Retro template gains **Promotion candidates** section (docs + `roles/retro.md`).
7. Manual promotion only (human PRs). No auto-candidate writer required yet.

**Prove:** one producer→critic pair shows reduced repeated `do_not_repeat` themes over N tasks **or** faster critic PASS on previously failed classes.

### Phase 2 — Capture → candidate (≈2–4 weeks after MVP)

- Script: `scripts/skill-candidates.sh` scans learnings + handoff `do_not_repeat` for frequency ≥ N; writes `skills/_candidates/*` **drafts only**.
- Optional learning additive fields (`pack_hint`, `task_id`).
- Project skill path live on one product (e.g. olympus or black-aces).

### Phase 3 — Gated automation

- Dispatchable wave: retro → candidate PRs opened with `gh pr create` on `skill/*` branches.
- Domain critic review on project skill PRs.
- Metrics dashboard via extending `make scorecard` or a small `scripts/skill-metrics.sh` (rework rate, candidate open/merge counts).

### Phase 4 — Only if metrics win

- Consider deeper charter thinning (move more procedure out of `roles/*.md` into packs).
- Optional Claude-native skill sync — still secondary to git source of truth.
- **Do not** auto-merge global skills without a new explicit owner decision.

### Explicitly deferred / forbidden early

- New always-on daemon for “memory”.
- Auto-promotion from handoffs (parked brain phases stay parked).
- Per-vendor skill stores as fleet truth.
- 50 packs on day one.

---

## 10. Success metrics

Measure from data the fleet already produces (logs, handoffs, learnings, critic verdicts, rework loops). Prefer **deltas vs baseline window** before skills injection.

| Metric | Definition | Direction of good | Source |
|--------|------------|-------------------|--------|
| Repeated `do_not_repeat` rate | Distinct normalized dead-ends per 10 tasks that already appeared in prior 30d | ↓ | handoff `.md` |
| Critic rework loops | Producer revise cycles before PASS | ↓ on skill-covered failure classes | dispatch logs / ab-metrics style CSV |
| Critic block rate | REVISE+BLOCK / reviews | ↓ *or* stable with higher defect severity caught — interpret with care | critic logs |
| Learning recurrence | Same summary fingerprint ≥3 in 30d | ↓ after related pack merge | `learnings/*.jsonl` |
| Skill inject compliance | Launches with L2 section present when packs configured | → 100% | launcher logs / preamble-adjacent |
| Candidate quality | % candidates merged without “invented path” revert | ↑ | skill PRs |
| Time-to-promote | Days from first signal → merged pack | ↓ but not at cost of global poison | git history |
| Blast-radius incidents | Global skill reverts per quarter | → 0 | git revert log |

**Program-level kill criterion (binding):** after Phase 1 packs are injected for ≥10 tasks on a flagship pair, if repeated dead-end rate and rework loops show **no improvement** vs prior 10-task window **and** agents ignore skill text (no behavioral change on covered checks), **stop expanding automation** — keep packs as human-edited docs only; do not build Phase 2 candidate spam. Machinery that does not change agent behavior is prompt weight, not experience.

---

## 11. Explicit non-goals

1. Replacing L1 charters with skills (identity and hard laws stay in `roles/*.md`).
2. Auto-merging skills from handoffs or learnings without review.
3. Resurrecting multi-vendor context Phases 2–5 as a dependency (handoffs stay audit/raw fuel).
4. Killing multi-vendor orchestration or forcing one vendor’s native skill system on the fleet.
5. New mandatory cloud memory DB / vector store / always-on daemon for MVP.
6. Per-role unique novels (50 packs) before shared packs prove value.
7. Using rate-cap events as skill content.
8. Re-executing agent “evidence” commands as trust (same stance as Phase-1 synthesis).
9. Implementing this proposal in the same change-set as the proposal document.
10. Silent edits to `skills-evolution-proposal-claude.md` / `…-kimi.md`.

---

## 12. Open questions for the owner

1. **Project skill path freeze:** `skills/` at product root vs `.agent-skills/` vs under `docs/`? (This proposal recommends `skills/` for symmetry.)
2. **Claude injection preference:** task-prefix only (parity with kimi/grok composition) vs also mirroring packs into `providers/claude/agents/` or Claude user skills — which is acceptable operationally on workers?
3. **Global merge policy:** remain human-only indefinitely, or allow a trusted role (e.g. owner + `plan-critic` advisory) after N clean promotions?
4. **Frequency N defaults:** global N=3 / project N=2 — too strict/loose for current volume?
5. **Should `docs-writer` / `devops` get discipline packs in MVP** or only after frontend/backend packs prove the loop?
6. **Guardrails:** add path deny for `dev-agents/skills/**` on product-repo tasks via `config/guardrails.yaml`, or charter-only enforcement first?
7. **Paperclip path:** do Paperclip-hired agents receive the same L2 inject, or only `dispatch.sh` / `run-remote.sh` fleet path in v1?
8. **Candidate privacy:** any product names/secrets risk in promoting learnings text into global packs? (Redaction rule?)
9. **Versioning UX:** integer `version` in frontmatter enough, or require CHANGELOG per pack?
10. **Interaction with company manifests:** should `companies/*.md` list enabled pack ids for that product, or stay out of the skill system entirely?

---

## Appendix A — Implementation sketch (not implementation)

Touch list for Phase 1 (illustrative; implementers verify before coding):

| Piece | Likely files |
|-------|----------------|
| Pack store | `skills/*/SKILL.md`, `skills/README.md` |
| Map | `config/role-skills.yaml` |
| Assemble text | `providers/lib.sh` and/or `scripts/skill-inject.sh` |
| Kimi/Grok load | `providers/kimi/launch.sh`, `providers/grok/launch.sh` |
| Claude parity | `scripts/run-remote.sh` (prefix) |
| Worker ship | `scripts/run-remote.sh` scp section (alongside launcher) |
| Retro section | `roles/retro.md` |
| Tests | extend `tests/run-launcher-tests.sh` — assert skills block present/absent |

No new network services. Failure mode if skills missing: log WARNING, run with charter+preamble only (same degradation spirit as missing charter on kimi/grok).

## Appendix B — Relationship to prior multi-vendor brain work

| Artifact | Role in *this* design |
|----------|----------------------|
| Handoff JSONL mechanical fields | Evidence anchors for promotion; not skill bodies |
| Handoff intent markdown | Source of `do_not_repeat` frequency mining |
| Untrusted delimiter | Remains for L3; skills teach verify-before-trust |
| A/B kill criterion precedent | Copied as program kill criterion for skills automation |
| Parked Phases 2–5 of brain | Stay parked; skills evolution does not unlock them |

## Appendix C — Opinionated positions (Grok seat)

1. **Orchestrator-injected git skills beat vendor skill marketplaces** for a multi-CLI fleet.
2. **Override > merge** for project vs global pack bodies (predictable, testable).
3. **Promotion is a PR problem**, not a prompt-engineering problem.
4. **Start with four shared packs** even if discipline packs slip — shared packs fix cross-role amnesia first.
5. **If it cannot be grepped from an existing path, it must not ship in a skill.**

---

*End of Grok seat proposal.*
