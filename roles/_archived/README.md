# Archived roles

These roles were moved out of the active roster in the **lean-roster** refactor
(2026-06) to match the current team size and the cost-control posture. Nothing
is deleted — every charter is preserved here and can be reactivated in minutes.

## Why these were archived

The active roster had grown to 31 roles with two overlapping concerns:

1. **A redundant second review layer.** Seven "reviewer" roles overlapped with
   the four Critics + Security + CTO gate, which are the validated, sharp review
   system (the Critics caught real payment bugs four other reviewers missed).
2. **Niche meta-roles** a small, pre-revenue team rarely fires.

Their coverage folds into the surviving roles:

| Archived reviewer | Folded into |
|---|---|
| `red-team-reviewer` | `security-reviewer` |
| `plan-reviewer` | `cto` (and `orchestrator`) |
| `perf-reviewer` | the relevant Critic + `devops` |
| `testing-reviewer` | `test-engineer` + the relevant Critic |
| `maintainability-reviewer` | the relevant Critic |
| `migration-reviewer` | `database-critic` |
| `api-reviewer` | `api-critic` |

## Parked until needed (reactivate when the stage justifies it)

- `analytics-agent`, `seo-auditor` — when there's a live growth/marketing surface
- `data-engineer`, `performance-engineer` — when there's real data/perf scale
- `release-manager` — when release cadence needs a dedicated owner
- `tech-scout` — runs fine on demand; doesn't need to be a standing role
- `production-auditor` — reactivate for compliance / SOC2 / pen-test push

Also archived under `providers/claude/agents/_archived/`: five duplicate agent
files whose filename did not match their `name:` field
(`backend-engineer`=go-backend, `frontend-engineer`=web-frontend,
`database-engineer`=db-architect, `qa-engineer`=test-engineer,
`security-engineer`=security-reviewer). The canonical files remain active.

## How to reactivate a role

```bash
git mv roles/_archived/<role>.md roles/<role>.md
git mv providers/claude/agents/_archived/<role>.md providers/claude/agents/<role>.md
# then re-add it to config/routing.yaml (model_routing + label_routes)
# and config/workers.yaml (provider_preferences)
```
