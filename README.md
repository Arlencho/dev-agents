# Dev Agents

Portable, project-agnostic, provider-agnostic orchestration toolkit for AI-powered parallel development.

## What this is

Source of truth for:

1. **Agent role charters** (`roles/*.md`) — 30 provider-agnostic roles spanning engineers, reviewers, critics, ops, and meta-agents.
2. **Heterogeneous producer-critic pattern** — every implementation task pairs a producer agent with an independent critic on a different model. Charter-level invariant.
3. **Multi-product orchestration** (`companies/*.md`) — one manifest per product (Olympus, SafePlace, Aegis, RiosOperator, WearForRun) wiring agents, budgets, and runtime config.
4. **Paperclip integration** — the `claude_local` adapter runs these agents under the Paperclip orchestration platform (`127.0.0.1:3100`) with task routing, board automation, and budget enforcement.

Works with Claude Code today; designed to extend to OpenAI, Cursor, Grok via the `providers/` adapter layer.

## What's new

### Heterogeneous producer-critic adoption (OLY-11 — 2026-04-29)

Every implementation task now runs through a producer + critic pair on different models. Critics report to CTO for independence, but pair with their producer counterpart on every diff.

**Pairing matrix:**

| Producer | Producer model | Critic | Critic model | Discipline |
|---|---|---|---|---|
| Frontend Engineer | sonnet | Frontend Critic | **opus** | Next.js / React / Tailwind / a11y |
| Backend Engineer | sonnet | Backend Critic | **opus** | Go / Chi / pgx / sqlc / OpenAPI |
| Database Engineer | **opus** (Amendment A) | Database Critic | opus | Postgres migrations / sqlc / index strategy |
| API Designer | sonnet | API Critic | **opus** | `api.yaml` / generated TS client / response envelopes |
| DevOps Engineer | sonnet | (none — by design) | — | Security Engineer covers review surface |

**Hard rule (charter-level invariant):** each Critic uses a different model from its paired producer. Same-model pairs lose ~30% of cross-error detection per Reflexion (Shinn 2023) and Constitutional AI (Bai 2022). Do **not** "correct" any Critic to Sonnet to save cost.

**Cross-cutting reviewers** (peers, NOT discipline-paired):
- **QA Engineer** (opus, test-first) — writes failing tests against PRD/contract before producer codes
- **Security Engineer** (opus, red-team) — active attack attempts on every PR before CTO gate
- **CTO** (opus) — final architectural gate (APPROVE-MERGE / BLOCK-FIX / BLOCK-ESCALATE)

Full org chart with reporting + pairing edges: [`docs/olympus-org-chart.md`](docs/olympus-org-chart.md).

### Backend Critic activation evidence (OLY-39, OLY-46, OLY-50)

Across 3 activations on payment / state-machine code, Backend Critic caught CRITICAL bugs that **4 prior reviewers (Bugbot, Security ×3, QA, CTO architectural gate) all approved**:

- `payment.go:425-441` — `Confirmed` overwrites `Failed` after Duffel order failure (state-machine invariant violation)
- Cross-replica race in `RefundOrphan` + `ResolveOrphanManually`
- Double-refund vulnerability via `ResolveOrphanManually` not gating `Status`

All loops converged within the 2-loop ceiling. No CTO escalation. The executable-only critic charter (failing test diff + `file:line` citation, prose rejected) is load-bearing.

### Per-role model tier routing (v2 — April 2026)

`config/routing.yaml → model_routing:` pins each role to `opus`, `sonnet`, or `haiku`. Tier aliases (not version IDs) so config doesn't churn when Anthropic ships a new version. ~51% cost reduction vs uniform Opus.

## Quick setup

### New machine (full setup)
```bash
git clone git@github.com:Arlencho/dev-agents.git
cd dev-agents
./scripts/setup-machine.sh
```
Installs Homebrew, Go, Node, Docker, Claude Code; bootstraps all roles to `~/.claude/agents/`; authenticates GitHub + GCP. Interactive — prompts for logins.

### Existing machine (agents only)
```bash
git clone git@github.com:Arlencho/dev-agents.git
cd dev-agents
./scripts/bootstrap.sh claude
```

### Paperclip orchestration platform
```bash
./scripts/paperclip-up.sh        # start local Paperclip on 127.0.0.1:3100
./scripts/paperclip-status.sh    # health + version + companies + agents
./scripts/paperclip-refresh.sh   # pull latest Paperclip release
./scripts/paperclip-down.sh      # stop
```
Pinned version + release scan log: [`learnings/paperclip-changelog.md`](learnings/paperclip-changelog.md).

## Repo structure

