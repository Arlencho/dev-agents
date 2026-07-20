# Kimi (Moonshot) Provider

Kimi K3 as a **producer** via the **Kimi Code CLI** — subscription login, **no API keys**. Currently the primary provider for `web-frontend` (the seat with direct benchmark evidence: K3 produced a production-grade single-file cinematic site, zero-dependency compliant, on the Black Aces test, 2026-07-19), with `claude` as its failover.

## How it runs

`providers/kimi/launch.sh` is invoked by `run-remote.sh` on the worker (selected by `AGENT_PROVIDER=kimi` from `provider_preferences` in `workers.yaml`). Because the Kimi CLI has no `--agent` equivalent, the launcher injects the role charter (`roles/<role>.md` body) at the top of the prompt, then runs:

```
kimi -p "<charter + task>" --output-format text
```

`-p` runs non-interactively with `--auto` permissions by default. Guardrails still apply — they're git hooks installed per-repo by `guardrails.sh`, vendor-agnostic.

## Setup (once per machine)

```bash
kimi login    # device-code OAuth against your Kimi for Coding subscription
kimi -p "say ok" --output-format text   # smoke test
```

No key export, nothing provisioned on the dispatcher. If `kimi` is missing or not logged in, the launcher exits 69 and dispatch **fails over to the next provider** in `routing.yaml provider_failover` (`web-frontend: [kimi, claude]`).

## Rate-cap behavior

If Kimi returns a cap/quota message (patterns in `config/ratecap-patterns.conf`), the launcher exits 75: `run-remote.sh` marks kimi cooling (`logs/provider-state/kimi.cooldown`, 60 min) and logs the event; `dispatch.sh` fails the task over to `claude` and notifies you. See `make scorecard`.

## Trial gate (before expanding K3 to other seats)

The **Frontend Critic stays on Opus** — this pairing is the fleet's first true cross-vendor producer-critic pair. K3's known unknown is edit stability across critic loops:
- Run 5–10 real frontend tasks; compare critic-block rate + loop convergence vs the Sonnet baseline in `learnings/`.
- If K3 can't converge within the 2-loop ceiling comparably, revert `web-frontend` to `claude` in `workers.yaml` and record the evidence.
- Do NOT expand K3 to other producer seats without seat-specific evidence.

## Model selection

`AGENT_MODEL` claude tier aliases (opus/sonnet/haiku) are ignored here — the launcher uses the CLI default model. Pass a Kimi-native model ID via `routing.yaml model_routing` only if you need to pin one.
