# Operator Guide — Dev Agents Fleet

> **Phase 1 — provisional.** The multi-vendor dispatch path, plan format, and failure modes below are production-proven. The **handoff ledger / A/B experiment** sections describe Phase 1 machinery that exists in-tree; treat shared-brain Phases 2–5 as **parked** after the A/B kill criterion unless you re-run a harder experiment. Do not assume full “project brain” productization yet.


This guide covers running the dev-agents fleet from dispatch to handoff — when to use a single CLI, how to author plans, and how to troubleshoot production runs.

**Audience**: Operations engineers and orchestrators running multi-agent waves. Assumes bash, git, and basic SSH familiarity.

## Quick Start: Single Task vs. Dispatch

### Path A: Single Agent Task (Ad Hoc)

Use when:
- You're testing a single agent or role
- You're iterating live and don't want the multi-machine overhead
- You're outside any scheduled wave

```bash
# On your local machine
cd /path/to/target-repo
claude --agent go-backend "fix auth bug #123"
```

**No plan file, no workers, no wave state—just direct invocation.**

### Path B: Multi-Agent Wave (Fleet Orchestration)

Use when:
- You have 3+ parallel tasks
- Tasks need sequencing (some depend on others)
- You're running on Mac Minis or remote workers
- You want a ledger of what each agent did

```bash
# From dev-agents repo
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/sprint-123.plan --auto
```

**Dispatch reads your plan, routes tasks to workers, collects logs, and records a handoff ledger.**

---

## Writing a Plan File

### Format

Canonical grammar: **[`docs/plan-file-format.md`](plan-file-format.md)** (must match `scripts/dispatch.sh`).

```
WAVE | AGENT | TASK_DESCRIPTION | [BRANCH_NAME]
```

- **WAVE** (integer): Same wave parallel; higher waves wait.
- **AGENT**: Role id under `roles/` (e.g. `go-backend`, `web-frontend`).
- **TASK_DESCRIPTION**: Free text. **Pipes `|` inside the description are preserved** (middle fields re-joined). Do **not** escape as `\|`.
- **BRANCH_NAME** (optional): Last field only if it looks like a branch (`contains /`, no spaces). Else auto `fix/<agent>-<timestamp>`.

### Rules

1. **No file conflicts within a wave.**
2. **Dependencies require separate waves.**
3. **Comments and blank lines ignored** (`#` prefix).
4. **Producer + critic on the same branch → different waves.**

### Example Plan

```
# Black Aces SEO metadata sprint — 3 waves
# Wave 1: Schema changes (db + api spec, parallel, no conflicts)
1 | db-architect    | Add seo_tags table with category/priority columns    | feat/seo-db
1 | api-designer    | Add GET /seo-tags/:page_slug endpoint to OpenAPI    | feat/seo-api

# Wave 2: Implementation (depends on schema + spec from wave 1)
2 | web-frontend    | Render og:image meta tag from seo_tags on product pages | feat/seo-og-image
2 | go-backend      | Implement /seo-tags endpoint handler                   | feat/seo-handler

# Wave 3: Review (depends on implementation)
3 | frontend-critic | Review og:image rendering; VERDICT: PASS / REVISE      | feat/seo-critic-frontend
3 | backend-critic  | Review endpoint handler; VERDICT: PASS / REVISE       | feat/seo-critic-backend
```

Save as `wave-plans/repo-YYYYMMDD.plan` or any meaningful name.

---

## Optional: Autoplan Review

Before dispatching, you can run `autoplan.sh` to review your plan with the CTO agent:

```bash
./scripts/autoplan.sh wave-plans/sprint-123.plan
```

**Passes:**
1. **Strategy** — Does the plan address the right problem?
2. **Design** — Are wave dependencies and assignments correct?
3. **Engineering** — Are tasks scoped for single agents? Any missing infrastructure?
4. **Cross-vendor (Grok plan-critic)** — Decorrelated review via `providers/grok/plan-critic.sh`. **Skipped** if `grok` is missing; **warn-and-continue** on error. Never blocks dispatch on third-party outage. See `providers/grok/README.md`.

Passes 1–3 run sequentially with accumulated feedback. Pass 4 is best-effort. Verdicts use `VERDICT: APPROVE | REVISE | REJECT`.

**Optional.** You can skip and dispatch directly. Use when your plan is complex or multi-day.

