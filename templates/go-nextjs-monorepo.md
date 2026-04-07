# Project Template: Go + Next.js Monorepo

Drop this into your repo as `CLAUDE.md` and customize the placeholders.

## Architecture

- **Go backend** (`apps/api/`) — Chi router, pgx, sqlc
- **Next.js web** (`apps/web/`) — App Router, TypeScript, Tailwind CSS
- **React Native mobile** (`apps/mobile/`) — Expo (if applicable)
- **PostgreSQL** + **Redis** via Docker Compose
- **OpenAPI spec** (`api.yaml`) → generated TypeScript client (`packages/api-client/`)

## Deployment

| Service | URL | Platform |
|---|---|---|
| Go API | `<API_URL>` | GCP Cloud Run / Fly.io |
| Web | `<WEB_URL>` | Vercel |

## Agent Roles

| Agent | Scope | Invoke |
|---|---|---|
| `go-backend` | `apps/api/` | `claude --agent go-backend "task"` |
| `web-frontend` | `apps/web/` | `claude --agent web-frontend "task"` |
| `mobile` | `apps/mobile/` | `claude --agent mobile "task"` |
| `db-architect` | `apps/api/db/` | `claude --agent db-architect "task"` |
| `test-engineer` | Test files only | `claude --agent test-engineer "task"` |
| `devops` | `infra/`, CI, scripts | `claude --agent devops "task"` |
| `api-designer` | `api.yaml`, `packages/` | `claude --agent api-designer "task"` |

## Conventions

### JSON / API Fields — snake_case
- ALL JSON field names use snake_case
- JavaScript variables stay camelCase
- Never camelCase in JSON tags or API fields

### Go
- Chi router, handlers as `func(w, r)`
- Services as interfaces, DI via struct fields
- Error wrapping: `fmt.Errorf("pkg.Func: %w", err)`
- Logging: `slog` structured, never `log.Println`
- Tests: table-driven, `testify/assert`

### TypeScript
- Strict mode, no `any`
- Server components by default, `"use client"` only when needed
- API calls via generated client only
- Tailwind CSS, no inline styles

### Database
- Migrations in `apps/api/db/migrations/` (goose format)
- Queries in `apps/api/db/queries/` (sqlc)
- UUIDs for PKs, snake_case, timestamps on every table

### API Contract
- `api.yaml` is single source of truth
- After changes: `make generate`
- Response envelope: `{ "data": T, "error"?: string }`

## Parallel Workflow

1. Spawn agents in worktrees or separate terminals
2. Each agent gets its own branch
3. Merge sequentially: api.yaml first, then backend, then frontend
4. Never two agents on the same files
