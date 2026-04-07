# Dev Agents

Portable, project-agnostic, provider-agnostic role definitions for AI-powered parallel development.

## What This Is

Reusable role definitions that tell AI coding agents their scope, conventions, and boundaries. Works with Claude Code today, designed to support OpenAI, Cursor, Grok, and others as they mature.

## Quick Setup

```bash
git clone git@github.com:Arlencho/dev-agents.git
cd dev-agents
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh claude    # or: openai, cursor, grok (when supported)
```

## Repo Structure

```
dev-agents/
├── roles/                    # Provider-agnostic role definitions (source of truth)
│   ├── go-backend.md
│   ├── web-frontend.md
│   ├── mobile.md
│   ├── db-architect.md
│   ├── api-designer.md
│   ├── devops.md
│   └── test-engineer.md
├── providers/
│   ├── claude/agents/        # Claude Code format (ready)
│   ├── openai/               # OpenAI format (placeholder)
│   ├── cursor/               # Cursor rules format (placeholder)
│   └── grok/                 # Grok format (placeholder)
└── scripts/
    └── bootstrap.sh          # Multi-provider bootstrap
```

- **`roles/`** — The canonical definitions. Edit here.
- **`providers/<name>/`** — Provider-specific format. Generated or adapted from roles.
- **`scripts/bootstrap.sh`** — Links the correct provider format to your system.

## Available Agents

| Agent | Role | Scope |
|-------|------|-------|
| `go-backend` | Go API engineer | Handlers, services, providers, middleware |
| `web-frontend` | Next.js/React engineer | Pages, components, styling, API integration |
| `mobile` | React Native/Expo engineer | Screens, navigation, native features |
| `db-architect` | Database architect | Migrations, SQL queries, sqlc |
| `api-designer` | API contract owner | OpenAPI spec, type generation |
| `devops` | DevOps engineer | Docker, CI/CD, deployment, scripts |
| `test-engineer` | Test engineer | Unit, integration, E2E tests only |

## Usage (Claude Code)

```bash
# Single agent
cd ~/my-project
claude --agent go-backend "implement the /users endpoint"

# Parallel agents (different terminals or machines)
claude --agent go-backend "implement auth service"      # Machine 1
claude --agent web-frontend "build login page"          # Machine 2
claude --agent db-architect "create users migration"    # Machine 3
```

## Multi-Machine Setup

1. Clone this repo on every machine
2. Run `./scripts/bootstrap.sh claude`
3. `git pull` to update agents everywhere

The bootstrap symlinks agents to `~/.claude/agents/` so they're available in every project on that machine.

## Parallel Development Rules

1. Break work into non-conflicting tasks (different files/directories)
2. Assign each task to the right agent role
3. Each agent works on its own git branch
4. Merge sequentially: first done -> merge -> rebase others
5. **No two agents touch the same files**

## Adding Agents

1. Create `roles/<name>.md` with the role definition
2. Copy to `providers/claude/agents/<name>.md` (add Claude frontmatter if needed)
3. Run `./scripts/bootstrap.sh claude` to relink
4. Commit and push — all machines get it on `git pull`

## Adding Providers

1. Create `providers/<name>/` directory
2. Add a format adapter (script or template) that reads from `roles/`
3. Add a case to `scripts/bootstrap.sh`
4. Submit a PR

## Provider Status

| Provider | Status | Format |
|----------|--------|--------|
| Claude Code | Ready | Markdown with YAML frontmatter in `~/.claude/agents/` |
| OpenAI | Placeholder | TBD |
| Cursor | Placeholder | `.cursorrules` files |
| Grok | Placeholder | TBD |