---

## Session modes (Conductor / Wave / Auto)

**Phase 0 co-pilot contracts** — behavior only; no new daemon. Full text: [`session-modes.md`](session-modes.md). Freeze: [`proposals/session-modes-SYNTHESIS.md`](proposals/session-modes-SYNTHESIS.md).

| Mode | When | Human gate |
|------|------|------------|
| **Conductor** | One surface, one primary role | Packet + one-line plan under `wave-plans/conductor/` → human **go** → `dispatch.sh`. Chat **does not** implement in-scope product code. |
| **Wave** | Multi-role / multi-PR / milestone | Plan file → *planning* then *armed* → human **trigger**. |
| **Auto** | Default when skill is loaded | Decision table selects Conductor / Wave / stay-in-chat; announce; lock per pin. **Not** `dispatch.sh --auto`. |

Escape hatches (one turn): `fix here`, `don't dispatch`, `switch to …`.

**Skill inject:** `session-modes` is mapped on `orchestrator` in `config/role-skills.yaml`. Packet template: [`templates/task-packet.md`](../templates/task-packet.md).

Example Conductor plan line:

```
1 | web-frontend | Fix missing space after bold legal entity (ABarranges class) | feat/fix-abarranges-space
```

```bash
./scripts/dispatch.sh git@github.com:<org>/<repo>.git wave-plans/conductor/<name>.plan
```

---

## Ground Truth (fleet measurement)

Shipped so localhost and remote fleets leave **auditable evidence**:

1. **Logs** — agent transcripts under `~/dev/agent-logs/` on the worker; after a wave, `dispatch.sh` copies them into repo `logs/` for **localhost and remote** workers.
2. **Provenance** — handoff JSONL includes `provenance.vendor`, `provenance.requested_model` (routing pin), and `provenance.effective_model` / `provenance.model` (what the launcher actually uses). Kimi/Grok ignore Claude tier aliases → `vendor-default-k3` / `vendor-default`.
3. **Autoplan fail-closed** — CLI failure or missing `VERDICT` is **REJECT**, not silent APPROVE. REVISE also aborts by default. Re-run after fixes:
   ```bash
   ./scripts/autoplan.sh path/to/plan.plan
   ```
   Opt-in only: `./scripts/autoplan.sh path/to/plan.plan --allow-revise` (still interactive; never auto-dispatch).
4. **Tests** — `make test` (launchers, failover, routing, autoplan fail-closed). CI: `.github/workflows/test.yml`.

Raw logs stay under `logs/` (gitignored). Promote **sanitized** lessons into `learnings/` as usual.

---

## Evidence Scorecard

After Ground Truth, aggregate fleet quality from existing handoffs (read-only):

```bash
make evidence
# or: ./scripts/wave-report.sh
# filter: ./scripts/wave-report.sh --wave 11
# stdout only: ./scripts/wave-report.sh --no-write
```

**Reads:** `wave-plans/*/handoffs/*.jsonl` + `*.md` (do-not-repeat), `wave-plans/ab-metrics.csv`, optional provider-state.

**Writes (local):** `logs/evidence.csv`, `logs/evidence-latest.txt` (gitignored).

Use for: Kimi frontend seat keep/revert (n + success), quality-first routing sanity, skills rework hints. Raw agent transcripts stay out of git.

Related: `make scorecard` (rate-cap / cooldown only).

---

## Dispatching a Wave

### Basic Invocation

```bash
./scripts/dispatch.sh <repo-url> <plan-file> [flags]
```

**Arguments:**
- `<repo-url>` — SSH clone URL (e.g., `git@github.com:Org/repo.git`)
- `<plan-file>` — Path to plan file (e.g., `wave-plans/sprint.plan`)

**Flags:**
- `--auto` — Auto-continue between waves (no prompt waiting for PR merges)
- `--retries N` — Max retries per failed task (default: 2)
- `--review` — Run `autoplan.sh` before dispatching
- `--retry-on-different-worker` — On failure, retry on a different worker (useful if a worker has issues)

### Example Dispatches

#### Interactive dispatch (prompts between waves)

```bash
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/sprint-123.plan
```

Dispatch will:
1. Read workers from `config/workers.yaml`
2. Parse the plan
3. Show wave 1 tasks and prompt "Continue to wave 2? [y/N]" after wave 1 completes
4. Allow you time to review PRs and merge before proceeding

