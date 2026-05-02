# Paperclip — Agent Runtime for the dev-agents Harness

Owner: Arlen Rios. Adoption date: 2026-04-27. Pinned version: `2026.427.0` (installed 2026-04-27 via `npx paperclipai onboard --yes`). Instance dir: `~/.paperclip/instances/default/`. Bind: `127.0.0.1:3100` (loopback / `local_trusted` mode).

> **TL;DR** — Paperclip is the *runtime* under dev-agents. Roles, wave-plans, retros, and config stay where they are. The SSH-push dispatch via `scripts/dispatch.sh` becomes one of two ways to run agents; the other is Paperclip's heartbeat model with multi-company isolation, budget caps, and a UI dashboard.

## 1. What Paperclip is

[Paperclip](https://github.com/paperclipai/paperclip) is an open-source (MIT) Node.js + Postgres + React platform for running multiple AI agent companies side-by-side under one control plane. It launched 2026-03-04. As of 2026-04-27 it has 59.6k stars, 2,340 commits, and a release cadence of roughly weekly (latest: `v2026.427.0`).

Paperclip is the **organizational layer** for AI labor:

- **Atomic task checkout + budget enforcement** — two agents can't double-do the same task; runaway spend is capped per company
- **Persistent agent state** — heartbeat-based agents resume task context across sessions
- **Runtime skill injection** — agents learn workflows without retraining
- **Governance with rollback** — approval gates, audit trails, safe rollback of config changes
- **Multi-company tenancy** — one deployment, isolated data + budgets per company
- **Bring-your-own-bot** — Claude Code, Codex, OpenCode, anything on OpenRouter, plus custom plugins

It is **not** an agent (it doesn't write code). It is the place agents check out work, report progress, and get governed.

## 2. Why we adopted it

The dev-agents v2 harness solved per-role model routing and dual-use role files (see `README.md` § "What's New in v2"). The next bottleneck is *coordination* across companies:

| Pain point in dev-agents v2 | What Paperclip fixes |
|---|---|
| Wave-plans are markdown only — no atomic checkout, two agents can race | Atomic task checkout |
| No per-project budget caps — Anthropic spend is observed, not enforced | Per-company budget enforcement |
| Retros + learnings are post-hoc files; no live audit trail | Heartbeat-driven audit log |
| Multiple products share one Anthropic key with no tenancy boundary | One deployment, N isolated companies |
| `dispatch.sh` requires Mac Minis online + SSH reachable; no async pull-based work | Heartbeat = agent pulls work when ready |
| 76 abandoned worktrees (2026-04-27 cleanup) — no lifecycle hook on task completion | Task lifecycle hooks built in |

## 3. How it fits with the existing harness

```
                     ┌──────────────────────────────────────────────┐
                     │  dev-agents/  (CONFIG — what + how, agnostic) │
                     │   roles/         — agent type registry        │
                     │   wave-plans/    — per-company task batches   │
                     │   companies/     — per-company manifests      │  ← NEW
                     │   config/        — routing, guardrails, etc.  │
                     │   retros/, learnings/, templates/, providers/ │
                     └─────────────────────────────────────────────┬─┘
                                                                   │
                                                  feeds task defs ▼
                                       ┌──────────────────────────────┐
                                       │  Paperclip (RUNTIME)         │
                                       │   • atomic task checkout      │
                                       │   • budgets per company       │
                                       │   • heartbeat audit log       │
                                       │   • UI @ localhost:3100       │
                                       │   • Postgres persistence      │
                                       └──┬─────────────┬──────────┬──┘
                                          ▼             ▼          ▼
                              ┌──────────────┐ ┌──────────────┐ ┌────────────┐
                              │ Claude Code  │ │ Codex / OAI  │ │ Custom HTTP│
                              │ (heartbeat)  │ │ (heartbeat)  │ │ plugin     │
                              └──────────────┘ └──────────────┘ └────────────┘
```

The legacy SSH-push path (`scripts/dispatch.sh` → `ssh mac-mini → claude`) **stays available** during transition. New work goes through Paperclip.

See [`docs/paperclip-architecture.md`](docs/paperclip-architecture.md) for the runtime sequence diagrams and the SSH-push vs heartbeat comparison.

## 4. Companies

Each company manifest in [`companies/`](companies/) defines: charter, budget, agent roster (subset of `roles/`), KPIs, escalation rules, and the source-of-truth product repo path. Manifests are the source of truth for which companies exist, their Paperclip IDs, and their hiring state — see the individual files for current values.

### Standard org chart (per company)

The recommended team structure when standing up a new company. All specialists report to CTO; producer-critic pairs work peer-to-peer (the pairing isn't drawn in Paperclip's tree UI — see [`docs/org-chart.md`](docs/org-chart.md)):

```
Orchestrator (CEO, opus)            — reportsTo: none
└── CTO (opus, architectural gate)
    ├── Backend Engineer    ← roles/go-backend.md          (sonnet)   ↔ Backend Critic   (opus)
    ├── Frontend Engineer   ← roles/web-frontend.md        (sonnet)   ↔ Frontend Critic  (opus)
    ├── Database Engineer   ← roles/db-architect.md        (opus)     ↔ Database Critic  (opus)
    ├── API Designer        ← roles/api-designer.md        (sonnet)   ↔ API Critic       (opus)
    ├── QA Engineer         ← roles/test-engineer.md       (opus, test-first)
    ├── DevOps Engineer     ← roles/devops.md              (sonnet)
    └── Security Engineer   ← roles/security-reviewer.md   (opus, red-team)
```

Critics MUST run on a different model from their paired producer (heterogeneity invariant — see § 6.3). Hire CMO / UX-Designer / Mobile / Performance / Analytics roles when their domain becomes active.

Each specialist's `AGENTS.md` instructions bundle is **byte-for-byte verbatim** from the corresponding `roles/*.md` file (verified via `cmp`).

## 5. Local setup

```bash
# Install + start (idempotent, prints next steps)
make paperclip-up

# Stop
make paperclip-down

# Status (running? on which port? which version?)
make paperclip-status
```

Paperclip server runs at `http://localhost:3100`. Postgres is embedded on port `54329` (no separate Docker container required for development).

**Defaults to be aware of:**
- `telemetry.enabled: true` — Paperclip sends usage telemetry by default. Disable in Paperclip UI → Settings if you want full air-gap.
- `database.backup.enabled: true` — automatic DB snapshots every 60 min, retained 30 days, in `~/.paperclip/instances/default/data/backups/`.
- `secrets.provider: local_encrypted`, `strictMode: false` — secrets encrypted with master key at `~/.paperclip/instances/default/secrets/master.key`. Strict mode OFF means missing secrets won't hard-fail; consider enabling once production-bound.
- `storage.provider: local_disk` — task attachments live on the local filesystem. Switch to S3 (config block already present) when going VPS.

For production / always-on hosting, the recommended path is a small VPS (Hetzner / Contabo, ~€10–15/mo) — see `docs/paperclip-architecture.md` § "Hosting options".

## 6. Recurring research

The `tech-scout` role (defined in `roles/tech-scout.md`) is configured to monitor Paperclip releases monthly:

```bash
# Run on demand
make paperclip-refresh

# Output: appends a dated entry to learnings/paperclip-changelog.md
```

The cadence (2,340 commits in 8 weeks → roughly weekly releases) means we pin a version and review monthly. Breaking changes get a `learnings/paperclip-breaking-<version>.md` postmortem before upgrading.

## 6.1 Budget guidance (per company)

Paperclip's per-company `budgetMonthlyCents` is a **runaway guardrail**, not a primary spend control on this setup. The `claude_local` adapter authenticates via Claude Code OAuth → Claude Pro Max subscription (flat-rate). Marginal cost is effectively zero up to Pro Max rate limits. The cap tracks what the spend *would* be at API rates, regardless of actual money flow.

Recommended starter caps:

| Company stage | Cap | Reasoning |
|---|---:|---|
| Alpha / development | **€100/mo** | Catches runaway loops within a day; doesn't impede normal work; forces a deliberate raise when usage grows |
| 1K MAU production | €300/mo | Matches `docs/COST_INVENTORY.md` projection at that scale |
| 10K+ MAU production | €1,000+/mo | Effectively no cap; only meaningful if agents are switched to API key (real money flow) |

Per-task token estimate (observed in production): CEO triage ~10K tok, CTO triage ~10K tok, engineer work ~100K tok, reviewer pass ~30K tok → **~$2 per substantive task at API rates**. 90 tasks/mo (3/day) → ~€170/mo. 300 tasks/mo (10/day) → ~€560/mo.

Per-agent caps are also possible (opus tiers cost ~5× sonnet). Default: one company-level cap, then refine per-agent only if a specific agent becomes a hotspot.

## 6.2 API gotchas (learned in production)

When automating Paperclip via API rather than UI:

- **Issue creation defaults to `status: "backlog"`.** Backlog issues are NOT picked up by agent heartbeats — the agent reports "Inbox empty" forever. Always include `"status": "todo"` in the POST body, OR `PATCH` to `todo` immediately after creation. **UI-created issues skip this** — they go straight to `todo`.
- **Issue update is `PATCH /api/issues/<id>`** (top-level). The company-scoped variant `PATCH /api/companies/<id>/issues/<id>` returns 404.
- **Issue read is `GET /api/issues/<id>`** (top-level) — returns full issue with project, goal, ancestors, blockedBy, blocks, relatedWork.
- **Issue list is `GET /api/companies/<id>/issues`** (company-scoped).
- **Heartbeat config** on the orchestrator: `intervalSec: 300, wakeOnDemand: true`. Tasks pick up within 5 min; faster dispatch via the agent's "Wake" / "Run" UI control.
- **Each agent has a personal instructions bundle** at `~/.paperclip/instances/default/companies/<company>/agents/<agent>/instructions/{AGENTS.md, HEARTBEAT.md, SOUL.md, TOOLS.md}`. Verify with `cmp` against your source-of-truth role file when an agent is hired by another agent — autonomous hires occasionally produce duplicates on retry (see `learnings/paperclip-day-1.md`).

## 7. Governance rules

These apply across all companies:

1. **Pinned version, not `main`** — never auto-upgrade Paperclip in production
2. **Budget caps are enforced, not advisory** — Paperclip rejects task dispatch when monthly cap is hit
3. **No cross-company secret access** — each company has its own secret scope
4. **Approval gates on destructive ops** — `git push --force`, `gh pr merge`, `make deploy-*` go through Paperclip's approval queue, not raw agent execution
5. **Lifecycle cleanup is mandatory** — every task definition includes a `cleanup` step (delete worktree, prune branch, etc.). Tasks without cleanup are rejected.

## 8. Standing up a new company — checklist

For each new company you onboard:

- [ ] **Install Paperclip locally** — `./scripts/paperclip-up.sh` (idempotent; pinned version recorded in § 1)
- [ ] **Create the company in Paperclip UI or via API** — record the id + issuePrefix in `companies/<name>.md`
- [ ] **First end-to-end task** — file a small read-only audit task to validate the heartbeat loop before dispatching real work
- [ ] **Hire the team via the `paperclip-create-agent` skill** — every specialist's `AGENTS.md` should be byte-for-byte verbatim from `roles/*.md` (verify with `cmp`)
- [ ] **Set monthly budget cap** — see § 6.1 for guidance based on cadence
- [ ] **Wire the post-task cleanup hook** — every task def must include a `cleanup` step (delete worktree, prune branch); tasks without cleanup are rejected
- [ ] **Decide hosting model** — laptop-only (default), VPS, or hybrid (laptop dev, VPS prod). See `docs/paperclip-architecture.md` § "Hosting options"
- [ ] **Decide on telemetry** — keep `enabled: true` (default) or disable in UI Settings
- [ ] **Decide on `secrets.strictMode`** — flip to `true` before production-bound work
- [ ] **Migrate a real wave-plan into Paperclip task defs** as the first implementation task
- [ ] **Set up the monthly refresh routine** — `./scripts/paperclip-refresh.sh` (or wire as a Paperclip-managed Routine)

## 9. Per-company rollout logs

Operational rollout history (dates, task IDs, hire receipts) is kept per-company under [`learnings/`](learnings/), not in this generic dossier. See:

- [`learnings/paperclip-changelog.md`](learnings/paperclip-changelog.md) — Paperclip release-tracking log (weekly scan)
- `learnings/<company>-day-1.md` (one per company, when added) — first-day audit findings + lessons
- `learnings/<company>-rollout-week1.md` (one per company, when added) — week-1 retrospective
