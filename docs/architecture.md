# Dev Agents Architecture

Living topology for the multi-vendor CLI fleet. If this file disagrees with `config/workers.yaml`, `config/routing.yaml`, or `scripts/dispatch.sh`, **config and scripts win**.

## What runs

| Path | When | Mechanism |
|------|------|-----------|
| **Co-pilot chat** | Human in Claude / Kimi / Grok interactive session | Mode 1: plan, advise, small local work |
| **Fleet dispatch** | Multi-agent waves on owned hardware | `dispatch.sh` → SSH/`run-remote.sh` → `providers/<vendor>/launch.sh` |
| **Paperclip** | Board, budgets, heartbeats | `claude_local` adapter (Claude today); multi-company manifests under `companies/` |
| **flow.sh** | Optional gated single-pipeline | intake → producer → critic → tests → CTO → human merge |

**Non-goals:** API-key fleet, same-seat producer×critic when a cross-vendor pair exists, silent skill auto-promotion.

## Prompt layers (every fleet launch)

```
L1 charter     roles/<role>.md  (or providers/<vendor> copy)
L2 skill packs skills/*/SKILL.md via skill-inject.sh  (before L3)
L3 case file   preamble + handoff ledger slice + task text
```

Missing L2 packs **warn and continue** — never block dispatch.

## Fleet dispatch path

```
plan file (.plan)
    │
    ▼
dispatch.sh  ── parse waves (see docs/plan-file-format.md)
    │
    ├─ resolve provider: workers.yaml provider_preferences
    │                    + routing.yaml provider_failover
    │                    + logs/provider-state/ cooldown (exit 75 rate-cap)
    │
    ▼
run-remote.sh  ── skill-inject.sh → launch on worker
    │
    ▼
providers/<vendor>/launch.sh <role> <task>
    exit 0 ok | 1 fail | 75 rate-capped | 69 unavailable
```

### Live multi-vendor seats (summary)

| Role | Primary vendor | Claude tier if Claude | Critic |
|------|----------------|----------------------|--------|
| `web-frontend` | **kimi** (→ K3) | sonnet (failover) | `frontend-critic` claude **opus** |
| `go-backend` | claude | **sonnet** | `backend-critic` **opus** |
| `db-architect` | claude | **opus** (DB exception) | `database-critic` **opus** |
| `api-designer` | claude | **opus** | `api-critic` **opus** |
| `devops` | claude | **opus** | Security covers review |
| `test-engineer` | claude | **opus** | (test-first; pairs with gates) |
| `plan-critic` | **grok** | n/a | Pass 4 of autoplan |
| CTO / security / critics | claude | **opus** | — |

Full matrix: `docs/org-chart.md` + `config/routing.yaml`.

## Single-machine wave (conceptual)

Orchestrator plans waves → parallel seats on separate branches → merge barriers → critics / security / CTO. Git is the bus. No long-lived daemon required for dispatch.

## Multi-machine

Orchestrator on MacBook; workers via SSH (`workers.yaml`). Same launch contract on every host after `setup-machine.sh`.

## Paperclip coexistence

Paperclip owns issues, assignees, budgets, optional heartbeats. Fleet multi-vendor dispatch is the production path for Kimi/Grok seats. Paperclip adapter remains largely Claude-local — do not assume Kimi/Grok heartbeats without adapter work.

## Related

- Operator cookbook: `docs/operator-guide.md`
- Org / pairing: `docs/org-chart.md`
- Plan grammar: `docs/plan-file-format.md`
- Skills freeze: `docs/proposals/skills-evolution-SYNTHESIS.md`
