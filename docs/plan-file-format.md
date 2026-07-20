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

## Hard Rules (Production-Learned)

These rules were discovered through production orchestration. Breaking them causes failures.

### Branch Naming
- **Branch is always the last field** in the pipe-delimited record.
- **Format**: `feat/<slash-slug>` or `fix/<slash-slug>` (kebab-case with forward slashes allowed for grouping).
  - ✅ Good: `feat/payments-db`, `fix/auth-token`, `feat/api/payment-endpoints`
  - ❌ Bad: `feat-payments_db`, `feat/PAYMENTS_DB`, `payments-db` (no scope prefix)

### Task Description — No Unescaped Pipes
- **Never put unescaped pipe characters (`|`) inside the task description.**
- Plan files are pipe-delimited; unescaped pipes break the parser.
- **For verdicts / decisions in descriptions, use space-separated format:**
  - ✅ Good: `review payment service — verdict PASS` or `audit code: REVISE async patterns`
  - ❌ Bad: `review | PASS | approved` or `verdict: PASS | REVISE | BLOCK`
- If you need to include a literal pipe, escape it: `\|` (not parsed by the orchestrator, but documents intent).

### Producer & Critic on Same Branch → Different Waves
- **When a Producer and Critic both work on the same branch, they must be in different waves.**
  - Producer wave N creates/pushes branch `feat/payments-svc`
  - Critic wave N+1 reviews on that same branch
- **Rationale**: Critic needs Producer's commits to exist before reviewing; same-wave parallel execution would cause race conditions.
- Example:
  ```
  2 | go-backend     | implement payment service              | feat/payments-svc
  3 | backend-critic | review payment service implementation | feat/payments-svc
  ```

### Critic Tasks & Existing Branches
- **When a Critic task reviews an existing branch** (not created by this plan), `run-remote` will check out that branch before invoking the agent.
- You do not need to specify branch creation logic in the task description.
- Example:
  ```
  4 | backend-critic | review PR #542 changes to payment flow | main
  ```
  The critic will check out `main`, load the diff, and review.

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