```
dev-agents/
├── roles/                    # 30 role charters (provider-agnostic source of truth)
│   ├── orchestrator.md       # Meta — plans, delegates, tracks (CEO)
│   ├── # Engineers
│   ├── go-backend.md  web-frontend.md  mobile.md
│   ├── db-architect.md  api-designer.md  devops.md
│   ├── # Critics (NEW — heterogeneous, opus-paired)
│   ├── backend-critic.md  frontend-critic.md
│   ├── database-critic.md  api-critic.md
│   ├── # Cross-cutting reviewers
│   ├── test-engineer.md  security-reviewer.md  retro.md
│   ├── # Specialty reviewers
│   ├── perf-reviewer.md  testing-reviewer.md  plan-reviewer.md
│   ├── migration-reviewer.md  maintainability-reviewer.md
│   ├── production-auditor.md  red-team-reviewer.md
│   ├── # Domain
│   ├── data-engineer.md  analytics-agent.md  performance-engineer.md
│   ├── seo-auditor.md  release-manager.md  docs-writer.md
│   ├── tech-scout.md  investigate.md
│   └── api-reviewer.md
├── companies/                # Per-product manifests (one per product)
│   ├── olympus.md            # Olympus AI travel booking — primary, demo 2026-05-15
│   ├── safeplace.md          # SafePlace — Swedish public-data platform
│   ├── aegis.md  rios-operator.md  wearforrun.md
├── wave-plans/               # Per-wave execution plans (one per wave)
├── learnings/                # Retros + Paperclip release-tracker
│   └── paperclip-changelog.md
├── docs/
│   ├── architecture.md
│   ├── olympus-org-chart.md  # Reporting + pairing visualization
│   ├── paperclip-architecture.md
│   ├── issue-lifecycle.md
│   ├── plan-file-format.md
│   └── scenarios.md
├── templates/                # Project CLAUDE.md scaffolds
│   ├── go-nextjs.md  python-fastapi.md
├── providers/
│   ├── claude/agents/        # Claude Code symlinks (ready)
│   ├── openai/  cursor/  grok/   # Placeholders
└── scripts/
    ├── # Local agent harness
    ├── bootstrap.sh  setup-machine.sh  new-project.sh
    ├── dispatch.sh  run-remote.sh  workers-status.sh
    ├── guardrails.sh  preamble.sh  notify.sh
    ├── autoplan.sh  retro-data.sh  learnings.sh  sync-providers.sh
    └── # Paperclip orchestration
    └── paperclip-up.sh  paperclip-down.sh
    └── paperclip-status.sh  paperclip-refresh.sh
```

## How orchestration actually works

Two execution paths — pick based on task scope:

### Path A — Paperclip task (recommended for multi-step or product-scoped work)

```
You file a task in Paperclip UI (or via API)
        │
        ▼
CEO (Orchestrator, opus) receives → decomposes
        │
        ▼
CTO (opus) routes → triages → spawns child sub-tasks
        │
        ▼
QA Engineer (opus, test-first) writes failing tests against PRD
        │
        ▼
Producer (Sonnet, or Opus for DB) implements
        │
        ▼
Critic (Opus, paired) reviews diff — hard 2-loop ceiling, executable output only
        │
        ▼
Security Engineer (opus, red-team) attacks the PR
        │
        ▼
CTO architectural gate — APPROVE-MERGE / BLOCK-FIX / BLOCK-ESCALATE
        │
        ▼
DevOps + CI ship
```

Per-task discipline (worktree isolation, label-flip cadence, no-Co-Authored-By trailer, conventional commits) is enforced by each project's `CLAUDE.md` rules.

### Path B — Direct agent invocation (for one-off, single-scope, ad-hoc work)

```bash
# In any project directory
claude --agent go-backend "fix auth bug #123"
claude --agent web-frontend "build login page"
claude --agent security-reviewer "review PR #301"
```

Use direct invocation when:
- The task is one clear, focused unit of work
- You're iterating live and don't want the full producer-critic loop
- You're outside any product's Paperclip company

## Multi-product orchestration

Each product lives under `companies/` with its own manifest (paperclip company id, budget cap, agent roster, deploy targets). Olympus is primary (May 15 demo); others (SafePlace, Aegis, etc.) are tracked but lower-cadence.

When you ask the Orchestrator a question, the active product context comes from `cwd` matching one of the manifests. Cross-product orchestration is intentionally manual — there is no global queue.

## Available agents (full roster)

### Engineers (write code)

| Agent | Model | Scope |
|---|---|---|
| `go-backend` | sonnet | Handlers, services, providers, middleware |
| `web-frontend` | sonnet | Pages, components, styling, API integration |
| `mobile` | sonnet | Screens, navigation, native features |
| `db-architect` | **opus** (Amendment A) | Migrations, sqlc queries, index strategy |
| `api-designer` | sonnet | OpenAPI spec, type generation, response envelopes |
| `devops` | sonnet | Docker, CI/CD, deployment, scripts |