#### Unattended dispatch (auto-continue)

```bash
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/sprint-123.plan --auto
```

Dispatch runs all waves without pausing — useful in CI or overnight runs.

#### With autoplan review

```bash
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/sprint-123.plan --review --auto
```

Autoplan runs first. If it returns `VERDICT: APPROVE`, dispatch proceeds. If `REVISE` or `REJECT`, dispatch halts.

#### With increased retry budget

```bash
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/sprint-123.plan --retries 3
```

Failed tasks retry up to 3 times (default 2) with exponential backoff (10s, 30s, then 30s).

---

## Watching Logs

### Live Agent Log

On the **worker machine** (the Mac Mini where the agent is running):

```bash
# Watch logs as they appear
tail -f $HOME/dev/agent-logs/black-aces-feat-auth-*.log
```

The log file name follows the pattern:
```
{repo}-{branch-slug}-{YYYYMMDD-HHMMSS}.log
```

### Dispatcher-Collected Logs

After dispatch completes, logs are collected from workers to:

```
logs/{repo}-{branch-slug}-{timestamp}.log
```

Check the final report:

```bash
# Summary of all tasks in the wave
cat wave-plans/repo-YYYYMMDD.log
```

### Common Log Patterns

**Healthy agent:**
```
✓ go-backend completed in 127s
```

**Rate-capped (failover triggered):**
```
⏳ web-frontend — kimi rate-capped after 45s (failing over)
```

**Retry and succeed:**
```
✓ backend-critic succeeded on retry 1 via claude in 89s
```

**Blocked (guardrails):**
```
■ security-reviewer BLOCKED by guardrails after 67s (not retryable)
```

---

## Handoff Ledger (Phase 1)

After each task completes, orchestrator-authored mechanical fields are recorded in the **handoff ledger** — a git-backed JSONL + Markdown structure living at:

```
wave-plans/<WAVE>/handoffs/
```

### Ledger Files

For a task like `5-web-frontend-feat-ab-T03-twitter-title`, two files are created:

#### `.jsonl` — Mechanical Record

**File:** `wave-plans/5/handoffs/5-web-frontend-feat-ab-T03-twitter-title.jsonl`

```json
{"task_id":"5-web-frontend-feat-ab-T03-twitter-title","wave":5,"agent":"web-frontend","provenance":{"vendor":"kimi","model":"sonnet","host":"localhost"},"branch":"feat/ab-T03-twitter-title","base_sha":"e44ec21","head_sha":"672544a","ts":"2026-07-20T13:28:43Z","status":"done","orchestrator_fields":{"files_touched":["index.html"],"diff_stat":" 1 file changed, 1 insertion(+)","agent_exit":0,"log":"$HOME/dev/agent-logs/black-aces-feat-ab-T03-twitter-title-20260720-152728.log"}}
```

**Fields:**
- `task_id` — Unique identifier combining wave, agent, branch.
- `wave` — Wave number.
- `agent` — Agent role.
- `provenance.vendor` — Provider (claude/kimi/grok).
- `provenance.model` — Model tier (sonnet/opus/haiku).
- `base_sha`, `head_sha` — Git commit SHAs (short form).
- `status` — "done" or "failed".
- `orchestrator_fields.files_touched` — Array of modified files.
- `orchestrator_fields.agent_exit` — Exit code (0 = success, non-zero = failure).
- `log` — Path to agent's full log.

**APPEND-ONLY format:** Multiple attempts (retries, failovers) accumulate as separate JSONL lines. The first line records the initial vendor; subsequent lines record failover events. This preserves complete provenance — no truncation.

#### `.md` — Agent Intent

**File:** `wave-plans/5/handoffs/5-web-frontend-feat-ab-T03-twitter-title.md`

Agent-authored summary of what was done:

```markdown
# Handoff — twitter:title meta

## Built
- Added exactly one Twitter title meta tag in `index.html` `<head>`:
  - `<meta name="twitter:title" content="Black Aces - Luck, engineered.">`

## Decisions (+why)
- Inserted the meta tag rather than replacing existing head content.
- Used double-quoted attributes to match existing style.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional `twitter:title` meta tags.
- Do not add `twitter:image` without explicit task change.

## Evidence
$ git diff origin/main...HEAD
...
```

