# Claude Agents

Portable, project-agnostic agent definitions for Claude Code parallel development workflows.

## What This Is

Reusable role definitions that tell Claude Code agents their scope, conventions, and boundaries. Clone this repo on any machine, run the bootstrap, and every Claude Code session gets the same agent capabilities.

## Quick Setup

```bash
git clone git@github.com:Arlencho/claude-agents.git
cd claude-agents
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

This symlinks all agent definitions to `~/.claude/agents/` so they're available globally. Updates via `git pull` apply everywhere.

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

## Usage

```bash
# Use an agent in any project
cd ~/my-go-project
claude --agent go-backend "implement the /users endpoint"

# Run multiple agents in parallel (different terminals)
claude --agent go-backend "implement auth service"    # Terminal 1
claude --agent web-frontend "build login page"        # Terminal 2
claude --agent db-architect "create users migration"  # Terminal 3
```

## Parallel Development Workflow

1. Break work into non-conflicting tasks (different files/directories)
2. Assign each task to the appropriate agent
3. Each agent works on its own branch
4. Merge sequentially: first done -> merge -> rebase others

Key rule: **no two agents touch the same files**.

## Customizing for a Project

These agents are generic. For project-specific rules, add a `CLAUDE.md` in your repo root — it takes precedence over global agent definitions.

## Adding New Agents

1. Create `agents/<name>.md` with frontmatter (name, description, tools)
2. Run `./scripts/bootstrap.sh` to relink
3. Commit and push — all machines get it on next `git pull`

## Future: Other Providers

This repo is for Claude Code agents. If other AI coding tools (OpenAI Codex, Cursor, etc.) need similar role definitions, create sibling repos:
- `claude-agents` (this repo)
- `openai-agents` (future)
- `cursor-agents` (future)
