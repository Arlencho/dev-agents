# Grok Provider

xAI Grok integration. Deliberately minimal: Grok holds **one-shot judgment seats** (no tool harness, no agentic loop), where cross-vendor decorrelation adds signal without handing a vendor with no proven harness integration the keys to anything.

## Plan Critic (active)

`plan-critic.sh` — one-shot adversarial review of a wave plan, run automatically as **Pass 4 (Cross-vendor)** of `scripts/autoplan.sh`. Charter: `roles/plan-critic.md`. Rationale: the plan is the highest-leverage artifact in the pipeline (a bad plan poisons every downstream agent), and the three Claude passes share one vendor's blind spots.

```bash
# standalone
XAI_API_KEY=... ./providers/grok/plan-critic.sh wave-plans/my-plan.txt

# as part of dispatch (runs automatically when the key is set)
XAI_API_KEY=... ./scripts/dispatch.sh <repo-url> plan.txt --review
```

- **Env**: `XAI_API_KEY` (required; https://console.x.ai), `GROK_MODEL` (default `grok-4.3`), `GROK_ENDPOINT` (default `https://api.x.ai/v1/chat/completions`), `GROK_DRY_RUN` (print request, don't call).
- **Degradation**: no key → pass skipped with a notice; API failure → warning, dispatch continues. The cross-vendor pass adds signal; it must never make dispatch depend on a third-party outage.
- **Contract**: output ends with `VERDICT: APPROVE | REVISE | REJECT` — same grammar as the Claude passes, so autoplan's summary/gate logic is unchanged.

## Candidate second seat (not built)

Security second-pass: one-shot re-review of PRs already approved by the Opus security reviewer. Build only if the plan-critic seat proves out in `learnings/`.

## Non-goals

Grok as orchestrator, CTO gate, or any producer role. Those seats are trust-critical and harness-proven on Claude; a vendor swap there trades a quota irritation for an integration downgrade.
