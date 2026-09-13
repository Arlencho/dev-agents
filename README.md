# Dev Agents

Portable, project-agnostic, **multi-vendor** orchestration toolkit for AI-powered parallel development.

Run agents via **claude**, **kimi**, and **grok** CLIs with **zero API keys** — subscription login only. Agents pair cross-vendor for decorrelated review and rate-cap failover out of the box.

## What this is

Source of truth for:

1. **Agent role charters** (`roles/*.md`) — **20 active** provider-agnostic roles (engineers, critics, ops, meta). Niche reviewers are parked in `roles/_archived/` (see its README).
2. **Heterogeneous producer-critic pattern** — every implementation task pairs a producer agent with an independent critic on a different model. Charter-level invariant.
3. **Multi-vendor CLI orchestration** — agents run via `claude`, `kimi`, and `grok` subscription CLIs on owned hardware. Provider selection via `workers.yaml provider_preferences` + `routing.yaml provider_failover`. Rate-cap sentinel marks vendors cooling and fails over automatically.
4. **Multi-product orchestration** (`companies/*.md`) — one manifest per product wiring agents, budgets, runtime config, and the source-of-truth product repo path.
5. **L2 skill packs** (`skills/*/SKILL.md` + `config/role-skills.yaml`) — versioned playbooks injected at launch (not identity; not auto-memory). Global packs live here; project packs live in the product repo and **replace** global by pack id. Evolution is PR-gated (human merge for global). See [skills evolution synthesis](docs/proposals/skills-evolution-SYNTHESIS.md).
6. **Paperclip integration** — the `claude_local` adapter runs these agents under the Paperclip orchestration platform (`127.0.0.1:3100`) with task routing, board automation, and budget enforcement.

## What's new

### Heterogeneous producer-critic pattern

Every implementation task runs through a producer + critic pair. Heterogeneity is **two-layered**:

1. **Vendor** (CLI): preferred when configured (Kimi or Grok producer × Claude critic).
2. **Model tier**: when both seats are Claude, critic still uses a **different** tier than the producer.

Critics report to CTO for independence, but pair with their producer counterpart on every diff. Seats come from `config/workers.yaml` → `provider_preferences` + `config/routing.yaml` → `model_routing` / `provider_failover`.

**Pairing matrix (current seats):**

| Producer role | Vendor (CLI) | Model tier | Critic role | Critic vendor | Critic tier | Discipline |
|---|---|---|---|---|---|---|
| Frontend Engineer (`web-frontend`) | **kimi** (failover: grok) | **K3** | Frontend Critic | **claude** | **claude-fable-5-1** | Next.js / React / Tailwind / a11y |
| Backend Engineer (`go-backend`) | **grok** (failover: kimi) | CLI default | Backend Critic | claude | **claude-fable-5-1** | Go / Chi / pgx / sqlc / OpenAPI |
| Database Engineer (`db-architect`) | **grok** (failover: kimi) | CLI default | Database Critic | claude | **claude-fable-5-1** | Postgres migrations / sqlc / indexes |
| API Designer (`api-designer`) | **grok** (failover: kimi) | CLI default | API Critic | claude | **claude-fable-5-1** | `api.yaml` / generated TS client / envelopes |
| DevOps Engineer (`devops`) | **grok** (failover: kimi) | CLI default | `devops-critic` | **grok** | failover kimi | CI / deploy / infra |
| Plan review (autoplan Pass 4) | n/a | n/a | Plan Critic | **grok** | default | Wave-plan review (`autoplan.sh`) |

> **Config wins:** live vendor + Claude tier = `config/workers.yaml` + `config/routing.yaml`. **Producer routing trial (owner decision 2026-09-13):** every producer except `web-frontend` runs on the grok seat for **five tasks**; critics, `security-reviewer`, `cto` and `orchestrator` keep the first-party seat. **Metric:** rounds to SAFE per producer task, counted against the Kimi and Claude baselines in [`wave-plans/ab-metrics.csv`](wave-plans/ab-metrics.csv). **Exit rule:** a producer whose median rounds to SAFE exceed the baseline by one goes back to its previous seat.

**Hard rules (charter-level invariants):**

1. **Do not same-seat producer and critic** when a cross-vendor or cross-tier pair is available. Same-model pairs lose ~30% of cross-error detection per Reflexion (Shinn 2023) and Constitutional AI (Bai 2022). Do **not** downgrade a critic seat to save cost.
2. **Frontend is the flagship cross-vendor pair:** Kimi produces, Claude critiques. Trust-critical seats (CTO, Security, the discipline critics) keep the first-party primary unless explicitly re-seated in config.
3. The `devops` × `devops-critic` pair is the trial's one same-vendor (grok × grok) seat, bounded by the exit rule above. The old Database same-vendor exception is retired: `db-architect` now produces on grok against the first-party Database Critic. See [`docs/org-chart.md`](docs/org-chart.md).

**Cross-cutting reviewers** (peers, NOT discipline-paired; first-party unless reconfigured):
- **QA Engineer** (claude-fable-5-1, test-first): writes failing tests against PRD/contract before producer codes
- **Security Engineer** (claude-fable-5-1, red-team): active attack attempts on every PR before CTO gate
- **CTO** (claude-fable-5-1): final architectural gate (APPROVE-MERGE / BLOCK-FIX / BLOCK-ESCALATE)