This is written by the agent into `handoff.md` at the repo root, then copied here by `run-remote.sh`. It's a soft requirement — if the agent doesn't write one, the task still counts as done, but a warning is logged.

### Reading the Ledger

**View all tasks in wave 5:**

```bash
ls -lh wave-plans/5/handoffs/
```

**Check which vendor ran a task:**

```bash
jq -r '.provenance.vendor' wave-plans/5/handoffs/5-web-frontend-feat-ab-T03-twitter-title.jsonl
# Output: kimi
```

**Find all rate-capped tasks (failover events):**

```bash
grep -l '"event":"failover"' wave-plans/*/handoffs/*.jsonl
```

**Extract agent intent for review:**

```bash
cat wave-plans/5/handoffs/5-web-frontend-feat-ab-T03-twitter-title.md
```

---

## A/B Experiment Control (Phase 1)

The A/B handoff experiment (2026-07) tests whether hidden handoff context (critic-blind arm) improves cross-error detection. Tasks are marked with the `[blind]` marker to exclude them from the handoff preamble.

### Blind Marker Usage

In a plan, prefix a task with `[blind]` to exclude its handoff context:

```
2 | frontend-critic | [blind] Review og-locale meta; VERDICT: PASS / REVISE | feat/ab-T04-og-locale
```

The marker is **stripped before reaching the agent** (see `run-remote.sh`). The agent never sees `[blind]`.

The handoff ledger still records the task — no hiding from orchestrator logs — but the preamble doesn't include prior context.

### A/B Metrics

Results are tracked in:

```
wave-plans/ab-metrics.csv
```

Format:
```
wave,task_id,agent,arm,files_touched,exit_code,verdict
5,5-web-frontend-feat-ab-T03-twitter-title,web-frontend,control,1,0,pass
5,5-frontend-critic-feat-ab-T03-twitter-title,frontend-critic,control,1,0,pass
6,6-frontend-critic-feat-ab-T04-og-locale,frontend-critic,blind,1,0,revise
```

**Phases 2-5 (Shared Brain)** are parked pending A/B results. Current Phase 1 focuses on critic control + failover transparency.

---

## L2 Skill Packs (Phase 0 live)

Fleet agents receive **versioned playbooks** in addition to charters and the case-file preamble.

| Layer | What | Where |
|-------|------|--------|
| L1 Charter | Role identity + hard laws | `roles/<role>.md` |
| L2 Skills | Shared playbooks | `skills/<id>/SKILL.md` + `config/role-skills.yaml` |
| L3 Case | This task’s context | `scripts/preamble.sh` (learnings, git, handoffs) |

**Inject path:** `run-remote.sh` calls `scripts/skill-inject.sh` and places L2 **before** L3. Log line: `Injected L2 skill packs into prompt`. Skills are **not** folded into `preamble.sh`.

**Project override:** same pack id under `<product-repo>/skills/<id>/SKILL.md` **replaces** the global pack body.

**Delivery face:** no AI branding on commits/PRs (`skills/git-ship` + `guardrails.sh` commit-msg hook). Provenance stays in handoffs/logs.

**Promote skills:** open a PR (not silent edit on product branches). Global = human merge. Project = critic or human. Full design: [`docs/proposals/skills-evolution-SYNTHESIS.md`](proposals/skills-evolution-SYNTHESIS.md). Lint: `./scripts/skills-lint.sh`.

**Not shipped yet (SYNTHESIS phases 1–3):** auto candidate scanner, retro-drafted skill PRs, scorecard metrics. Phase 0 = inject + starter packs only.

---

## Common Failures & Troubleshooting

### 1. HTTPS Clone Auth Fails

**Error:**
```
fatal: could not read Username for 'https://github.com':
```

**Cause:** Task tried to clone over HTTPS but worker has no GitHub token.

**Fix:**
```bash
# On the worker, ensure SSH key is configured
ssh-keygen -t ed25519 -C "worker@black-aces"
ssh-copy-id -i ~/.ssh/id_ed25519.pub $(whoami)@$(hostname)

# Then use SSH URLs in plans, not HTTPS
git@github.com:Org/repo.git  # ✓ correct
https://github.com/Org/repo.git  # ✗ avoid
```

**Prevention:** Always use `git@` URLs in dispatch arguments.

### 2. Branch Already Exists

