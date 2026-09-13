# Grok Provider

xAI Grok via the **Grok Build CLI**: subscription login (`grok login`), **no API keys**. Grok holds the `plan-critic` and `devops-critic` judgment seats and, under the routing trial (owner decision 2026-09-13), every producer seat except `web-frontend`. Trust-critical seats (orchestrator, cto, security-reviewer, the discipline critic primaries) stay first-party.

## Plan Critic (active)

`plan-critic.sh`: one-shot adversarial review of a wave plan, run automatically as **Pass 4 (Cross-vendor)** of `scripts/autoplan.sh`. Charter: `roles/plan-critic.md`. Rationale: the plan is the highest-leverage artifact in the pipeline (a bad plan poisons every downstream agent), and the three Claude passes share one vendor's blind spots.

It calls `providers/grok/launch.sh plan-critic "<plan>"` (which injects the charter and runs the headless Grok CLI). Same `VERDICT: APPROVE|REVISE|REJECT` grammar as the Claude passes, so autoplan's summary/gate logic is unchanged.

```bash
grok login    # once, against SuperGrok / X Premium+

# standalone
./providers/grok/plan-critic.sh wave-plans/my-plan.txt

# as part of dispatch (runs automatically when grok is installed)
./scripts/dispatch.sh <repo-url> plan.txt --review
```

- **Degradation**: grok not installed / not logged in → pass skipped (exit 3); rate-capped → cooldown recorded, pass skipped; any error → warn and continue. The cross-vendor pass adds signal; it must never block dispatch on a third-party outage.

## Producer seats (routing trial, owner decision 2026-09-13)

`providers/grok/launch.sh` is a full producer launcher (charter injection + rate-cap classification). Under the trial it is the primary for every producer seat except `web-frontend`: `go-backend`, `db-architect`, `api-designer`, `devops`, `test-engineer`, `mobile`, `investigate` and `docs-writer` (`workers.yaml provider_preferences`). Producer failover chains list only grok and kimi, so a producer never falls back to the first-party seat.

- **Assignment**: grok primary, kimi failover (`web-frontend` keeps the reverse order: kimi primary, grok failover). Why: first-party seats hit the subscription spend limit on 2026-09-13 and killed every seat for three hours; producers are the larger share of that spend and the critics are where the quality lives.
- **Trial length**: five tasks per producer seat.
- **Metric**: rounds to SAFE per task, counted against the Kimi and Claude baselines in [`wave-plans/ab-metrics.csv`](../../wave-plans/ab-metrics.csv).
- **Exit rule**: a producer whose median rounds to SAFE exceed the baseline by one goes back to its previous seat.

### Headless flag (QA-verified)

`GROK_HEADLESS_ARGS=(-p)` in `launch.sh`: confirmed against grok 0.2.103: `-p, --single <PROMPT>` runs a single-turn prompt, prints to stdout, and exits. Headless mode performs real file edits (verified), so guardrails matter here just as they do for the other vendors.

## Non-goals

Grok as orchestrator, CTO gate, or security-reviewer. Those seats are trust-critical and harness-proven on the first-party stack, and they carry no failover entry that would route them here. The discipline critics keep their first-party primary and reach grok only as failover.
