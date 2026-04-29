---
name: olympus
status: active
repo: ../olympus-platform
paperclip_company_id: ec35552a-a808-46f3-acbe-4e6dec4969f1
paperclip_issue_prefix: OLY
budget_monthly_cents: 10000  # €100/mo, set 2026-04-28 — see PAPERCLIP.md § 6.1
paperclip_project_id: 16a1b183-4800-4b35-95a6-f9c3730579e0  # Onboarding (default)
paperclip_workspace_id: a7238075-4236-44ff-82c6-95a5bb9d60af
github_repo: Arlencho/olympus-platform
github_default_branch: main
---

# Olympus — AI Travel Booking Platform

## Charter

End-to-end AI-orchestrated travel: search → plan → book → travel → memory. Solo-founder, pre-revenue MVP. Demo target: London 2026-05-15.

Source-of-truth product repo: [`olympus-platform/`](../../olympus-platform/) — own CLAUDE.md, own PRD-first policy, own deploy pipeline. This manifest is the **orchestration view** of Olympus, not the product spec.

## Active phase

| Item | Value |
|---|---|
| Wave plan in flight | `wave-plans/olympus-booking-checkout-2026-04-24.md` |
| Demo deadline | 2026-05-15 (London) |
| Production URLs | `api.olympus-ai.tech` (Cloud Run), `app.olympus-ai.tech` (Vercel) |
| Stage | Alpha — near-zero real users |

## Budget cap

| Line | Cap (EUR/mo) | Source |
|---|---:|---|
| Anthropic API (Claude Code agent runs) | covered by total | `olympus-platform/docs/COST_INVENTORY.md` § 2.1 |
| **Total cross-provider** (set 2026-04-28) | **€100** | Paperclip company `budgetMonthlyCents: 10000` |

Budget-hit policy: Paperclip rejects new task dispatch. Existing in-flight tasks complete. Notification to Arlen via Paperclip UI.

## Agent roster

### Live in Paperclip (hired 2026-04-28 via OLY-2 — CEO used `paperclip-create-agent` skill)

Each engineer's `AGENTS.md` is byte-for-byte verbatim from the listed role file. CTO has a custom 4.4 KB charter (no source file). All under Paperclip company `ec35552a-a808-46f3-acbe-4e6dec4969f1`.

| Title in Paperclip | Paperclip agent id | Paperclip role | Model | reportsTo | dev-agents source |
|---|---|---|---|---|---|
| Orchestrator | `bdbf8aad-5fd6-4336-9c6f-47e1b1d8dbe6` | ceo | opus | — (top) | (Paperclip-generated CEO instructions; mirrors `roles/orchestrator.md` discipline) |
| CTO | `a54874c4-...` | cto | opus | Orchestrator | custom charter — not from a role file |
| Backend Engineer | `7cc24e11-...` | engineer | sonnet | CTO | `roles/go-backend.md` |
| Frontend Engineer | `c698ce1d-...` | engineer | sonnet | CTO | `roles/web-frontend.md` |
| Database Engineer | `76b65114-...` | engineer | **opus** (Amendment A — 2026-04-29) | CTO | `roles/db-architect.md` |
| API Designer | `de5fe798-...` | designer | sonnet | CTO | `roles/api-designer.md` |
| QA Engineer | `5c0cd279-...` | qa | **opus** (test-first — 2026-04-29) | CTO | `roles/test-engineer.md` |
| DevOps Engineer | `d7dd47a2-...` | devops | sonnet | CTO | `roles/devops.md` |
| Security Engineer | `b940a8ce-...` | security | opus | CTO | `roles/security-reviewer.md` |
| API Critic | `b16585ed-...` | critic | opus | CTO | `roles/api-critic.md` (NEW — see § Pairing matrix) |
| Backend Critic | `b1dd31d7-...` | critic | opus | CTO | `roles/backend-critic.md` (NEW) |
| Database Critic | `a5e50b32-...` | critic | opus | CTO | `roles/database-critic.md` (NEW) |
| Frontend Critic | `81f04cfc-...` | critic | opus | CTO | `roles/frontend-critic.md` (NEW) |

### Producer-Critic pairing matrix (heterogeneous, OLY-11 — 2026-04-29)

The Critics report to CTO (for **independence**), but they **pair** with their producer counterpart on every implementation task. The pairing is invoked by the CEO routing playbook, not by a `reportsTo` edge — Paperclip's org chart is a tree and can't render peer edges.

| Producer | Producer model | Critic | Critic model | Discipline scope |
|---|---|---|---|---|
| Frontend Engineer (`c698ce1d-...`) | sonnet | Frontend Critic (`81f04cfc-...`) | opus | Next.js / React / Tailwind / a11y / PRD `01-conventions.md` § 3.3 |
| Backend Engineer (`7cc24e11-...`) | sonnet | Backend Critic (`b1dd31d7-...`) | opus | Go / Chi / pgx / sqlc / OpenAPI contract |
| Database Engineer (`76b65114-...`) | **opus** (Amendment A) | Database Critic (`a5e50b32-...`) | opus | Postgres migrations + sqlc queries + index strategy |
| API Designer (`de5fe798-...`) | sonnet | API Critic (`b16585ed-...`) | opus | `api.yaml` / generated TS client / response envelopes |
| DevOps Engineer (`d7dd47a2-...`) | sonnet | (no critic by design) | — | Infra / CI; Security Engineer covers the review surface |