**Error:**
```
fatal: A branch named 'feat/auth-service' already exists.
```

**Cause:** The branch exists locally on the worker from a prior task or incomplete cleanup.

**Fix:** `run-remote.sh` has built-in recovery:

```bash
# run-remote.sh already does this:
git fetch origin
if git checkout "$BRANCH" 2>/dev/null; then
    git pull origin "$BRANCH" 2>/dev/null || true
elif git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
else
    git checkout -b "$BRANCH"
fi
```

The logic:
1. Try to checkout the existing local branch.
2. If it exists remotely, create a local tracking branch.
3. Otherwise, create a fresh branch.

**If still stuck:**
```bash
# Manual cleanup on worker
git branch -D feat/auth-service
git fetch --prune origin
```

Then retry dispatch.

### 3. Plan Pipe Delimiter Confusion

**Error:**
```
ERROR: Plan line unparseable:
1 | go-backend | implement auth with VERDICT: PASS|REVISE | feat/auth
```

**Cause:** The task description contains `|` (pipes). Dispatcher gets confused about field boundaries.

**Fix:** Dispatch correctly detects branch names by looking for `/` characters:

```
1 | frontend-critic | Review auth; VERDICT: PASS|REVISE | feat/auth
                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^
                                (description)            (branch)
```

The dispatcher sees `feat/auth` ends with `/` + alphanumeric, so it's recognized as a branch. Pipes in the description are fine.

**If unsure, quote the branch:**

```
1 | frontend-critic | "Review auth; VERDICT: PASS|REVISE" | feat/auth
```

### 4. GitHub CLI Auth Fails (gh 401)

**Error:**
```
gh: FAILED - POST https://api.github.com/repos/Org/repo/issues - 401
```

**Cause:** The worker's `gh` CLI is not authenticated.

**Fix:**
```bash
# On the worker
gh auth login

# Follow prompts to authenticate with GitHub
# Choose SSH (not HTTPS)
```

**Prevention:** Test before dispatching:
```bash
gh pr list -R Org/repo
# Should show PRs without authentication errors
```

### 5. Provider CLI Not Logged In (Exit 69)

**Error:**
```
⏳ web-frontend — kimi unavailable on mac-mini-2 after 45s (failing over)
```

**Cause:** The Kimi CLI isn't installed or the worker isn't logged in.

**Exit code 69** signals "unavailable" — dispatch will failover to the next provider in `routing.yaml`.

**Fix:**
```bash
# On the worker, verify the CLI is installed
which kimi
kimi --version

# Log in if needed
kimi login

# Or check if it's installed in a non-standard location
find ~ -name kimi -o -name grok -o -name claude 2>/dev/null
```

**Prevention:** Include provider CLI setup in `config/workers.yaml` checklist and verify with `workers-status.sh`.

### 6. Rate-Cap (Exit 75)

**Error:**
```
⏳ web-frontend — kimi rate-capped after 45s (failing over)
```

**Cause:** The vendor (Kimi, Grok, Claude) hit a rate limit.

**Response:** Dispatch automatically fails over to the next provider in the chain:

```yaml
# config/routing.yaml
provider_failover:
  web-frontend: [kimi, claude]  # try kimi first, then claude
```

A cooldown window is set (default 60 minutes); vendor is skipped for new tasks until cooldown expires.

**Fix:**
```bash
# Check cooldown status
cat logs/provider-state/kimi.cooldown 2>/dev/null || echo "not cooling"

# Manually clear cooldown if needed (dangerous — use only after checking rate limit with vendor)
rm logs/provider-state/kimi.cooldown
```

**Prevention:** Monitor `logs/provider-state/ratecap.log` and adjust batch sizes or retry delays if rate-caps are frequent.

### 7. Guardrails Block (Exit 77)

**Error:**
```
■ security-reviewer BLOCKED by guardrails after 67s (not retryable)
```

**Cause:** The agent violated a guardrail (e.g., tried to commit without proper message format or touch a forbidden file).

**Fix:** Not retryable. Review the agent's work manually and re-dispatch with a corrected task description.

**Common guardrail violations:**
- AI branding on commits/PRs (`Co-Authored-By:` Claude/Kimi/…, "Made with …", "Generated with …") — **forbidden**; strip and recommit (fix: fleet law in `skills/git-ship`)
- Committing to `main` directly (fix: task must use a branch)
- Modifying `.env` or secrets (fix: task must work on public code only)

