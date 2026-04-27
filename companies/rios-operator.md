---
name: rios-operator
status: placeholder  # codebase exists + active, but not yet registered in Paperclip
repo: ../rios-operator
paperclip_company_id: TBD — register in Paperclip UI to activate
paperclip_issue_prefix: RIOS  # suggested
budget_monthly_cents: TBD
---

# Rios Operator — Autonomous Founder Operating System

## Charter

AI-powered idea evaluation, scoring, and portfolio management. Go backend + Telegram bot frontend. Personal operating system that runs Arlen's idea pipeline (INBOX → EVALUATING → EXPERIMENT → BUILD → ASSET) with autonomous scoring and reflection.

Source-of-truth product repo: [`rios-operator/`](../../rios-operator/) — own CLAUDE.md, Go modules, Docker compose stack.

## Active phase

| Item | Value |
|---|---|
| Stack | Go 1.24 backend, Claude LLM, Telegram bot, Postgres + pgvector |
| Services | `brain/` (HTTP API on :8080), `telegram/` (bot) |
| Strategic charter (legacy) | `../RIOS_OPERATOR_Strategic_Project_Charter_v1.md`, `../RIOS_V1_CLOSURE_PLAN.md` |
| Stage | Personal use, not yet productized |

> **Action:** Move the parent-level `RIOS_OPERATOR_*` strategic docs into this manifest's references or into `rios-operator/docs/` so they're versioned alongside the code, not stranded at the workspace root.

## Budget cap

| Line | Cap (EUR/mo) | Source |
|---|---:|---|
| Anthropic API (idea scoring + reflection) | TBD — set conservatively, this is personal infra not customer-facing | — |
| Total | TBD | Set in Paperclip UI |

## Agent roster

Subset of `roles/` for Rios Operator. Smaller surface than Olympus.

| Role | File | Model tier | Used for |
|---|---|---|---|
| `orchestrator` | `roles/orchestrator.md` | opus | Planning |
| `go-backend` | `roles/go-backend.md` | sonnet | `brain/`, `telegram/` |
| `db-architect` | `roles/db-architect.md` | sonnet | `db/migrations/`, `db/query/` (sqlc) |
| `analytics-agent` | `roles/analytics-agent.md` | sonnet | Idea scoring quality, reflection summaries |
| `test-engineer` | `roles/test-engineer.md` | sonnet | `*_test.go` |
| `devops` | `roles/devops.md` | sonnet | `docker-compose.yml`, infra |
| `retro` | `roles/retro.md` | sonnet | Reflection cadence (Rios already does autonomous reflection — retro complements it) |

No web frontend, no mobile — the UI is Telegram.

## KPIs

- **Idea pipeline throughput**: cards moved column / week (autonomous + manual)
- **Scoring accuracy**: % of approved proposals that match Arlen's later judgment
- **Reflection cadence**: weekly strategic reflection runs without manual trigger
- **Agent budget burn**: EUR/mo spent on Claude scoring vs cap

## Escalation rules

1. **Reflection produces a "kill" verdict on an idea Arlen has invested time in** — Paperclip surfaces a confirmation gate, never auto-archives
2. **Budget at 100%** — pause autonomous scoring; Telegram bot still functional for read-only queries
3. **Schema migration in `db/migrations/`** — approval gate (small DB, but holds personal idea data — don't lose)

## Open follow-ups

- [ ] Create company in Paperclip UI, record `paperclip_company_id`
- [ ] Set conservative budget cap (this is personal, not revenue-generating)
- [ ] Decide: should Rios Operator's autonomous scheduler be wrapped in Paperclip tasks, or kept as standalone? (The `every 15s` scheduler in `brain/` is its own loop — wrapping it adds ceremony for no gain. Probably keep standalone, use Paperclip only for *changes* to Rios Operator)
- [ ] Move strategic charters from workspace root into this directory tree