Full org chart with reporting + pairing edges: [`docs/org-chart.md`](docs/org-chart.md). Live seats always win over this table if `workers.yaml` differs — update both when you re-seat a role.

### Production evidence — Backend Critic activations

Across the first 3 Backend Critic activations on payment / state-machine code in a live product company, the critic caught CRITICAL bugs that **4 prior reviewers (Bugbot, Security in 3 rounds, QA, CTO architectural gate) all approved**:

- State-machine invariant violation: `Confirmed` status overwrites `Failed` after a downstream provider failure
- Cross-replica race in refund + manual-resolve admin actions
- Double-refund vulnerability: manual-resolve path didn't gate `Status` → subsequent refund call passed the duplicate-action guard

All loops converged within the 2-loop ceiling. No CTO escalation. The executable-only critic charter (failing test diff + `file:line` citation, prose rejected) is load-bearing — it's what stops critics from producing LGTM noise.

### Multi-vendor CLI orchestration (2026-07)

The heterogeneity invariant extended across vendors — same-vendor different-tier pairs still share training lineage; cross-vendor pairs decorrelate harder. Every vendor runs through its **own subscription-authenticated CLI** — Claude Code (`claude`), Grok Build (`grok`), Kimi Code CLI (`kimi`) — with **zero API keys**. Auth is a per-machine login, exactly like `claude login`.

**Provider launcher layer** (`providers/lib.sh` + `providers/<vendor>/launch.sh`) — one launcher per vendor behind a uniform contract: `launch.sh <role> <task>`, exit `0` success / `1` fail / `75` rate-capped / `69` unavailable. `run-remote.sh` ships the launcher to the worker and invokes it; `dispatch.sh` reads `AGENT_PROVIDER` from `provider_preferences` (workers.yaml). Non-claude launchers inject the `roles/<role>.md` charter into the prompt (no `--agent` equivalent); guardrails still apply as git hooks.

**Rate-cap sentinel + failover** — a vendor that emits a cap pattern (`config/ratecap-patterns.conf`) exits 75; the vendor is marked cooling (`logs/provider-state/`, `cooldown_minutes` in routing.yaml), the event is logged + notified, and `dispatch.sh` **fails the task over** to the next provider in `routing.yaml provider_failover` — reusing the existing retry loop. `make scorecard` shows cooldown state, cap events, and per-provider task outcomes.

**Seats today**: `web-frontend` → **Kimi K3** primary, `grok` failover (`providers/kimi/README.md`). Every other producer (`go-backend`, `db-architect`, `api-designer`, `devops`, `test-engineer`, `mobile`, `investigate`, `docs-writer`) → **Grok** primary, `kimi` failover, under the five-task routing trial (owner decision 2026-09-13): rounds to SAFE counted against the Kimi and Claude baselines in `wave-plans/ab-metrics.csv`, and a producer whose median exceeds the baseline by one goes back (`providers/grok/README.md`). The discipline critics keep a first-party primary on **claude-fable-5-1** with grok as the only failover; `security-reviewer`, `cto` and `orchestrator` carry no failover entry. **Grok Plan Critic** runs as Pass 4 of `autoplan.sh` via the grok CLI (`providers/grok/README.md`).

**Non-goals**: no vendor swap on orchestrator, CTO gate, security, or the critic primaries; trust-critical seats stay on harness-proven Claude.

### Per-role model routing

`config/routing.yaml → model_routing:` pins each role to a **Claude model id** (`claude-fable-5-1` for every first-party seat). Kimi/Grok launchers **ignore** the Claude model column and use the CLI default (Kimi **K3**, Grok default). Live seats: see `workers.yaml` `provider_preferences` + this map.

| Example seat | Provider | Model (today) |
|---|---|---|
| `web-frontend` | kimi | **K3** (CLI default) |
| trial producers (`go-backend`, `db-architect`, `api-designer`, `devops`, `test-engineer`, `mobile`, `investigate`, `docs-writer`) | grok | CLI default |
| `plan-critic` / `devops-critic` | grok | CLI default |
| critics / cto / security / retro / orchestrator | claude | **claude-fable-5-1** |

### L2 skills + experience evolution (Phase 0 live)

Agents load **charter (L1) + skill packs (L2) + case file (L3 preamble) + task**. Skills are short, evidence-cited playbooks under `skills/<id>/SKILL.md`, mapped per role in `config/role-skills.yaml`.

**Runtime (fleet dispatch):** `scripts/run-remote.sh` runs `scripts/skill-inject.sh` and places L2 text **before** the L3 preamble (not inside `preamble.sh`). Missing packs warn and continue — never block dispatch. Workers also receive a copy under `~/dev/agent-runtime/<dispatch id>/skills/`, shipped once per dispatch.

**Starter packs (shared, not 50 novels):** `evidence-first`, `untrusted-prior`, `handoff-intent`, `git-ship`, `docs-no-hallucinate`, `session-modes` (orchestrator). Lint with `./scripts/skills-lint.sh`.

**Evolution:** experience stays in learnings/handoffs/retros; **promotion is a PR** (project → critic or human; **global → human always**). No producer auto-merge of skills. No AI branding on commits/PRs (`git-ship` + commit-msg guardrail). Full freeze: [`docs/proposals/skills-evolution-SYNTHESIS.md`](docs/proposals/skills-evolution-SYNTHESIS.md). Phases 1–3 (manual promote practice → candidate automation → metrics) are planned there; only **Phase 0 inject** is shipped.

