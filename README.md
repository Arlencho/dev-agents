# Dev Agents

Portable, project-agnostic, provider-agnostic role definitions and tooling for AI-powered parallel development.

## What This Is

A complete toolkit for running multiple AI coding agents in parallel across machines and projects. Defines agent roles, project templates, orchestration scripts, and multi-machine runners. Works with Claude Code today, designed to support OpenAI, Cursor, Grok, and others.

## Quick Setup

### New machine (full setup — installs everything)
```bash
git clone git@github.com:Arlencho/dev-agents.git
cd dev-agents
./scripts/setup-machine.sh
```

This installs Homebrew, Go, Node, Docker, Claude Code, bootstraps all 11 agents, and authenticates GitHub + GCP. Interactive — prompts for logins. Run once per machine, never again.

### Existing machine (agents only)
```bash
git clone git@github.com:Arlencho/dev-agents.git
cd dev-agents
./scripts/bootstrap.sh claude
```

## Repo Structure

```
dev-agents/
├── roles/                    # Provider-agnostic role definitions (source of truth)
│   ├── go-backend.md         # Go API engineer
│   ├── web-frontend.md       # Next.js/React engineer
│   ├── mobile.md             # React Native/Expo engineer
│   ├── db-architect.md       # Database architect
│   ├── api-designer.md       # API contract owner
│   ├── devops.md             # DevOps engineer
│   ├── test-engineer.md      # Test engineer (never modifies prod code)
│   ├── orchestrator.md       # Meta-agent — plans, delegates, tracks
│   ├── tech-scout.md         # AI tooling monitor — competitive intelligence
│   ├── security-reviewer.md  # Security auditor — PR review, vulnerability scanning
│   └── seo-auditor.md        # SEO auditor — meta tags, structured data, Core Web Vitals
├── templates/                # Project CLAUDE.md templates
│   ├── go-nextjs.md # Go + Next.js full-stack template
│   └── python-fastapi.md     # Python FastAPI service template
├── providers/
│   ├── claude/agents/        # Claude Code format (ready)
│   ├── openai/               # OpenAI format (placeholder)
│   ├── cursor/               # Cursor rules format (placeholder)
│   └── grok/                 # Grok format (placeholder)
└── scripts/
    ├── bootstrap.sh          # Install agents on any machine
    ├── run-remote.sh         # Run an agent on a remote machine via SSH
    └── new-project.sh        # Scaffold a new project with agent infrastructure
```

## Available Agents

### Development Agents (write code)

| Agent | Role | Scope |
|-------|------|-------|
| `go-backend` | Go API engineer | Handlers, services, providers, middleware |
| `web-frontend` | Next.js/React engineer | Pages, components, styling, API integration |
| `mobile` | React Native/Expo engineer | Screens, navigation, native features |
| `db-architect` | Database architect | Migrations, SQL queries, sqlc |
| `api-designer` | API contract owner | OpenAPI spec, type generation |
| `devops` | DevOps engineer | Docker, CI/CD, deployment, scripts |
| `test-engineer` | Test engineer | Unit, integration, E2E tests only |

### Meta Agents (coordinate and review)

| Agent | Role | Scope |
|-------|------|-------|
| `orchestrator` | **Default entry point** | Your tech lead colleague — routes tasks, plans work, spots blind spots |
| `tech-scout` | Competitive intelligence | Monitors AI tooling releases, suggests workflow improvements |
| `security-reviewer` | Security auditor | Reviews code for vulnerabilities, compliance, best practices |
| `seo-auditor` | SEO auditor | Audits pages for meta tags, structured data, Core Web Vitals |

## When to Use Which Agent

**Default: Start with the orchestrator.** It's your tech lead colleague — it helps you figure out what to do, who should do it, and what you haven't thought of. Even for simple tasks, it'll confirm the right agent and flag blind spots.

| Situation | Start with | Example |
|-----------|-----------|---------|
| **Not sure where to start** | `orchestrator` | "I need to add payments — what's the plan?" |
| **Not sure which agent** | `orchestrator` | "Is this a backend or devops task?" |
| **Multi-task goal** | `orchestrator` | "Close all P2 issues", "Build the booking feature" |
| **What should I work on?** | `orchestrator` | "What's the highest priority work right now?" |
| **One clear, focused task** | Go directly to the role agent | `claude --agent go-backend "fix auth bug #123"` |
| **Weekly maintenance** | `tech-scout` | "What AI tooling updates should we adopt?" |
| **Before merging a PR** | `security-reviewer` | "Review PR #301 for security issues" |
| **Before a launch** | `seo-auditor` | "Audit all public pages for SEO" |
| **New project** | `new-project.sh` script, then `orchestrator` | "Scaffold and plan the initial sprint" |

**Rule of thumb**: When in doubt, ask the orchestrator. It'll either handle it or point you to the right agent.

## Usage

### Direct Agent (single-scope task)
```bash
cd ~/my-project
claude --agent go-backend "implement the /users endpoint"
```

### Orchestrator (multi-scope goal)
```bash
# Step 1: Orchestrator analyzes and produces a wave plan
claude --agent orchestrator "close all P2 issues on this repo"

# Step 2: Execute the plan — parallel agents per wave
claude --agent go-backend "implement auth service"      # Terminal 1
claude --agent web-frontend "build login page"          # Terminal 2
claude --agent db-architect "create users migration"    # Terminal 3

# Step 3: Merge in the order the orchestrator specified
```

