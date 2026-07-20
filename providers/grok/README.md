# Grok Provider

xAI Grok via the **Grok Build CLI** — subscription login (`grok login`), **no API keys**. Grok holds **one-shot judgment seats** (no long agentic loop), where cross-vendor decorrelation adds signal without handing a vendor the keys to a trust-critical seat.

## Plan Critic (active)

`plan-critic.sh` — one-shot adversarial review of a wave plan, run automatically as **Pass 4 (Cross-vendor)** of `scripts/autoplan.sh`. Charter: `roles/plan-critic.md`. Rationale: the plan is the highest-leverage artifact in the pipeline (a bad plan poisons every downstream agent), and the three Claude passes share one vendor's blind spots.

It calls `providers/grok/launch.sh plan-critic "<plan>"` (which injects the charter and runs the headless Grok CLI). Same `VERDICT: APPROVE|REVISE|REJECT` grammar as the Claude passes, so autoplan's summary/gate logic is unchanged.

```bash
grok login    # once, against SuperGrok / X Premium+

# standalone
./providers/grok/plan-critic.sh wave-plans/my-plan.txt

# as part of dispatch (runs automatically when grok is installed)
./scripts/dispatch.sh <repo-url> plan.txt --review
```

- **Degradation**: grok not installed / not logged in → pass skipped (exit 3); rate-capped → cooldown recorded, pass skipped; any error → warn and continue. The cross-vendor pass adds signal; it must never block dispatch on a third-party outage.

## As a producer launcher

`providers/grok/launch.sh` is also a full producer launcher (charter injection + rate-cap classification), usable by setting a role's `provider_preferences` to `grok`. Not currently assigned to any producer seat — Grok's benchmarked strength here is judgment, not the frontend producer role K3 holds.

### Headless flag (QA-verified)

`GROK_HEADLESS_ARGS=(-p)` in `launch.sh` — confirmed against grok 0.2.103: `-p, --single <PROMPT>` runs a single-turn prompt, prints to stdout, and exits. Headless mode performs real file edits (verified), so guardrails matter here just as they do for the other vendors.

## Non-goals

Grok as orchestrator, CTO gate, or any critic paired with a producer. Those seats are trust-critical and harness-proven on Claude.
