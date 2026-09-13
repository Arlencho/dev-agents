# Plan File Format

Canonical grammar for wave plans consumed by `scripts/dispatch.sh`.
If `README.md` or `docs/operator-guide.md` disagree with this file, **this file wins** — and both must be updated to match.

## Record shape

Each non-empty, non-comment line is pipe-delimited:

```
WAVE | AGENT | TASK_DESCRIPTION | [BRANCH_NAME]
```

| Field | Required | Meaning |
|-------|----------|---------|
| `WAVE` | Yes (wave format) | Integer wave number. Tasks with the same wave run in parallel; higher waves wait. |
| `AGENT` | Yes | Role id matching a file under `roles/<agent>.md` (e.g. `web-frontend`, `go-backend`). |
| `TASK_DESCRIPTION` | Yes | Free text. **May contain `\|` characters.** |
| `BRANCH_NAME` | No | Git branch. Auto-generated as `fix/<agent>-<timestamp>` if omitted or not detected. |

Legacy (no wave column):

```
AGENT | TASK_DESCRIPTION | [BRANCH_NAME]
```

All such lines become wave `1`.

## Parser rules (matches `scripts/dispatch.sh`)

1. Fields are split on `|`.
2. **Branch detection:** the **last** field is a branch only when it looks like a branch slug: contains `/`, has no spaces, and matches safe slug characters.
3. Everything between agent and branch is **re-joined with `|`** as the description. So pipes inside the task text are **preserved** (e.g. `VERDICT: PASS|REVISE` is fine).
4. Do **not** escape pipes as `\|` — the backslash would be passed to the agent literally.
5. Style tip: for human-readable alternatives in prose, prefer ` / ` over `|` when you do not need a literal pipe.
6. **Producer and critic on the same branch must be different waves** (producer ships, next wave critic reviews).
7. Branch names: kebab-case, e.g. `feat/payments-db`.

## Header lines

Comment lines (`#`) above the records are the plan header. The first prose
comment is the plan's **purpose** (what the queue and the Floor print). Lines
that open with one of these words are **directives**, read by machines and
skipped as purpose:

| Line | Read by | Meaning |
|------|---------|---------|
| `# DISPATCH: ./scripts/dispatch.sh <repo-url> <plan> [flags]` | `scripts/queue-runner.sh` | The command a person would copy. The runner takes the repo URL and the flags from it (adds `--detach --auto`, drops `--review`). A queued plan without this line is marked blocked. |
| `# AFTER: <plan path>` | `scripts/queue-runner.sh` | The plan waits until the named plan has a `dispatch_end` with outcome `landed` (close-out `completed`, every seat's last exit `success`). Until then the runner writes `waiting: after <plan>: ...` into the queue entry (shown by `make queue-list` and the Floor) and clears it itself once the named plan lands. A named plan whose last run failed keeps the waiter waiting and says so. |
| `# FIX-ROUND: 1 of <plan path>` | `scripts/queue-runner.sh` | Written by the runner into the fix plan it generates (`<plan>-fix1.plan`) after a `BLOCK-FIX`. A `BLOCK-FIX` on a plan carrying this line queues nothing: the item becomes a stop. Do not write it by hand. |

Example:

```
# Assistant Channel W2-B: the six read tools and the cost quota. Issue 2800.
# DISPATCH: ./scripts/dispatch.sh git@github.com:you/repo.git wave-plans/w2b.plan --retries 1
# AFTER: wave-plans/w2a.plan
```

The paths in `AFTER` and `FIX-ROUND` are repo-relative, like the queue's. The
runner matches the named plan to runs by **basename** (the event stream records
the basename), so keep plan basenames unique.

## Examples

```
1 | db-architect   | create payments tables migration        | feat/payments-db
1 | api-designer   | add PaymentIntent endpoints to api.yaml | feat/payments-api
2 | go-backend     | implement payment service handlers      | feat/payments-svc
2 | web-frontend   | checkout payment UI                     | feat/payments-ui
3 | test-engineer  | add payment flow integration tests     | feat/payments-tests
3 | backend-critic | review payment handlers                 | feat/payments-svc
```

## Related

- Operator cookbook: [`docs/operator-guide.md`](operator-guide.md)
- Dispatch: `scripts/dispatch.sh`
- Queue runner (reads `DISPATCH`, `AFTER`, writes `FIX-ROUND`): `scripts/queue-runner.sh`, `README.md` § The queue runner
- Live seats: `config/workers.yaml` + `config/routing.yaml` (config wins over any prose table)