### Without Claude Code (just planning)
```bash
# You can also use the orchestrator pattern manually in any Claude session:
# "Break this into parallel tasks and tell me which agents to use"
```

### Remote Execution (Mac Minis)
```bash
# Run an agent on a remote machine
./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/olympus-platform.git go-backend "fix auth bug #123"
```

### Tech Scout (periodic)
```bash
# Run weekly to stay current
claude --agent tech-scout "scan for AI tooling updates relevant to our workflow"
```

### Security Review
```bash
# Review a specific PR
claude --agent security-reviewer "review PR #301 for security issues"

# Full codebase audit
claude --agent security-reviewer "audit the entire codebase for vulnerabilities"
```

### SEO Audit
```bash
claude --agent seo-auditor "audit all public pages for SEO issues"
```

### New Project
```bash
# Scaffold a new project with AI agent infrastructure
./scripts/new-project.sh go-nextjs my-new-saas
cd my-new-saas
claude --agent go-backend "scaffold the API with health check and auth"
```

## Complete Workflow Guide

Here's how a typical development session looks from start to finish:

### 1. Start with the Orchestrator
```bash
cd ~/my-project
claude --agent orchestrator "I need to add a payment system with Stripe"
```

The orchestrator will:
- Analyze what's needed (API endpoints, database tables, frontend pages)
- Tell you which agents to use
- Produce a wave plan with merge order
- Flag things you haven't considered ("you'll also need webhook handling")

### 2. Execute the Plan
The orchestrator outputs something like:
```
Wave 1 (parallel):
  - db-architect: "create payments migration" → branch feat/payments-db
  - api-designer: "add payment endpoints to api.yaml" → branch feat/payments-spec

Wave 2 (after Wave 1 merges):
  - go-backend: "implement payment service with Stripe" → branch feat/payments-api

Wave 3 (after Wave 2 merges):
  - web-frontend: "build checkout page" → branch feat/payments-ui
  - test-engineer: "add payment flow tests" → branch feat/payments-tests
```

Run Wave 1 agents in parallel:
```bash
claude --agent db-architect "create payments migration with orders table"   # Terminal 1
claude --agent api-designer "add POST /payments and webhook endpoints"      # Terminal 2
```

### 3. Merge and Continue
Merge Wave 1 PRs, then start Wave 2:
```bash
claude --agent go-backend "implement Stripe payment service"
```

### 4. Review Before Merging
```bash
claude --agent security-reviewer "review the payment implementation for security issues"
```

### 5. Post-Launch
```bash
claude --agent seo-auditor "audit the new checkout page for SEO"
claude --agent tech-scout "any new Stripe SDK features we should adopt?"
```

### Multi-Machine Parallel (advanced)
Same workflow but across machines:
```bash
# From your MacBook — dispatch to Mac Minis
./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/repo.git go-backend "implement payment service"
./scripts/run-remote.sh mac-mini-2 git@github.com:Arlencho/repo.git web-frontend "build checkout page"
```

---

## Multi-Machine Setup

1. Clone this repo on every machine (MacBook, Mac Minis, etc.)
2. Run `./scripts/bootstrap.sh claude`
3. `git pull` to update agents everywhere

The bootstrap symlinks agents to `~/.claude/agents/` — available in every project on that machine.

## Project Templates

Templates provide a pre-configured `CLAUDE.md` for common project types:

| Template | Stack | Use case |
|----------|-------|----------|
| `go-nextjs` | Go + Next.js + PostgreSQL | Full-stack SaaS, APIs with web frontend |
| `python-fastapi` | Python + FastAPI + SQLAlchemy | Data services, ML APIs, microservices |

```bash
./scripts/new-project.sh go-nextjs my-project
```

## Parallel Development Rules

1. Break work into non-conflicting tasks (different files/directories)
2. Assign each task to the right agent role
3. Each agent works on its own git branch
4. `api.yaml` changes merge FIRST (everything depends on the contract)
5. Database migrations merge BEFORE code that uses them
6. Tests merge LAST
7. **No two agents touch the same files**

## Adding Agents

1. Create `roles/<name>.md` with the role definition
2. Copy to `providers/claude/agents/<name>.md`
3. Run `./scripts/bootstrap.sh claude` to relink
4. Commit and push — all machines get it on `git pull`

## Adding Providers

1. Create `providers/<name>/` directory
2. Add a format adapter that reads from `roles/`
3. Add a case to `scripts/bootstrap.sh`

## Documentation

| Doc | What it covers |
|-----|---------------|
| [Architecture Diagrams](docs/architecture.md) | Single-machine, multi-machine, agent communication, your specific setup |
| [Scenarios](docs/scenarios.md) | 7 real-world examples: bug fix, feature request, sprint planning, multi-machine, pre-launch audit, new project, "I don't know where to start" |

## Provider Status

| Provider | Status | Format |
|----------|--------|--------|
| Claude Code | Ready | Markdown with YAML frontmatter in `~/.claude/agents/` |
| OpenAI | Placeholder | TBD |
| Cursor | Placeholder | `.cursorrules` files |
| Grok | Placeholder | TBD |