Cross-cutting reviewers (peers, NOT discipline-paired):
- **QA Engineer** (`5c0cd279-...`, opus) — test-first authorship for every implementation task; runs once per task, before any producer
- **Security Engineer** (`b940a8ce-...`, opus) — red-teams every PR after the discipline Critic's loop; runs once per task, before CTO
- **CTO** (`a54874c4-...`, opus) — final architectural gate; runs once per task, after Security

**Hard rule (OLY-11 charter-level invariant): each Critic uses a different model from its paired producer.** This is the heterogeneity guarantee — same-model pairs share blind spots and lose ~30% of cross-error detection per Anthropic's 2025 multi-agent cookbook + the Reflexion / Constitutional AI literature. Do not "correct" any Critic to Sonnet to save cost.

The Paperclip UI surfaces the pairing via each Critic's `title` field (e.g., `Frontend Critic ↔ Frontend Engineer`) — that's the visual hint on the org-chart card.

### Not yet hired (queue when needed)

These roles exist in `roles/` and would slot into the Olympus team when their domain becomes active:

| Role file | When to hire | Tier |
|---|---|---|
| `roles/performance-engineer.md` | When perf becomes a focus (post-MVP) | sonnet |
| `roles/analytics-agent.md` | When analytics surface ships | sonnet |
| `roles/tech-scout.md` | Could replace the `paperclip-refresh` shell script — keep deferred for now | sonnet |
| `roles/retro.md` | Could become a Paperclip Routine that posts retros after each wave | sonnet |
| `roles/mobile.md` | When `apps/mobile/` is scaffolded (olympus-platform #43) | sonnet |

**Do NOT hire** for Olympus today: CMO, UXDesigner. No marketing or design surface yet. Paperclip's CEO is instructed to defer those.

### Org-chart short-circuits

The CTO is the central point of failure for engineering execution. If CTO becomes overloaded, options:
1. **Add a "Tech Lead" layer** between CTO and engineers (e.g., Backend Tech Lead + Frontend Tech Lead reporting to CTO)
2. **Promote one engineer** to "Senior X" with permission to dispatch sibling engineers — flatter, less ceremony
3. **Keep flat** — let CTO triage all engineering work; this is fine until throughput becomes a bottleneck

Don't add layers prematurely. Monitor `Activity` log for CTO becoming the heartbeat-rate-limit.

## KPIs (orchestration-level — not product KPIs)

- **Task throughput**: # of tasks completed per wave (target: 100% of P0/P1 in scope)
- **Cycle time**: median minutes per task from checkout to merged PR
- **Cleanup compliance**: % of tasks where post-task hook successfully removed worktree (target: 100%)
- **Budget burn rate**: EUR spent / cap, weekly snapshot
- **Retro coverage**: % of merged waves with a `retros/` entry within 7 days

Product KPIs (MAU, conversion, etc.) live in `olympus-platform/docs/` — not here.

## Escalation rules

1. **Budget at 80% of cap** — Paperclip notifies, no dispatch block
2. **Budget at 100%** — Paperclip blocks new dispatch; in-flight completes
3. **Two consecutive task failures on same role** — pause that agent type, require human review
4. **Production deploy step in a task** — never auto-execute. Paperclip surfaces approval prompt; Arlen confirms in UI before `make deploy-api` / `make deploy-web` runs
5. **Schema migration** — same as deploy: approval gate, never auto

## Existing scaffolding

Olympus is the most-prepared company. The following already exist in `olympus-platform/`:

- `scripts/task-worktree.sh` — per-task git worktree (reads `$PAPERCLIP_TASK_ID`)
- `scripts/load-gh-token.sh` — GH token loader for Paperclip agent hosts
- `docs/operations/secret-rotation.md` § "Paperclip agent host" guidance
- `docs/operations/env-vars-api.md` § "Agent workspace env vars (local Paperclip)"
- `CLAUDE.md` § "Parallel Workflow" → "Numbered flow" already references `$PAPERCLIP_TASK_ID`

Net: Olympus → Paperclip integration is mostly *finishing what's started*, not new wiring.

## Open follow-ups

- [x] Create company in Paperclip UI — done 2026-04-27 (id recorded in frontmatter)
- [x] First end-to-end Paperclip task — OLY-1 "Audit PAPERCLIP.md against live config" completed cleanly via Orchestrator agent
- [x] Build engineering team — done 2026-04-28 via OLY-2; 9 agents (CEO + CTO + 7 specialists), all `AGENTS.md` byte-for-byte verbatim
- [x] Set monthly budget cap to €100/mo — done 2026-04-28 via `PATCH /api/companies/<id>` `{budgetMonthlyCents: 10000}`
- [x] Re-test the audit loop with delegation working — done 2026-04-28 via OLY-3 → CEO created child OLY-4 → assigned to QA Engineer; both completed in ~50s, zero IC work by CEO
- [x] Connect Onboarding project to GitHub repo `Arlencho/olympus-platform` — done 2026-04-28 via `POST /api/projects/<id>/workspaces` (workspace `a7238075`, cwd = local checkout, repoUrl = github, ref = main)
- [ ] Convert one real Olympus wave-plan into Paperclip task defs as the first *implementation* task (writes product code, not just audits)
- [ ] Wire post-task cleanup hook (the 76-worktree gap from 2026-04-27)
- [ ] Decide: keep `dispatch.sh` for ad-hoc, or migrate fully to Paperclip after first implementation wave succeeds
