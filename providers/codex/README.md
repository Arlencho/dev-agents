# Codex Provider

The Codex CLI (`codex`, subscription login via `codex login`, **no API keys**) as a **producer** failover seat. Owner decision 2026-09-25: every producer chain is now primary, the other non-Anthropic seat, then `codex`, then `claude` as the last resort. Codex holds no primary seat and no judgment seat.

## How it runs

`providers/codex/launch.sh` is invoked by `run-remote.sh` on the worker when dispatch resolves `AGENT_PROVIDER=codex` (a producer whose earlier providers are capped or unavailable). `codex exec` has no `--agent` equivalent, so the launcher injects the role charter (`roles/<role>.md` body) at the top of the prompt, then runs:

```
codex exec --dangerously-bypass-approvals-and-sandbox --color never -- "<charter + task>"
```

- **Permissions**: approvals off and no sandbox, inside the seat's own git worktree. The seat needs `git push`, `gh`, `npm` and the network, which the codex sandbox modes block or prompt for; this is the same level the claude launcher runs with (`--dangerously-skip-permissions`). Guardrails still apply: they are git hooks installed per repo by `guardrails.sh`, vendor-agnostic.
- **Stdin** is detached (`codex exec` appends piped stdin to the prompt; under run-remote that descriptor carries the dispatch script).
- **Output** is plain text through `run_and_classify`, so rate caps, auth failures and provider limits classify exactly like kimi and grok. Codex echoes the prompt back under a `user` line; the classifier drops every output line that appears verbatim in the prompt, so a charter or learning that quotes a cap message never misclassifies a run.
- **Model**: `AGENT_MODEL` claude tier aliases (opus/sonnet/haiku, claude-*) are ignored and the CLI default model is used. A codex-native model id is passed through as `-m`.

## Setup (once per machine)

```bash
codex login            # subscription login
codex login status     # prints the login state, exit 0 when logged in
./scripts/vendor-auth-check.sh --vendors codex --deep   # login status + headless AUTH_OK
```

If `codex` is missing or not logged in, the launcher exits 69 and dispatch **fails over to the next provider** in `routing.yaml provider_failover` (for producers that is `claude`).

## Rate-cap behavior

If codex returns a cap, quota, usage-limit, 429 or 402 message (`codex` rows in `config/ratecap-patterns.conf`), the launcher exits 75: `run-remote.sh` marks codex cooling (`logs/provider-state/codex.cooldown`, `cooldown_minutes` in routing.yaml) and logs the event; `dispatch.sh` fails the task over to the next provider. Auth messages (`not logged in`, `codex login`, 401, `unauthorized`, expired token) exit 69. A fast exit naming a spend or session limit is a provider limit (exit 78, hold and probe; see `scripts/provider-probe.sh`).

## Non-goals

Codex as a producer primary, a critic, plan-critic, security-reviewer, cto or orchestrator. It is the third rung of the producer chain only.
