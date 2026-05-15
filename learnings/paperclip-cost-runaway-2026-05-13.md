# Paperclip cost runaway — 2026-05-13 → 2026-05-15

**Incident**: A full month of Anthropic spend consumed in ~3 days on the
Olympus 14-agent fleet. Reported by the human on 2026-05-15 after the
London demo.

**Status**: Mitigated. Paperclip server stopped 2026-05-15 14:31 CEST.
Fix landed in `scripts/paperclip-apply-safe-defaults.sh` + auto-apply
hook in `scripts/paperclip-up.sh`. Documented in PAPERCLIP.md §6.1a.

## Timeline

- **2026-04-27** — Paperclip onboarded. Default state per Paperclip
  itself: heartbeat disabled, `budgetMonthlyCents: 0` (unlimited).
- **2026-05-12 21:00 CEST** — All 14 agents flipped to
  `heartbeat.enabled: true, intervalSec: 300, wakeOnDemand: true,
  maxConcurrentRuns: 5` for the May 15 London demo countdown. Memory:
  `project_paperclip_heartbeat_demo_window.md`. Planned cleanup:
  2026-05-16 (the day *after* demo).
- **2026-05-13 → 2026-05-15** — Heavy multi-agent activity through the
  demo prep window. Producer chains running iteratively (5 Frontend
  Engineer loops on PR #1321 alone), CTO + Critics + QA + Security on
  every chain.
- **2026-05-15 ~14:00 CEST** — Human realises monthly Anthropic budget
  is exhausted.
- **2026-05-15 14:31 CEST** — Server killed (PID 55927); 8 orphan
  Claude Code subprocesses reaped.

## Contributing factors (ranked by suspected cost weight)

1. **Opus on 5 of 6 review-chain stages** — CTO + Backend Critic + QA
   Engineer + Security Engineer + (Frontend / Database / API) Critic
   per chain. Opus is ~5× Sonnet on inputs. Every chain fired all of
   them.
2. **Producer chain iterations** — Frontend Engineer iterated 5× on
   #1321 (U+2019 regex case) before convergence. Each iteration is a
   full Sonnet run on a large changeset.
3. **Heartbeat polling × 14 agents × 5-min interval × 3 days** —
   ~12,096 heartbeats total. Most are no-op but some wake into a real
   Claude run.
4. **`maxConcurrentRuns: 5` per agent** — when work arrived in bursts,
   up to 5 simultaneous Claude streams per agent.
5. **The "always-on" PR Sentinel** — 132 runs in the 6-day log window,
   sweeping every open PR on every heartbeat.
6. **The active Claude Code orchestrator session (Opus 4.7, 1M
   context)** — multi-day session, several long doc-writing turns,
   image analyses. Independent of the Paperclip fleet but pulled from
   the same Anthropic budget.

## What we fixed

1. **`heartbeat.enabled: false` by default on every agent.** The
   `paperclip-apply-safe-defaults.sh` script runs automatically on
   every `paperclip-up.sh`. Agents wake only on explicit assignment
   (`wakeOnDemand: true`).
2. **Per-agent `budgetMonthlyCents` caps.** Total fleet ceiling
   €215/mo, weighted by role × model. Paperclip rejects task dispatch
   when an agent hits its cap.
3. **`intervalSec: 1800` (30 min) and `maxConcurrentRuns: 2` when
   heartbeat is later enabled.** Halves the polling frequency and caps
   simultaneous runs.
4. **`make paperclip-agent-on/off/status` subcommands.** Selective
   per-agent control for active work, with a built-in reminder to turn
   the agent back off when done.
5. **PAPERCLIP.md §6.1a documents the new safety model** so the next
   re-onboard, or any future operator, starts from safe defaults.

## What we deliberately did NOT do

- **Modify the Paperclip platform itself.** It is upstream open-source;
  the right level of intervention is per-instance config, not a fork.
- **Daily cost-watcher cron.** Considered, rejected as over-engineering
  for a solo-dev environment. The per-agent budget cap is enforced by
  Paperclip at task-dispatch time, which is the right abstraction.
- **Disable `dangerouslySkipPermissions`.** Out of scope for this
  incident (it's a security posture, not a cost lever).

## How to verify the fix

Next time Paperclip is brought up:

```bash
cd dev-agents
make paperclip-up         # foreground; safe defaults auto-apply
# In another terminal:
make paperclip-agent-status
# Expected: all 14 agents show heartbeat=off, model-appropriate budget caps
```

If the table shows `heartbeat=ON` on any agent right after `paperclip-up`,
the auto-apply hook in `paperclip-up.sh` failed — investigate the
`[safe-defaults]` log lines.

## Lessons codified

- **"Heartbeat ON during demo window" is the wrong abstraction.** The
  right one is "explicitly wake the agent you need for the next 30
  minutes, then put it back to sleep." This is what the Paperclip UI's
  "Wake" / "Run" buttons are for — we just need to use them.
- **Budget caps must default to non-zero.** `0 = unlimited` is the
  wrong default for any subscription-replaceable runtime. Even at
  Pro Max flat-rate, the cap is the only enforceable signal that
  prevents a runaway from chewing through actual money via API rates.
- **Demo-window state changes need an automatic revert deadline.** The
  cleanup script in `project_paperclip_heartbeat_demo_window.md` was
  scheduled for 2026-05-16. By then the damage was done. Better
  pattern: set a `validUntil` timestamp at the same time the override
  is applied, and the auto-apply hook restores defaults the moment
  that timestamp passes.

## Postmortem author

Claude Opus 4.7 + Arlen Rios, 2026-05-15.
