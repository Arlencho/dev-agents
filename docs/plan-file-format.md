# Plan File Format

Plan files define what agents work on, in what order, and on which branches. The orchestrator produces these; `dispatch.sh` consumes them.

## Format

Each line is a pipe-delimited record:

```
WAVE | AGENT | TASK_DESCRIPTION | BRANCH_NAME
```

| Field | Required | Description |
|-------|----------|-------------|
| `WAVE` | Yes | Integer wave number. Tasks in the same wave run in parallel. Higher waves wait for lower waves to finish. |
| `AGENT` | Yes | Agent role name (must match a file in `roles/`, e.g. `go-backend`) |
| `TASK_DESCRIPTION` | Yes | Plain-text description of what the agent should do |
| `BRANCH_NAME` | Yes | Git branch name the agent will create and push to |

## Rules

- **Wave ordering**: Wave 1 runs first, then wave 2, etc. Tasks within a wave run in parallel.
- **No file conflicts**: Two tasks in the same wave must NOT touch the same files.
- **Dependencies**: If task B depends on task A, put them in different waves (A in a lower wave).
- **Branch names**: Use descriptive names like `feat/payments-db` or `fix/auth-token`.
- Comments start with `#` and are ignored.
- Blank lines are ignored.

## Legacy Format

For simple (non-wave) plans, the wave number can be omitted. All tasks are treated as wave 1:

```
AGENT | TASK_DESCRIPTION | BRANCH_NAME
```

## Example

```
# Payments feature — 3 waves
# Wave 1: schema + API spec (no conflicts, safe to parallelize)
1 | db-architect   | create payments tables migration        | feat/payments-db
1 | api-designer   | add payment endpoints to OpenAPI spec   | feat/payments-spec
1 | devops         | add Stripe webhook route to CI          | feat/payments-ci

# Wave 2: implementation (depends on schema + spec from wave 1)
2 | go-backend     | implement payment service and handlers  | feat/payments-svc
2 | web-frontend   | build checkout page with Stripe Elements| feat/payments-ui

# Wave 3: quality (depends on implementation from wave 2)
3 | test-engineer  | add payment flow integration tests      | feat/payments-tests
3 | security-reviewer | audit payment code for vulnerabilities | feat/payments-audit
```

## Where Plan Files Live

- **Active plans**: `wave-plans/<repo>-<date>.plan` (auto-saved by dispatch.sh)
- **Execution logs**: `wave-plans/<repo>-<date>.log` (results after dispatch completes)
- **Temporary plans**: `/tmp/wave*.txt` (for one-off dispatches)