See `config/guardrails.yaml` for the full ruleset.

---

## Cookbook — Copy-Paste Examples

### Example 1: Simple Feature Plan

**File:** `wave-plans/auth-refactor-20260720.plan`

```
# Auth refactor — 2 waves

# Wave 1: Contract + schema
1 | api-designer   | Add /auth/refresh endpoint to OpenAPI spec | feat/auth-spec
1 | db-architect   | Create refresh_tokens table with TTL index | feat/auth-db

# Wave 2: Implementation + review
2 | go-backend     | Implement refresh token logic in handlers   | feat/auth-refresh
2 | backend-critic | Review refresh endpoint; VERDICT: PASS / REVISE | feat/auth-review
```

**Dispatch:**
```bash
./scripts/dispatch.sh git@github.com:Org/repo.git wave-plans/auth-refactor-20260720.plan --auto
```

### Example 2: Multi-Vendor A/B Plan

**File:** `wave-plans/seo-ab-20260720.plan`

```
# Black Aces SEO — A/B critic control

# Wave 1: Implementation
1 | web-frontend  | Add canonical link to product pages | feat/canonical

# Wave 2: Control arm (sees prior context)
2 | frontend-critic | Review canonical link; VERDICT: PASS / REVISE | feat/canonical-review-ctrl

# Wave 3: Blind arm (no prior context)
3 | frontend-critic | [blind] Review canonical link; VERDICT: PASS / REVISE | feat/canonical-review-blind
```

**Dispatch:**
```bash
./scripts/dispatch.sh git@github.com:Arlencho/black-aces.git \
  wave-plans/seo-ab-20260720.plan --auto
```

**Check A/B results after both waves finish:**
```bash
grep canonical wave-plans/ab-metrics.csv
```

### Example 3: With Autoplan Review + Higher Retry Budget

**File:** `wave-plans/complex-refactor-20260715.plan`

```
# Complex schema + code refactor — 4 waves
1 | db-architect | Backfill user_roles table; add migration | feat/roles-backfill
1 | api-designer | Add role-based access control to spec   | feat/rbac-spec

2 | go-backend   | Implement RBAC middleware              | feat/rbac-mw
2 | web-frontend | Add role selector to admin UI           | feat/roles-ui

3 | test-engineer    | Add RBAC integration tests         | feat/rbac-tests
3 | backend-critic   | Review RBAC handler; VERDICT: PASS | feat/rbac-review

4 | security-reviewer | Red-team RBAC; VERDICT: PASS     | feat/rbac-security
```

**Dispatch with plan review + higher retries:**
```bash
./scripts/dispatch.sh git@github.com:Org/repo.git \
  wave-plans/complex-refactor-20260715.plan \
  --review --retries 3 --auto
```

### Example 4: Interactive Dispatch (Manual Wave Gates)

**File:** `wave-plans/production-hotfix-20260720.plan`

```
1 | go-backend  | Fix payment cancellation race condition | fix/payment-race
1 | test-engineer | Add regression test for payment flow | test/payment-race

2 | backend-critic | Review payment fix; VERDICT: PASS | fix/payment-race-review

3 | security-reviewer | Audit payment fix; VERDICT: PASS | sec/payment-race
```

**Dispatch WITHOUT `--auto` to review PRs between waves:**
```bash
./scripts/dispatch.sh git@github.com:Org/repo.git \
  wave-plans/production-hotfix-20260720.plan

# Dispatcher will pause after wave 1 and prompt:
# "Continue to wave 2? [y/N]"
# 
# Review the PR:
# $ gh pr list -R Org/repo
# $ gh pr review <number> -a -c "looks good"
# 
# Then press Enter to proceed
```

### Example 5: Retry on Different Worker

**If one worker is flaky:**

```bash
./scripts/dispatch.sh git@github.com:Org/repo.git \
  wave-plans/sprint-20260720.plan \
  --retry-on-different-worker --retries 3
```

Failed tasks retry on a different worker (useful if a Mac Mini needs maintenance or has network issues).

---

## Monitoring & Observability

### Worker Status

```bash
./scripts/workers-status.sh
```

Output:
```
mac-mini-1 (192.168.1.100) — online [4 agents active]
mac-mini-2 (192.168.1.101) — online [2 agents active]
  ├─ web-frontend (feat/auth-service)
  └─ go-backend (feat/payment-processor)
```

