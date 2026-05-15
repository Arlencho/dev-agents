---
name: safeplace
status: active
repo: github.com/arlenrios/safeplace
paperclip_company_id: f9e2a2e4-85fc-4a79-b9d3-255a78c9883e
paperclip_issue_prefix: SAF
paperclip_project_id: c9ffeb52-aacc-42b5-b340-578bb5fcb9ab  # Onboarding (default)
budget_monthly_cents: TBD  # set in cents (e.g., 10000 = €100/mo)
---

# SafePlace — Real-time safety intelligence for Sweden

## Charter

Real-time safety intelligence for Sweden — police, weather, traffic, fire, and crime data unified on one interactive map. Ship the existing 4-wave backlog (~108 GitHub issues) end-to-end with agents handling code + tests; **the human runs every production deploy and migration.**

Source-of-truth product repo: `github.com/arlenrios/safeplace` (default branch `main`). This manifest is the **orchestration view** of Safeplace, not the product spec.

## Active phase

| Item | Value |
|---|---|
| Wave plan in flight | `wave-plans/safeplace-2026-04-16.md` |
| GCP project | `safeplace-io` (separate from `olympus-ai-tech`) |
| Stack | Go API + server-rendered Go templates, Postgres (Cloud SQL), no React/Next surface, no OpenAPI contract |

## Hard production boundary (charter-level)

Agents do code + tests + **local** migrations only. The user runs every production migration and `make deploy` manually. The CTO charter enforces this — never auto-execute production-mutating commands.

## Agent roster

### Live in Paperclip (hired 2026-05-09 via SAF-1 — CEO used `paperclip-create-agent` skill)

Each engineer's `AGENTS.md` is byte-for-byte verbatim from the listed role file. CTO has a custom Safeplace-adapted charter (mirrors Olympus's CTO charter; swapped `olympus-platform` → `safeplace`, dropped Frontend / API Designer / their Critics because Safeplace has no React/Next surface and no OpenAPI contract). All under Paperclip company `f9e2a2e4-85fc-4a79-b9d3-255a78c9883e`.

| Title in Paperclip | Paperclip agent id | Paperclip role | Model | reportsTo | dev-agents source |
|---|---|---|---|---|---|
| CEO | `6349c9a7-4732-490d-a186-a3404753c532` | ceo | opus | — (top) | (Paperclip-generated CEO instructions) |
| CTO | `b0e92a53-8bef-43f9-b1b1-2b49d5d3f57c` | cto | opus | CEO | custom Safeplace charter — not from a role file |
| Backend Engineer | `6de77351-632c-4f6c-a7b1-87092355025a` | engineer | sonnet | CTO | `roles/go-backend.md` |
| Database Engineer | `e2ecc561-b1c7-45f8-a786-3c8277c8db02` | engineer | **opus** (Amendment A) | CTO | `roles/db-architect.md` |
| DevOps Engineer | `16fd5965-b3b1-43f5-b671-16b4dff12f29` | devops | sonnet | CTO | `roles/devops.md` |
| Security Engineer | `030f4866-ca39-4863-a050-74d68fad8d95` | security | opus | CTO | `roles/security-reviewer.md` |
| QA Engineer | `1a3e4ea7-9f04-4475-b256-74fc413ddb47` | qa | **opus** (test-first) | CTO | `roles/test-engineer.md` |
| Backend Critic ↔ Backend Engineer | `172fbbda-e96c-4a66-b406-d98fe588a4ff` | general (critic) | opus | CTO | `roles/backend-critic.md` |
| Database Critic ↔ Database Engineer | `9deee858-2b87-4426-9f98-a0840ae650da` | general (critic) | opus | CTO | `roles/database-critic.md` |

### Producer-Critic pairing matrix (heterogeneous)

The Critics report to CTO (for **independence**), but they **pair** with their producer counterpart on every implementation task. Pairing is invoked by the routing playbook, not by a `reportsTo` edge — Paperclip's org chart is a tree and can't render peer edges.

| Producer | Producer model | Critic | Critic model | Discipline scope |
|---|---|---|---|---|
| Backend Engineer | sonnet | Backend Critic | opus | Go / Chi / pgx / sqlc / handler conventions / ingestion adapters / templates |
| Database Engineer | **opus** (Amendment A) | Database Critic | opus | Postgres migrations + sqlc queries + index strategy |

Cross-cutting reviewers (peers, NOT discipline-paired):
- **QA Engineer** (opus) — test-first authorship for every implementation task; runs once per task, before any producer
- **Security Engineer** (opus) — red-teams every PR after the discipline Critic's loop; runs once per task, before CTO
- **CTO** (opus) — final architectural gate; runs once per task, after Security

**Hard rule (charter-level invariant): each Critic uses a different model from its paired producer.** Same-model pairs share blind spots. For Database Engineer + Database Critic the heterogeneity is preserved by adversarial framing in the prompt (both Opus, but the Critic's role is to break the producer's work). Backend Engineer (sonnet) ↔ Backend Critic (opus) gives strict cross-model heterogeneity for the Go-heavy surface.

