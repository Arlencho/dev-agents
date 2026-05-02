# Paperclip ↔ dev-agents Architecture

How Paperclip slots into the existing dev-agents harness. Read [`PAPERCLIP.md`](../PAPERCLIP.md) first for the dossier.

## 1. Two dispatch models

The harness now supports two ways to run a wave-plan. They coexist; choose per task.

### 1.1 Legacy: SSH-push to Mac Minis

The original v2 model. `scripts/dispatch.sh` parses a wave-plan, SSHs to the right Mac Mini, and invokes `claude --model <tier>` per role.

```
wave-plan.md ──► scripts/dispatch.sh ──ssh──► claude (Mac Mini 1, model=opus)
                                       ──ssh──► claude (Mac Mini 2, model=sonnet)
                                       ──ssh──► claude (Mac Mini 3, model=haiku)
```

**Strengths:** simple, no control plane, reuses existing SSH/`workers.yaml`/routing.

**Limits:**
- Push-based — Mac Mini must be online & reachable when dispatch runs
- No atomic checkout — two dispatches can race on the same wave-plan
- No budget enforcement — cost is observed in `wave-plans/*.log` after the fact
- No multi-company tenancy — every dispatch shares one secret/credential scope
- No lifecycle cleanup — the agent is responsible for its own cleanup; missed cleanup → orphaned worktrees (76-worktree cleanup, 2026-04-27)

### 1.2 New: Paperclip heartbeat

Paperclip runs a control plane (Node.js + embedded Postgres). Tasks are *checked out* by agents that heartbeat back.

```
wave-plan.md ──► paperclip task definitions (per company)
                          │
                  ┌───────┴────────┐
                  ▼                ▼
           claude (heartbeat)  codex (heartbeat)
                  │                │
                  └───── checks out atomic task ─────┐
                                                      ▼
                                       paperclip control plane
                                       (budget caps, audit log, governance)
```

**Strengths:**
- Pull-based — agents pick up work whenever they're ready (laptop closed → resume on wake)
- Atomic checkout — one task, one agent, no races
- Budget caps per company, enforced at dispatch
- Multi-company isolation — one company's tasks can't read another company's state
- Lifecycle hooks — task-complete → cleanup runs deterministically
- UI dashboard at `localhost:3100` — see what's running across all companies

**Costs:**
- Server must be running (laptop or VPS)
- Postgres state — backups, migrations, eventual upgrade pain
- Pinned-version discipline (release every ~week → breaking changes possible)

## 2. When to use which

| Situation | Use |
|---|---|
| Quick one-off dispatch, single company, you're at the keyboard | **SSH-push** (`make dispatch`) |
| Multi-company work in flight, need budget caps, want async pickup | **Paperclip** |
| Production / always-on agents, governance required | **Paperclip** |
| Migrating an existing wave-plan to test Paperclip | **Paperclip** |
| Network-flaky environment where SSH stalls | **Paperclip** |

## 3. What stays in dev-agents (unchanged)

These are the *language-agnostic* parts of the harness — they describe **what** and **how**, independent of runtime.

| Asset | Purpose | Paperclip relation |
|---|---|---|
| `roles/*.md` | Agent type registry | Imported as Paperclip "agent types" — same YAML frontmatter format |
| `wave-plans/<company>-<topic>-<date>.md` | Per-company task batches | Source-of-truth for the human; converted to Paperclip task defs |
| `config/routing.yaml` | Per-role model tier | Paperclip reads this to set `--model` on agent invocation |
| `config/guardrails.yaml` | Pre-execution blocking rules | Wired into Paperclip's `PreToolUse` hooks |
| `config/preamble.yaml` | Project-context preamble per agent | Injected by Paperclip on task checkout |
| `templates/*.md` | New-project scaffolds | Unchanged |
| `providers/<provider>/agents/` | Provider-format role copies | Unchanged — `make sync` keeps them in sync with `roles/` |
| `learnings/`, `retros/` | Postmortems, learnings | Paperclip's audit log feeds *into* these (one entry per completed wave) |

