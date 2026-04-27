---
name: olympus
status: active
repo: ../olympus-platform
paperclip_company_id: ec35552a-a808-46f3-acbe-4e6dec4969f1
paperclip_issue_prefix: OLY
budget_monthly_cents: 0  # unlimited; cap pending — see PAPERCLIP.md § 8
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
| Anthropic API (Claude Code agent runs) | TBD | `olympus-platform/docs/COST_INVENTORY.md` § 2.1 |
| Total cross-provider | TBD | Set in Paperclip UI after company creation |

Budget-hit policy: Paperclip rejects new task dispatch. Existing in-flight tasks complete. Notification to Arlen via Paperclip UI.

## Agent roster

Subset of `roles/` that Olympus actually uses. Adding a role here = enabling it for this company in Paperclip.

| Role | File | Model tier | Used for |
|---|---|---|---|
| `orchestrator` | `roles/orchestrator.md` | opus | First conversation, planning, dispatch decisions |
| `go-backend` | `roles/go-backend.md` | sonnet | `apps/api/` — Chi router, pgx, sqlc, Anthropic Go SDK |
| `web-frontend` | `roles/web-frontend.md` | sonnet | `apps/web/` — Next.js App Router, Tailwind |
| `db-architect` | `roles/db-architect.md` | sonnet | `apps/api/db/` — migrations, sqlc queries |
| `api-designer` | `roles/api-designer.md` | sonnet | `api.yaml`, `packages/api-client/` |
| `test-engineer` | `roles/test-engineer.md` | sonnet | Test files, `docs/qa/` |
| `devops` | `roles/devops.md` | sonnet | `infra/`, `Makefile`, CI workflows |
| `security-reviewer` | `roles/security-reviewer.md` | opus | Pre-merge security review |
| `performance-engineer` | `roles/performance-engineer.md` | sonnet | Profiling, optimization |
| `analytics-agent` | `roles/analytics-agent.md` | sonnet | Data quality, scoring |
| `tech-scout` | `roles/tech-scout.md` | sonnet | Monthly tooling research |
| `retro` | `roles/retro.md` | sonnet | Post-wave retrospectives |

Mobile (`roles/mobile.md`) is intentionally excluded until `apps/mobile/` is scaffolded (see olympus-platform issue #43).

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
- [ ] Set monthly budget cap (currently unlimited; review Anthropic console first)
- [ ] Convert one real Olympus wave-plan into Paperclip task defs as the first *implementation* task (not just audit)
- [ ] Wire post-task cleanup hook (the 76-worktree gap from 2026-04-27)
- [ ] Decide: keep `dispatch.sh` for ad-hoc, or migrate fully to Paperclip after first implementation wave succeeds