### Critics (review diffs — opus-paired)

| Agent | Pairs with | Output rule |
|---|---|---|
| `backend-critic` | `go-backend` | Failing test diff + `file:line` citation only |
| `frontend-critic` | `web-frontend` | Same — executable critique, prose rejected |
| `database-critic` | `db-architect` | Migration diff, query plan, index analysis |
| `api-critic` | `api-designer` | Contract violation, response-shape diff |

### Cross-cutting reviewers

| Agent | Model | Cadence |
|---|---|---|
| `test-engineer` | **opus** (test-first) | Once per implementation task, BEFORE producer |
| `security-reviewer` | opus (red-team) | Once per PR, AFTER critic loop |
| `retro` | sonnet | Per-wave, post-merge |

### Specialty reviewers (invoke as needed)

`perf-reviewer`, `testing-reviewer`, `plan-reviewer`, `migration-reviewer`, `maintainability-reviewer`, `production-auditor`, `red-team-reviewer`, `api-reviewer`

### Meta + domain

`orchestrator` (CEO), `tech-scout`, `analytics-agent`, `data-engineer`, `performance-engineer`, `seo-auditor`, `release-manager`, `docs-writer`, `investigate`

## Parallel development rules

1. Break work into non-conflicting tasks (different files/directories)
2. Each agent works on its own git worktree (`scripts/task-worktree.sh`)
3. `api.yaml` changes merge FIRST (everything depends on the contract)
4. Database migrations merge BEFORE code that uses them
5. Tests merge LAST
6. **No two agents touch the same files**
7. **Conventional Commits**, no `Co-Authored-By:` trailer (board directive OLY-4)
8. **No direct push to `main`** — all changes via PR

## Adding a role

1. Create `roles/<name>.md` with YAML frontmatter (`name`, `description`, `model`)
2. If it's a Critic, follow the `executable-output-only` charter pattern from `backend-critic.md`
3. Run `./scripts/sync-providers.sh` to relink to `providers/claude/agents/`
4. Run `./scripts/bootstrap.sh claude` on each machine after `git pull`

## Adding a product (`companies/`)

1. Create `companies/<name>.md` with YAML frontmatter (paperclip ids, repo, budget, demo date)
2. Hire agents in Paperclip via `paperclip-create-agent` skill or `POST /api/companies/<id>/agent-hires`
3. Each agent's `AGENTS.md` bundle is byte-for-byte verbatim from the source role file (sync via `./scripts/sync-providers.sh`)

## Provider status

| Provider | Status | Adapter |
|---|---|---|
| Claude Code (local) | Ready | Markdown + YAML frontmatter in `~/.claude/agents/` |
| Claude Code (Paperclip-orchestrated) | Ready | `claude_local` adapter, runs under Paperclip on `127.0.0.1:3100` |
| OpenAI | Placeholder | TBD |
| Cursor | Placeholder | `.cursorrules` files |
| Grok | Placeholder | TBD |

## Documentation

| Doc | What it covers |
|---|---|
| [`docs/olympus-org-chart.md`](docs/olympus-org-chart.md) | Mermaid + ASCII visualization of reporting + pairing edges (Paperclip's tree UI can't draw peer edges; this is canonical) |
| [`docs/paperclip-architecture.md`](docs/paperclip-architecture.md) | Paperclip platform architecture — companies, agents, issues, runs, adapters |
| [`docs/architecture.md`](docs/architecture.md) | Single-machine, multi-machine, agent communication topology |
| [`docs/issue-lifecycle.md`](docs/issue-lifecycle.md) | Paperclip issue states (backlog → todo → in_progress → in_review → done) + label-flip discipline |
| [`docs/plan-file-format.md`](docs/plan-file-format.md) | Wave-plan markdown format |
| [`docs/scenarios.md`](docs/scenarios.md) | Real-world examples — bug fix, feature request, sprint planning, multi-machine, pre-launch audit |
| [`learnings/paperclip-changelog.md`](learnings/paperclip-changelog.md) | Weekly Paperclip release scan log (OLY-5 routine) |

## Real-world results

- **Backend Critic activations (OLY-39, OLY-46, OLY-50)** — caught 3 CRITICAL/HIGH bugs in payment + state-machine code that Bugbot, Security (3 rounds), QA, and CTO architectural gate all approved. Validation evidence for the heterogeneity invariant and executable-only critic charter.
- **Analytics-agent audit (SafePlace)** — first pass scored a production data platform 34/100 on data quality across 256K events / 6 Swedish government APIs; identified 10 specific gaps (municipality misattribution at 57%, polluted reference data, missing confidence indicators). After 3 waves of parallel orchestrator-led fixes, re-score was 83.5/100.

The point isn't the score — it's that the agents catch problems human review misses, and the producer-critic pattern catches what single-reviewer pipelines miss.
