# Kimi (Moonshot) Provider

Kimi K3 as a **producer** — starting with `web-frontend`, the seat where we have direct benchmark evidence (K3 produced a production-grade single-file cinematic site, zero-dependency compliant, on the Black Aces test, 2026-07-19).

## Integration path: Claude Code harness, Moonshot endpoint

Moonshot's coding service exposes an **Anthropic-compatible** API, so K3 runs inside the *same* Claude Code harness as every other agent — same role charters, same guardrails, same logs. No second CLI, no new adapter surface.

`scripts/run-remote.sh` triggers this automatically for any routed model matching `kimi*`/`k3*`:

```
ANTHROPIC_BASE_URL=https://api.kimi.com/coding  ANTHROPIC_AUTH_TOKEN=$KIMI_API_KEY  claude --agent web-frontend --model kimi-k3 ...
```

### Enable the trial

1. Get a key from https://www.kimi.com (Kimi Coding / API console) and `export KIMI_API_KEY=...` on the **dispatching** machine (the key rides the ssh heredoc; workers need nothing).
2. In `config/routing.yaml`, uncomment `web-frontend: kimi-k3` and comment the sonnet line.
3. Verify the model ID before first dispatch — Moonshot's public IDs shift (`kimi-k3`, `k3`, 1M-context variants). Check with:
   ```bash
   curl -s https://api.kimi.com/coding/v1/models -H "Authorization: Bearer $KIMI_API_KEY" | jq -r '.data[].id'
   ```
   If the ID differs, use the exact ID in routing.yaml (the `kimi*`/`k3*` prefix match in run-remote.sh covers both spellings). Override the endpoint with `KIMI_BASE_URL` if Moonshot moves it.

### Revert

Flip the two routing.yaml lines back. Nothing else changes.

## Trial protocol (gate before expanding)

The invariant that matters: **Frontend Critic stays on Opus** — this pairing is the fleet's first true cross-vendor producer-critic pair, strictly stronger decorrelation than tier-only heterogeneity. K3's known unknown is edit stability across critic loops, so:

- Run K3 on 5–10 real frontend tasks; compare critic-block rate and loop-convergence vs the Sonnet baseline in `learnings/`.
- If K3 can't converge within the 2-loop ceiling at a rate comparable to Sonnet, demote it (revert routing) and record the evidence.
- Do NOT expand K3 to other producer seats (go-backend etc.) without seat-specific evidence.

## Alternative path (not used): Kimi CLI

Moonshot ships its own CLI (`kimi --yolo` for headless auto-approve). Rejected for now: it would bypass the Claude Code guardrails hooks and role-charter loading that run-remote.sh assumes. Revisit only if the Anthropic-compatible endpoint proves limiting.