### Scorecard

```bash
make scorecard
```

Shows per-provider task outcomes, rate-cap events, and cooldown status.

### Recent Wave Plans

```bash
ls -lt wave-plans/*.plan | head -5
cat wave-plans/repo-YYYYMMDD.log  # execution log
```

### Ledger Health Check

Verify no dangling branches or incomplete handoffs:

```bash
cd wave-plans
for wave in */; do
  echo "Wave $wave:"
  ls "$wave/handoffs/" 2>/dev/null | wc -l
done
```

---

## Advanced: Manual Dispatch (Run-Remote Directly)

If you need to test a single agent on a worker without the full dispatch machinery:

```bash
./scripts/run-remote.sh mac-mini-1 \
  git@github.com:Org/repo.git \
  go-backend \
  "fix payment race condition in refund handler" \
  feat/payment-race
```

This is equivalent to:
- SSH to `mac-mini-1`
- Clone/fetch the repo
- Create and checkout `feat/payment-race`
- Run `claude --agent go-backend` with your task
- Push the branch
- Record a handoff ledger entry
- Return exit code (0 = success, non-zero = failure)

**Use case:** Debugging a specific agent on a specific worker without dispatching an entire wave.

---

## File Locations Reference

| Component | Location | Purpose |
|-----------|----------|---------|
| **Plans** | `wave-plans/<name>.plan` | Author here; dispatch reads from here |
| **Execution log** | `wave-plans/<repo>-<date>.log` | Dispatch saves results here |
| **Handoff ledger** | `wave-plans/<wave>/handoffs/<task-id>.{jsonl,md}` | Mechanical record + agent intent |
| **Worker config** | `config/workers.yaml` | SSH hosts, capacities, provider_preferences |
| **Routing config** | `config/routing.yaml` | model_routing, provider_failover, rate-cap windows |
| **Role → skills map** | `config/role-skills.yaml` | Which L2 packs each role loads |
| **Skill packs** | `skills/<id>/SKILL.md` | Global L2 playbooks |
| **Guardrails** | `config/guardrails.yaml` + hooks from `guardrails.sh` | Blocked commands; commit-msg bans AI branding |
| **Agent logs** | `logs/` (dispatcher) or `~/dev/agent-logs/` (worker) | Full agent output |
| **Provider state** | `logs/provider-state/` | Rate-cap cooldowns, failover events |
| **Learnings** | `learnings/` | Auto-recorded failure patterns |

---

## Troubleshooting Checklist

- [ ] SSH keys configured on all workers (`ssh-copy-id`)
- [ ] GitHub CLI authenticated on all workers (`gh auth login`)
- [ ] Provider CLIs installed and logged in (claude, kimi, grok as needed)
- [ ] Plan uses SSH URLs (`git@github.com:...`), not HTTPS
- [ ] No file conflicts within waves (different branches touch different files)
- [ ] Dependencies in separate waves (lower waves first)
- [ ] Branch names contain `/` or omit them to auto-generate
- [ ] Dispatch flags match your use case (`--auto`, `--review`, `--retries`)
- [ ] Rate-caps don't accumulate (check `logs/provider-state/ratecap.log`)
- [ ] Handoff ledger is complete (check `wave-plans/<wave>/handoffs/`)

---

## Further Reading

- [`docs/plan-file-format.md`](plan-file-format.md) — Deep dive on plan syntax
- [`docs/scenarios.md`](scenarios.md) — Real-world examples (bug fix, feature request, pre-launch audit)
- [`docs/proposals/skills-evolution-SYNTHESIS.md`](proposals/skills-evolution-SYNTHESIS.md) — Skills architecture freeze (phases 0–3)
- [`skills/README.md`](../skills/README.md) — Pack layout + promotion rules
- [`scripts/dispatch.sh`](../scripts/dispatch.sh) — Full dispatcher source; see Flags section
- [`scripts/run-remote.sh`](../scripts/run-remote.sh) — skill-inject + preamble + launcher
- [`scripts/skill-inject.sh`](../scripts/skill-inject.sh) — L2 pack assembly
- [`config/workers.yaml`](../config/workers.yaml) — Worker + provider configuration template
- [`config/role-skills.yaml`](../config/role-skills.yaml) — Role → pack map