## 4. What's new in dev-agents

| Asset | Purpose |
|---|---|
| `PAPERCLIP.md` | Top-level dossier — what is it, version, our config, our companies |
| `companies/<name>.md` | Per-company manifest — charter, budget, agent roster, repo path, KPIs |
| `docs/paperclip-architecture.md` | This file |
| `scripts/paperclip-up.sh` | Idempotent local startup (calls `npx paperclipai onboard --yes` first run, otherwise just starts the server) |
| `scripts/paperclip-down.sh` | Stop server cleanly |
| `scripts/paperclip-status.sh` | Health check + version + currently-checked-out tasks |
| `scripts/paperclip-refresh.sh` | Run `tech-scout` against latest Paperclip releases; appends to `learnings/paperclip-changelog.md` |
| Makefile targets | `make paperclip-{up,down,status,refresh}` |

## 5. Hosting options

### 5.1 Local laptop (current)
- Server runs at `127.0.0.1:3100`, embedded Postgres at `127.0.0.1:54329`
- Data dir: `~/.paperclip/instances/default/`
- Backup: every 60 min, retained 30 days, in `<data dir>/data/backups`
- Trade-off: laptop sleeps → agents stop. Fine for dev / interactive sessions

### 5.2 Always-on VPS
- ~€10–15/mo (Hetzner CX22 or Contabo VPS S)
- Same install (`npx paperclipai onboard --yes`), `bind=0.0.0.0` behind a Caddy/Cloudflare Tunnel
- External Postgres (Neon free tier or VPS-local) for backups + reliability
- Trade-off: more ops, but agents run while you sleep
- Recommendation: defer until at least one company is in steady-state

### 5.3 Hybrid
- Laptop dev (interactive) + VPS prod (long-running)
- Two separate Paperclip instances; same `dev-agents/` repo references both
- Companies can be split: production company on VPS, sandbox on laptop

## 6. Integration sequence — first end-to-end

This is the path to validate Paperclip with one real wave:

1. **Pin a version** — note the current version in `PAPERCLIP.md` § 1
2. **Create your first company** in the Paperclip UI (or via API) — manifest in `companies/<name>.md`
3. **Set budget cap** — based on your expected agent cadence
4. **Import roles** — `roles/*.md` → Paperclip agent types (one-time sync)
5. **Convert one wave-plan** — pick the smallest open wave-plan in `wave-plans/` and convert its issues into Paperclip task defs
6. **Wire one Claude Code agent** to heartbeat on the company
7. **Dispatch the task** — agent checks out, runs, reports
8. **Verify cleanup** — task-complete hook removes the worktree
9. **Capture lessons** — `learnings/paperclip-rollout-week1.md`

After this works, repeat with rios-operator. After that, plan AEGIS / WearForRun / SafePlace as their codebases come online.

## 7. Failure modes + mitigations

| Failure | Symptom | Mitigation |
|---|---|---|
| Paperclip server crashes mid-task | Agent heartbeat 5xx, task stuck `in_flight` | Watchdog (Paperclip has `liveness_recovery_dedupe` migration) auto-recovers; manual `paperclip task release <id>` as fallback |
| Anthropic budget cap hit | Task dispatch rejected | Either raise cap (governance approval) or wait for monthly reset |
| Plugin loader fails | UI works, agents can't pick up tasks | `make paperclip-status` shows registered tools count = 0; restart fixes |
| Embedded Postgres data corruption | Server won't start | Restore from `~/.paperclip/instances/default/data/backups` (60-min granularity) |
| Two laptops running same instance | Two `127.0.0.1:3100` competing — won't happen in practice | Bind enforces loopback; instance dir is per-machine |

## 8. Migration vs replacement — explicit

The SSH-push path is **not deprecated.** `scripts/dispatch.sh` keeps working for ad-hoc work. Paperclip is for governed, multi-company, async-tolerant work. Both can coexist indefinitely.

If/when Paperclip proves out across all 5 companies, we'll re-evaluate retiring `dispatch.sh`. Until then, dual-runtime is the design.