**Session modes (Phase 0):** co-pilot contracts **Conductor / Wave / Auto** — classify → task packet → human go → `dispatch.sh`. Chat does not silently ship product fixes. Contract: [`docs/session-modes.md`](docs/session-modes.md). Freeze: [`docs/proposals/session-modes-SYNTHESIS.md`](docs/proposals/session-modes-SYNTHESIS.md).

### Fleet Desk (v2 — shipped)

Static **Almanac** (settled record) + live **Ops Floor** (motion during dispatch). Full walkthrough: [`docs/experience.md`](docs/experience.md).

```bash
make experience-open   # Almanac (file://) — companies, missions, trails
make desk-follow       # Ops Floor at http://127.0.0.1:8777/live/ (leave open)

# Terminal B — work that the Floor can see:
./scripts/dispatch.sh git@github.com:you/repo.git wave-plans/your.plan
# or long shell:
./scripts/fleet-session.sh run --label my-run --repo my-repo -- make test
```

Live polls ~3s (no reload). Settled runs: **REPLAY** scrubber on the Floor. Quiet stream (~90s no events while still “running”) shows **QUIET** hang chrome.

The strip offers **today** and **yesterday** (the day before, read from the same streams the same way; older history is the Almanac's). Push: `FLEET_NOTIFY_NEEDS_YOU_MIN=10 make desk-follow` sends one macOS notification per NEEDS YOU item nobody acted on for 10 minutes, once per item; off when the variable is unset. Details: [`docs/experience-data.md`](docs/experience-data.md) § Yesterday and the push.

## Operator Quickstart

If you're running agents on owned hardware (local machines or Mac Minis), this section is your starting point.

### Two modes: co-pilot chat vs fleet dispatch

**Mode 1: Co-pilot chat (single-agent, one CLI)**
```bash
# In any project directory
claude --agent go-backend "fix auth bug #123"
claude --agent web-frontend "build login page"
claude --agent security-reviewer "review PR #301"
```
Use this for focused, interactive work — one agent, immediate feedback, no wave coordination. For product pins, prefer **session modes** ([`docs/session-modes.md`](docs/session-modes.md)): Conductor routes to a seat instead of self-fixing in chat.

**Mode 2: Fleet dispatch (multi-agent, parallel waves, from shell)**
```bash
# Orchestrate 5–20 agents across waves from a plan file
./scripts/dispatch.sh git@github.com:yourcompany/myproject.git wave-plans/myplan.txt --auto --retries 3
```
Use this for multi-step features (API spec → migration → backend → frontend → tests) where tasks have dependencies and parallelism matters.

### Plan file format (WAVE agent task branch)

Plan files define what agents do, in what order, and on which branches. One task per line:

```
WAVE | AGENT | TASK_DESCRIPTION | BRANCH_NAME
```

**Example:**
```
# Payments feature — 3 waves
1 | db-architect   | create payments tables migration        | feat/payments-db
1 | api-designer   | add payment endpoints to OpenAPI spec   | feat/payments-spec
2 | go-backend     | implement payment service and handlers  | feat/payments-svc
2 | web-frontend   | build checkout page with Stripe Elements| feat/payments-ui
3 | test-engineer  | add payment flow integration tests      | feat/payments-tests
3 | security-reviewer | audit payment code for vulnerabilities | feat/payments-audit
```

**Critical rules** (canonical: [`docs/plan-file-format.md`](docs/plan-file-format.md) — matches `dispatch.sh`):
- **Wave ordering**: same wave parallel; higher waves wait.
- **Pipes in description are preserved** (middle fields re-joined). Do **not** escape with `\|`.
- **Branch** is optional last field only if it looks like a branch (`contains /`, no spaces); else auto-generated.
- **Producer + critic same branch → different waves.**
- Lines starting with `#` and blank lines are ignored.

Full grammar: [`docs/plan-file-format.md`](docs/plan-file-format.md).

### Running dispatch.sh: git SSH, Homebrew bash, --auto, --retries

**Prerequisite:** bash 4+ (macOS ships bash 3.2; use Homebrew).
```bash
brew install bash
```

**Basic dispatch:**
```bash
./scripts/dispatch.sh git@github.com:yourcompany/myproject.git wave-plans/myplan.txt
```

**Flags:**
- `--auto` — auto-continue between waves (no "press Enter" prompts). Useful for CI or overnight runs.
- `--retries N` — max retries per task (default: 2). Set higher for flaky agents.
- `--review` — run autoplan review before dispatching (see `autoplan.sh`).
- `--retry-on-different-worker` — on failure, try the same task on a different worker.
- `--no-wait`: do not queue behind another dispatch on one of this plan's branches; exit 9 immediately instead.

**One worktree per seat.** `scripts/run-remote.sh` keeps `~/dev/<repo>` on the worker as a
fetch point only (cloned once, then only ever fetched; HEAD stays detached at `origin/main`, so no
branch, `main` included, is ever checked out there and a seat on any branch can start) and
gives every seat its own git worktree at `~/dev/worktrees/<repo>/<dispatch id>/<task id>-<branch>`
(the dispatch id is `<UTC second>-<repo>-<dispatcher pid>`, so two dispatches started in the same
second never share a directory),
added from `origin/<branch>` when the branch exists on origin, else as a new branch from
`origin/main`. The seat runs, commits and pushes in that worktree; `handoff.md` is copied next to
the seat log before the worktree is removed at seat exit, on every path (normal end, launcher
exit 1 / 69 / 75, Ctrl-C, kill). Set `FLEET_KEEP_FAILED_WORKTREES=1` on the dispatcher to keep the
worktree of a seat that exited non-zero for inspection; the daily sweep removes it after a day.
Fetch-point operations (clone, fetch, hook install, worktree add / remove) are serialized per
repo by `~/dev/<repo>.seat-lock`, so the seats of one wave can start in the same second.

**One local dispatch per branch.** Because every seat has its own worktree, two dispatches on
the same repo run concurrently. What still must not interleave is two dispatches driving the
same branch (their producer and critic seats would take turns on it with no plan-level
ordering), so before the first wave `dispatch.sh` takes one lock per distinct branch in its
plan whenever a localhost worker is in play, in sorted order, and holds them until the run
ends. A second dispatch that needs a held branch prints the holder's pid, plan and branch and
then queues (heartbeat line every 60s), or exits 9 straight away with `--no-wait`, releasing
any lock it had already taken.

The locks are **machine-global, not per clone**: they live at
`~/dev/dispatch-locks/<repo>/<branch>.lock` (slashes in the branch written as dashes), the same
per-user fleet base as `~/dev/agent-logs` and the `~/dev/<repo>` fetch point they protect. Two
clones of dev-agents on one host therefore contend for the same files instead of each holding
private ones. Override the base with `FLEET_HOME` (or the directory with `LOCK_DIR`) if your
fleet keeps its per-user state elsewhere.

The locks are released on normal exit, on error, and on Ctrl-C / kill / hangup, including while
a wave is still running: the wave wait and the retry backoff poll in short slices rather than
blocking, so a signal is serviced within about a second instead of waiting for the seats. The
run keeps its exit code through the close-out (130 interrupted, 143 terminated). A lock whose
owner pid is gone is cleared automatically. Remote-only fleets never take them. Inside one
dispatch, a seat whose branch is still held by a live seat (same wave, or a retry) waits for
that seat instead of failing; see `wait_for_branch` in `scripts/run-remote.sh`.

**Example: fast, parallel, hands-off dispatch:**
```bash
/opt/homebrew/bin/bash scripts/dispatch.sh git@github.com:yourcompany/myproject.git wave-plans/feature-2026-07.txt --auto --retries 3
```

### Detached dispatch: --detach, dispatch-status, dispatch-wait, the queue runner

**Why.** A dispatch started from a chat session is a background task of that session, and the
harness kills the whole process group of its background tasks when the turn ends or the session
is killed. The same happens to a dispatch started from an ssh shell that hangs up. Every seat in
flight dies with it, the branch locks are left to the stale-lock sweep, and the Floor shows a run
that never closed. The fix is not a longer session: it is a dispatch that no parent owns.

**Run detached.** `--detach` forks a child that becomes the leader of a session of its own
(`setsid`), with `/dev/null` for stdin, the run log for stdout and stderr, and `SIGHUP`
ignored (what `nohup` does). macOS ships `nohup` but no `setsid` binary, so the two steps are
one perl call (`fork` + `POSIX::setsid` + `exec`); perl is on every mac and every worker. The
child re-runs `dispatch.sh` on the attached code path unchanged: same branch locks, same queue
marks, same events, same notify hooks. The parent prints the id and returns:

```bash
./scripts/dispatch.sh git@github.com:you/repo.git wave-plans/x.plan --detach --retries 1
# dispatch id: 20260913-084708-repo-52236
# pid:         52236 (session leader)
# log:         logs/dispatch-runs/20260913-084708-repo-52236.log
# check:       scripts/dispatch-status.sh 20260913-084708-repo-52236
# wait:        scripts/dispatch-wait.sh 20260913-084708-repo-52236 [timeout seconds]
```

`--detach` implies `--auto` (there is no one at stdin to press Enter) and refuses
`--interactive`. `--review` still runs in the foreground, before the fork, so you see the
verdict. Nothing aimed at the shell you started from, its process group, or its session
reaches the run: close the chat, kill the terminal, it keeps going. Files, all under
`logs/dispatch-runs/` (gitignored): `<id>.log` everything the run printed, `<id>.pid` the
pid, repo slug, plan and start time (one per line), `<id>.exit` the run's exit code, written on
its way out. The event stream opens under the same id at `logs/fleet-events/<id>.jsonl`.

**Check.** `scripts/dispatch-status.sh <id>` prints running or the final status, the seat
table folded from the event stream, and the last ten lines of the log. Exit **3** while the run
is going, **0** once it has ended (completed, aborted, or died without a close-out: pid gone
and no `dispatch_end` event), **2** for an id nothing knows. A run started without `--detach`
has no pid file and is read from its event stream alone.

**Wait.** `scripts/dispatch-wait.sh <id> [timeout seconds]` polls that status every 30 seconds
and prints the same summary when the run ends (exit 0) or the timeout passes (exit 3, snapshot).
This is the command a chat session runs instead of holding the dispatch as its own background
task: the waiter can be killed or time out and the run does not notice.

```bash
./scripts/dispatch-wait.sh 20260913-084708-repo-52236 1800   # give it half an hour, then look
make dispatch-status ID=20260913-084708-repo-52236
```

**The queue runner.** `scripts/queue-runner.sh` is one tick of the Ops Floor queue
(`logs/fleet-queue.json`, see `make queue-list`): if no dispatch is running for a repo and
the queue holds a queued plan for that repo whose blocked reason is empty, it starts that plan
with `--detach --auto`, reading the repo URL and the flags from the plan's own
`# DISPATCH: ./scripts/dispatch.sh <repo-url> <plan> ...` header line. At most one start per
tick, one running dispatch per repo (a live pid in `logs/dispatch-runs/*.pid`, or a live pid
in a branch lock under `~/dev/dispatch-locks/<repo>/`, counts as running; the per-branch
locks stay the safety net beneath). What it started goes to
`logs/dispatch-runs/queue-runner.log`. A plan it cannot start (no file, no `DISPATCH` line,
`dispatch.sh` refused) is marked blocked with the reason so it is not retried every minute;
`make queue-list` shows the reason, `./scripts/queue.sh unblock <plan>` clears it, and
`./scripts/queue.sh block <plan> "reason"` holds a plan back on purpose.

Installed the same way as the PR Sentinel and the worktree sweep (a plist in `docs/`, an
install and an uninstall script, make targets), and off until installed:

```bash
make queue-runner-dry          # what the next tick would start, starts nothing
make queue-runner              # one tick by hand
make queue-runner-install      # launchd, every minute (docs/queue-runner-launchd.plist)
make queue-runner-status
make queue-runner-uninstall
launchctl setenv QUEUE_RUNNER_PAUSE 1     # pause: the tick does nothing while this is set
launchctl unsetenv QUEUE_RUNNER_PAUSE
```

The tick's own output goes to `~/Library/Logs/queue-runner.log`; the runs it starts log under
`logs/dispatch-runs/`. The plist sets `AbandonProcessGroup` as a second guard, but the run
does not need it: it is a session of its own before the tick ends.

Ground Truth: `tests/run-detached-dispatch-tests.sh` starts a detached run from a shell in
its own process group, kills that group, and shows the run finishing with its events, queue
marks and lock release intact; then the status and wait exit codes, and the runner starting
one plan and not a second while the first runs.

### workers.yaml provider_preferences + routing.yaml provider_failover

**Edit `config/workers.yaml`** to assign which CLI each agent prefers:
```yaml
provider_preferences:
  go-backend: grok
  web-frontend: kimi       # Primary: Kimi K3; fails over to grok if capped
  db-architect: grok
  api-designer: grok
  devops: grok
  test-engineer: grok
  security-reviewer: claude
  cto: claude              # Trust-critical; always Claude
  orchestrator: claude     # Trust-critical; always Claude
  default: claude          # Fallback for any unlisted agent
```

**Edit `config/routing.yaml`** to define failover chains:
```yaml
provider_failover:
  web-frontend: [kimi, grok]    # Try kimi first; if capped, use grok
  go-backend: [grok, kimi]      # Trial producers: grok first, never claude
  default: [claude, kimi]       # Default chain: claude first
```

How it works:
1. `dispatch.sh` reads `provider_preferences[agent]` to pick the primary vendor.
2. If the primary is rate-capped (exit 75) or unavailable (exit 69), `dispatch.sh` walks `provider_failover[agent]` for the next provider.
3. Same retry loop applies; the task is retried on the failover provider up to `--retries` times.
4. Log all events and results per provider (see `make scorecard` below).

**Provider README references:**
- Kimi (K3 producer): [`providers/kimi/README.md`](providers/kimi/README.md)
- Grok (trial producer seats + plan-critic): [`providers/grok/README.md`](providers/grok/README.md)
- Claude (default, trust-critical roles): `providers/claude/agents/` (copied from roles/ via `scripts/sync-providers.sh` (roles/ is upstream))

### make scorecard

View cross-vendor task outcomes, rate-cap events, and cooldown state:
```bash
make scorecard
```

Output shows:
- Per-provider task success/failure counts
- Rate-cap events (if any vendor hit quota)
- Cooldown state (vendor unavailable until timestamp)
- Wave-by-wave execution summary

Run this after dispatches to audit provider health and inform `provider_preferences` tuning.

### Worker login notes

Each vendor requires a **one-time subscription login** on each machine:

**Claude Code (`claude`):**
```bash
claude login
```
Browser OAuth flow. Requires a Claude **Pro or Max** subscription. Non-interactive SSH workers cannot read macOS Keychain OAuth; on those machines mirror credentials to the CLI's file store at `~/.claude/.credentials.json` (mode `600`) so `claude` can authenticate without a GUI Keychain prompt. Do not commit this file.

**Kimi Code CLI (`kimi`):**
```bash
kimi login
```
Device-code OAuth against your Kimi for Coding subscription. Same principle — no API key export; all auth stored locally and refreshed automatically.

**Grok Build CLI (`grok`):**
```bash
grok login
```
Login to xAI Grok via device-code OAuth against SuperGrok / X Premium+ subscription. Same local auth, automatic refresh.

**Non-interactive SSH dispatch note:** If running dispatch.sh from a CI environment or remote shell (e.g., GitHub Actions → SSH → Mac Mini), the login credentials must be in a form accessible without user interaction. This is typically handled by pre-login or SSH agent forwarding. Contact your team's automation lead if you need to set this up. (No credentials are documented in this repo — they live in per-machine setup.)

## Repo structure

```
dev-agents/
├── roles/                    # 20 active role charters (source of truth; sync → providers/)
│   ├── orchestrator.md  cto.md  plan-critic.md  pr-sentinel.md
│   ├── go-backend.md  web-frontend.md  mobile.md  db-architect.md
│   ├── api-designer.md  devops.md  docs-writer.md  investigate.md
│   ├── backend-critic.md  frontend-critic.md  database-critic.md  api-critic.md
│   ├── test-engineer.md  security-reviewer.md  retro.md
│   └── _archived/            # Parked specialty roles — see README there
├── companies/                # Per-product manifests (one file per product)
│   └── # Each manifest: charter, paperclip company id, budget cap, agent
│       # roster (subset of roles/), KPIs, escalation rules, repo path.
│       # See any existing manifest as a template.
├── wave-plans/               # Per-wave execution plans + handoff ledgers
├── learnings/                # Retros + Paperclip release-tracker + per-company logs
│   └── paperclip-changelog.md
├── skills/                   # L2 global skill packs (SKILL.md per pack)
│   ├── README.md             # Layout, promotion rules, delivery-face law
│   ├── evidence-first/  untrusted-prior/  handoff-intent/
│   ├── git-ship/  docs-no-hallucinate/  session-modes/
│   └── _candidates/          # Drafts only — never injected at runtime
├── docs/
│   ├── architecture.md
│   ├── org-chart.md          # Producer-critic reporting + pairing visualization
│   ├── operator-guide.md     # Fleet ops: dispatch, logs, handoffs, failures
│   ├── plan-file-format.md   # Detailed WAVE format spec
│   ├── session-modes.md      # Conductor / Wave / Auto co-pilot contracts
│   ├── paperclip-architecture.md
│   ├── issue-lifecycle.md
│   ├── scenarios.md
│   └── proposals/            # Design freezes (skills evolution, multi-vendor, …)
├── templates/                # Project CLAUDE.md scaffolds + Conductor packet
│   ├── go-nextjs.md  python-fastapi.md  task-packet.md
├── config/
│   ├── workers.yaml          # Worker machine registry + provider_preferences
│   ├── routing.yaml          # model_routing + provider_failover
│   ├── role-skills.yaml      # Role → L2 skill pack map
│   ├── preamble.yaml         # L3 case-file inject limits
│   ├── guardrails.yaml       # Blocked/warned command patterns
│   └── ratecap-patterns.conf # Vendor rate-cap detection patterns
├── providers/
│   ├── lib.sh                # Shared launcher utilities
│   ├── claude/agents/        # Claude Code agent definitions
│   ├── kimi/
│   │   ├── README.md         # Kimi K3 producer setup + rate-cap behavior
│   │   └── launch.sh
│   ├── grok/
│   │   ├── README.md         # Grok trial producer + plan-critic launcher
│   │   └── launch.sh
│   └── openai/  cursor/      # Placeholder stubs
└── scripts/
    ├── bootstrap.sh  setup-machine.sh  new-project.sh
    ├── dispatch.sh           # Multi-agent fleet orchestration (waves)
    ├── run-remote.sh         # Preamble + skill-inject + launcher on worker
    ├── skill-inject.sh       # Assemble L2 skill text for a role
    ├── skills-lint.sh        # Lint packs ([ev:], size, path hygiene)
    ├── guardrails.sh         # pre-push + commit-msg (no AI branding)
    ├── preamble.sh  notify.sh  autoplan.sh  retro-data.sh  learnings.sh
    ├── sync-providers.sh  provider-scorecard.sh
    └── paperclip-up.sh  paperclip-down.sh  paperclip-status.sh  paperclip-refresh.sh
```

## How orchestration actually works

Two execution paths — pick based on task scope:

### Path A — Paperclip task (recommended for multi-step or product-scoped work)

```
You file a task in Paperclip UI (or via API)
        │
        ▼
CEO (Orchestrator, claude-fable-5-1) receives → decomposes
        │
        ▼
CTO (claude-fable-5-1) routes → triages → spawns child sub-tasks
        │
        ▼
QA Engineer (test-first) writes failing tests against PRD
        │
        ▼
Producer (kimi or grok seat) implements
        │
        ▼
Critic (claude-fable-5-1, paired) reviews diff; hard 2-loop ceiling, executable output only
        │
        ▼
Security Engineer (claude-fable-5-1, red-team) attacks the PR
        │
        ▼
CTO architectural gate — APPROVE-MERGE / BLOCK-FIX / BLOCK-ESCALATE
        │
        ▼
DevOps + CI ship
```

Per-task discipline (worktree isolation, label-flip cadence, conventional commits, **no AI branding** on commits/PRs) is enforced by project `CLAUDE.md` rules, fleet `skills/git-ship`, and the commit-msg guardrail hook.

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

### Path C — Fleet dispatch (for multi-agent waves on owned hardware)

```bash
# See "Operator Quickstart" section above for full details
./scripts/dispatch.sh git@github.com:yourcompany/myproject.git wave-plans/myplan.txt --auto --retries 3
```

**Launch prompt shape (fleet path):** L1 charter (launcher / `--agent`) → **L2 skills** (`skill-inject.sh`) → **L3 case** (`preamble.sh`: learnings, git, handoffs) → task text. Log line `Injected L2 skill packs into prompt` confirms skills loaded.

Use fleet dispatch when:
- You have 5–20 agents working in parallel across waves
- Tasks have clear dependencies (API spec → backend → frontend → tests)
- You own the hardware (local machines or Mac Minis, not cloud CI)
- Rate-cap failover and provider rotation are important

## Multi-product orchestration

Each product lives under `companies/` with its own manifest (paperclip company id, budget cap, agent roster, deploy targets). Each manifest pins the source-of-truth product repo path so agents know where to find the product's `CLAUDE.md` and PRDs.

When you ask the Orchestrator a question, the active product context comes from `cwd` matching one of the manifests. Cross-product orchestration is intentionally manual — there is no global queue.

To onboard a new product, follow the checklist in [`PAPERCLIP.md`](PAPERCLIP.md) § 8 ("Standing up a new company").

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

### Paperclip orchestration platform (secondary)
```bash
./scripts/paperclip-up.sh        # start local Paperclip on 127.0.0.1:3100
./scripts/paperclip-status.sh    # health + version + companies + agents
./scripts/paperclip-refresh.sh   # pull latest Paperclip release
./scripts/paperclip-down.sh      # stop
```
Pinned version + release scan log: [`learnings/paperclip-changelog.md`](learnings/paperclip-changelog.md).

### Live-agent sync (post-merge ritual)

`providers/claude/agents/*.md` is the **single source of truth** for all agent instructions. The live Paperclip instance reads `~/.paperclip/instances/default/companies/<id>/agents/<aid>/instructions/AGENTS.md`. These diverge over time unless synced.

**After every merge to `dev-agents/main`** that touches `providers/claude/agents/`:

```bash
make paperclip-sync   # push providers/ → all live AGENTS.md files (provider wins)
```

To check drift without applying:
```bash
make paperclip-check  # report only; exits 1 if any drift or missing provider
```

For **negative drift** (live has content not yet in providers — e.g., you edited a live file directly):
```bash
./scripts/paperclip-sync.sh --reverse <slug>
# e.g.: ./scripts/paperclip-sync.sh --reverse devops
# Copies live AGENTS.md → providers/claude/agents/<slug>.md (with backup)
# Then review the diff and open a PR to dev-agents/main.
```

The sync script resolves agent → provider file via a 3-level lookup:
1. `providers/<kebab(name)>.md` — e.g., "Backend Engineer" → `backend-engineer.md`
2. `providers/<role>.md` — e.g., role=`devops` → `devops.md`
3. Frontmatter `name:` in the live file — e.g., `name: go-backend` → `go-backend.md`

## Available agents (active roster — 19)

> **Config wins** over this table: `config/workers.yaml` + `config/routing.yaml`.

### Engineers (write code)

| Agent | Vendor (CLI) | Model tier | Scope |
|---|---|---|---|
| `go-backend` | **grok** (failover kimi) | CLI default | Handlers, services, providers, middleware |
| `web-frontend` | **kimi** (failover grok) | **K3** | Pages, components, styling, API integration |
| `mobile` | **grok** (failover kimi) | CLI default | Screens, navigation, native features |
| `db-architect` | **grok** (failover kimi) | CLI default | Migrations, sqlc queries, index strategy |
| `api-designer` | **grok** (failover kimi) | CLI default | OpenAPI spec, type generation, response envelopes |
| `devops` | **grok** (failover kimi) | CLI default | Docker, CI/CD, deployment, scripts |

### Critics (prefer cross-tier / cross-vendor vs producer)

| Agent | Vendor / tier | Pairs with | Output rule |
|---|---|---|---|
| `backend-critic` | claude **claude-fable-5-1** (failover grok) | `go-backend` (**grok**) | Failing test diff + `file:line` only |
| `frontend-critic` | claude **claude-fable-5-1** (failover grok) | `web-frontend` (**kimi**) | Flagship **cross-vendor** pair |
| `database-critic` | claude **claude-fable-5-1** (failover grok) | `db-architect` (**grok**) | Migration / index / query critique |
| `api-critic` | claude **claude-fable-5-1** (failover grok) | `api-designer` (**grok**) | Contract / envelope violations |
| `plan-critic` | **grok** | autoplan Pass 4 | Wave-plan review (non-blocking if missing) |

### Cross-cutting

| Agent | Model | Cadence |
|---|---|---|
| `test-engineer` | **grok** (trial producer seat, test-first) | Before producer codes |
| `security-reviewer` | **claude-fable-5-1** (red-team) | Per PR after critic |
| `retro` | **claude-fable-5-1** | Per-wave post-merge |
| `docs-writer` | **grok** (trial producer seat) | Docs / design proposals |
| `investigate` | **grok** (trial producer seat) | Bugs / incidents |
| `orchestrator` / `cto` | **claude-fable-5-1** | Plan / architectural gate |

### Routine discovery

| Agent | Model | Purpose |
|---|---|---|
| `pr-sentinel` | **claude-fable-5-1** | PR queue triage (Paperclip and/or local launchd; see `docs/local-pr-sentinel.md`) |

### Archived (not active)

Specialty / niche roles live in [`roles/_archived/`](roles/_archived/README.md) — reactivate with `git mv` when a wave needs them. Do **not** put archived ids in plan files.

## Parallel development rules

1. Break work into non-conflicting tasks (different files/directories)
2. Prefer isolated git worktrees or per-task branches (fleet path uses branches via dispatch)
3. `api.yaml` changes merge FIRST (everything depends on the contract)
4. Database migrations merge BEFORE code that uses them
5. Tests merge LAST
6. **No two agents thrash the same files** without a barrier
7. **Conventional Commits**, no AI/vendor branding on the delivery face — ban `Co-Authored-By:` AI trailers, "Made with …", "Generated with …" in commits **and** PR titles/bodies (provenance in handoffs/logs only; see `skills/git-ship`)
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

| Provider | Status | Auth | Adapter |
|---|---|---|---|
| Claude Code | Ready | `claude login` | Markdown + YAML frontmatter in `~/.claude/agents/` |
| Kimi Code CLI | Ready | `kimi login` | `providers/kimi/launch.sh` + role charter injection |
| Grok Build | Ready | `grok login` | `providers/grok/launch.sh` + role charter injection |
| OpenAI | Placeholder | TBD | TBD |
| Cursor | Placeholder | TBD | TBD |

## Documentation

| Doc | What it covers |
|---|---|
| [`docs/operator-guide.md`](docs/operator-guide.md) | **Start here for ops** — dispatch, handoffs, skills inject, failures, cookbook |
| [`docs/plan-file-format.md`](docs/plan-file-format.md) | Canonical WAVE plan grammar (matches `dispatch.sh`) |
| [`docs/session-modes.md`](docs/session-modes.md) | Co-pilot session modes: Conductor / Wave / Auto (Phase 0) |
| [`docs/experience.md`](docs/experience.md) | **Fleet Desk (v2)** — Almanac + Ops Floor: live follow, REPLAY, operator path |
| [`docs/experience-data.md`](docs/experience-data.md) | Fleet Desk data contract (schema v2 + live/1 events) |
| [`docs/proposals/fleet-desk-v2-SYNTHESIS.md`](docs/proposals/fleet-desk-v2-SYNTHESIS.md) | Fleet Desk v2 freeze (Phases A–C shipped) |
| [`docs/proposals/experience-console-SYNTHESIS.md`](docs/proposals/experience-console-SYNTHESIS.md) | Fleet Desk Phase 0/1 data freeze (schema v2) |
| [`docs/architecture.md`](docs/architecture.md) | Fleet topology: launchers, failover, L1/L2/L3, Paperclip coexistence |
| [`docs/org-chart.md`](docs/org-chart.md) | Pairing + reporting (vendor-aware) |
| [`docs/paperclip-architecture.md`](docs/paperclip-architecture.md) | Paperclip companies / agents / issues |
| [`docs/issue-lifecycle.md`](docs/issue-lifecycle.md) | Paperclip issue states + PR Sentinel |
| [`docs/local-pr-sentinel.md`](docs/local-pr-sentinel.md) | Local launchd PR Sentinel (vs Paperclip heartbeat) |
| [`docs/scenarios.md`](docs/scenarios.md) | Worked examples |
| [`docs/proposals/README.md`](docs/proposals/README.md) | **Proposals index** — freezes vs drafts |
| [`skills/README.md`](skills/README.md) | L2 skill packs |
| [`docs/proposals/skills-evolution-SYNTHESIS.md`](docs/proposals/skills-evolution-SYNTHESIS.md) | Skills freeze |
| [`docs/proposals/session-modes-SYNTHESIS.md`](docs/proposals/session-modes-SYNTHESIS.md) | Session modes freeze (Phase 0) |
| [`config/role-skills.yaml`](config/role-skills.yaml) | Role → skill map |
| [`providers/kimi/README.md`](providers/kimi/README.md) | Kimi launcher |
| [`providers/grok/README.md`](providers/grok/README.md) | Grok trial producer seats + plan-critic launcher |
| [`learnings/paperclip-changelog.md`](learnings/paperclip-changelog.md) | Weekly Paperclip release scan log |

**Ops:** `make test` · `make experience` / `make experience-open` (Almanac) · **`make desk-follow`** (live Ops Floor + browser) · `./scripts/fleet-session.sh run --label X -- <cmd>` (long shell on Floor) · `make evidence` · `make scorecard` · `make fleet-status` (when configured).

## Real-world results

- **Backend Critic activations** — first 3 activations on payment + state-machine code in a live product company caught 3 CRITICAL/HIGH bugs that Bugbot, Security (3 rounds), QA, and CTO architectural gate had all approved. Validation evidence for the heterogeneity invariant and the executable-only critic charter.
- **Analytics-agent audit** — first pass scored a production data platform 34/100 on data quality across 256K events / 6 Swedish government APIs; identified 10 specific gaps (e.g., 57% municipality misattribution, polluted reference data, missing confidence indicators). After 3 waves of parallel orchestrator-led fixes, re-score was 83.5/100.

The point isn't the score — it's that the agents catch problems human review misses, and the producer-critic pattern catches what single-reviewer pipelines miss.