**Paperclip role-enum note:** the canonical `critic` role is not in Paperclip's current enum. The two Critics are hired as `role: general` with their adversarial behavior enforced byte-for-byte in `AGENTS.md`. The pairing surfaces in the org-chart card via the `title` field (e.g., `Backend Critic ↔ Backend Engineer`).

### Not yet hired (queue when needed)

These roles are referenced in the wave-plan but were skipped in the founding hire because they don't apply to Safeplace's current surface (or are deferred):

| Role file | When to hire | Tier |
|---|---|---|
| `roles/web-frontend.md` | NOT NEEDED for Safeplace — UI is Go templates owned by Backend Engineer | — |
| `roles/api-designer.md` | NOT NEEDED for Safeplace — no OpenAPI contract | — |
| `roles/analytics-agent.md` | When Wave 3 BRÅ correlation begins (read-only audits) | sonnet |
| `roles/maintainability-reviewer.md` | When Wave 4 #26 `main.go` split begins | sonnet |
| `roles/investigate.md` | When Wave 3 #41 Polisen-decline diagnosis begins | sonnet |
| `roles/performance-engineer.md` | If perf becomes a focus | sonnet |
| `roles/retro.md` | Could become a Paperclip Routine after each wave | sonnet |

**Do NOT hire** for Safeplace today: CMO, UXDesigner, Frontend Engineer, API Designer, Frontend Critic, API Critic. No marketing surface, no React/Next, no OpenAPI.

## KPIs (orchestration-level — not product KPIs)

- **Task throughput**: # of tasks completed per wave (target: 100% of P0/P1 in scope)
- **Cycle time**: median minutes per task from checkout to merged PR
- **Local-only compliance**: 100% of agent runs respect the production boundary (zero `make deploy`, zero prod migrations)
- **Budget burn rate**: EUR spent / cap, weekly snapshot
- **Retro coverage**: % of merged waves with a `retros/` entry within 7 days

## Escalation rules

1. **Budget at 80% of cap** — Paperclip notifies, no dispatch block
2. **Budget at 100%** — Paperclip blocks new dispatch; in-flight completes
3. **Two consecutive task failures on same role** — pause that agent type, require human review
4. **Production deploy step in a task** — never auto-execute. Agent stops, lists the exact commands the human will run, hands the issue back via `in_review`.
5. **Schema migration in production** — same as deploy: never auto. Agent runs the migration LOCALLY against the dev Postgres and proves it round-trips, then hands off.

## Wave plan reference

`wave-plans/safeplace-2026-04-16.md` — last loaded 2026-05-09 by CEO during SAF-1 hire.

- **Wave 0 (close-outs, before Wave 1):** #98 dup of #105, #4 verify-and-close, #6 close, #5 relabel `research`
- **Wave 1:** #100 admin diagnostics, #101 Skolverket, #102 safety-score snapshots, #103 enrich-locations CLI
- **Wave 2:** #104 Cloud SQL upgrade, #106 health/ready, #30 Prom metrics, #77 query perf, #76 SMHI purge
- **Wave 3:** #98+#105 BRÅ correlation, #12 BRÅ import, #41 Polisen decline, #43 other_crime classifier, #75 per-agent LLM
- **Wave 4:** #107 profile pages, #108 push, #28 a11y, #26 main.go split, #1+#8 safety panel v2

The wave-plan was written for an older roster that included `api-designer`, `web-frontend`, `analytics-agent`, etc. CTO will route work that mentions those roles to the closest live engineer (usually Backend Engineer for templates and route wiring) or escalate to CEO for a hire when a wave genuinely needs a missing role.

## Open follow-ups

- [x] Hire founding engineering team — done 2026-05-09 via SAF-1 (8 agents: CEO + CTO + 6 specialists, all `AGENTS.md` byte-for-byte verbatim)
- [x] Read wave-plan into CEO context — done 2026-05-09 during SAF-1
- [ ] Set monthly budget cap — pending (Olympus precedent: €100/mo via `PATCH /api/companies/<id>` `{budgetMonthlyCents: 10000}`)
- [ ] First implementation wave: dispatch Wave 0 close-outs (#98 dup, #4/#6 verify-and-close) — next CEO task
- [ ] Decide: keep legacy `rios-brain` VM and Cloud NAT (currently flagged for decom in `olympus-platform/docs/COST_INVENTORY.md` § 1.5 + § 1.11) or repurpose
- [ ] Confirm GitHub repo connection to Paperclip workspace (Olympus precedent: `POST /api/projects/<id>/workspaces` with cwd = local checkout, repoUrl = github, ref = main)

## Historical context

- GCP project: `safeplace-io`
- Legacy resources: `rios-brain` VM, Cloud NAT, Cloud Router (still hosted in this GCP project as of 2026-04 per `olympus-platform/docs/COST_INVENTORY.md`)
- Stack since revival: Go API + Go templates + Postgres + ingestion adapters for Polisen, SMHI, Trafikverket, Krisinformation, Skolverket, BRÅ, Kolada, SCB
