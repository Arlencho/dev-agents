# Retro — 2026-04-17 Anthropic Ecosystem Alignment

**Trigger:** Periodic check on whether the dev-agents harness is still keeping up with the Anthropic / Claude Code ecosystem. Last material architectural change was the specialist-reviewer + retro agent work (Mar 2026).

**Scope of this round:** Research-only audit followed by a Tier 1 surgical update. No rewrites.

**Outcome:** PR #20 (`feat: v2 — Anthropic ecosystem alignment`) merged to `main` as `7a12bae`. Four commits, revertable individually.

---

## What we researched

Current (as of April 2026) capabilities from the Anthropic ecosystem and adjacent industry, filtered against our harness design.

### Anthropic / Claude Code features worth knowing

| Capability | Shipped | Relevance to us |
|---|---|---|
| Claude Code subagents with YAML frontmatter + `isolation: worktree` | Stable, v2.1.49 (Feb 2026) | Native in-process equivalent of our role-per-agent + branch-per-task model. Our role files are one `model:` field away from being dual-use. |
| Claude Agent SDK (renamed from Claude Code SDK, Sept 2025) | GA | Alternative substrate for our harness — but rewriting `run-remote.sh` to use the SDK wins nothing when each worker already runs `claude` locally. |
| Hooks (PreToolUse / PostToolUse / Stop / 9 others) | Stable | Drop-in replacement for `guardrails.sh` regex scanning. Blocks before execution with exit code 2, not after-the-fact log scanning. |
| Plugins + Skills + Slash commands | GA since late-2025 | Our `roles/` + `scripts/` + `config/` is effectively a plugin in disguise. Could be packaged for reuse across other orgs. |
| MCP servers | Stable | One shared MCP memory server would let agents coordinate within a wave without funneling state through commit messages. |
| Prompt caching (5-min + 1-hour TTL, 10% read cost) | Stable | `preamble.sh` output is the perfect cache target — stable, injected every session. Needs refactoring how we deliver it. |
| Scheduled tasks / Cloud Routines | Launched Apr 14, 2026 | Not useful for owned Mac Mini fleet, but relevant if we ever shift to cloud-hosted runs. |
| Three-tier model routing (Opus / Sonnet / Haiku) | Available for all users | Published 51% cost reduction reference. Directly applicable. |

### Industry patterns we checked

- **LangGraph** has become the production-grade durable-state choice. Our wave-plan format is a flattened DAG — migrating would be rewriting what already works.
- **CrewAI** is the role-based framework closest to our model. Worth monitoring as a dual-track option if Claude-only becomes a constraint.
- **AutoGen** entered maintenance mode in favor of Microsoft Agent Framework — avoid new investments.
- **Temporal / Inngest / Vercel Workflow DevKit** provide durable workflow primitives. Overkill for our fleet size.
- **AGENTS.md** (agentsmd.org) is the emerging cross-tool repo-guidance standard (Copilot / Cursor / Jules / Aider all read it). Complements, doesn't replace, our role definitions.

---

## What landed in v2 (PR #20)

1. **Per-role model tier routing** in `config/routing.yaml` → `model_routing:`
2. **Dispatch pipeline threaded** — `dispatch.sh` and `run-remote.sh` now pass `--model <tier>` to the remote `claude` invocation
3. **Dual-use role files** — all 26 `roles/*.md` now carry a `model:` field in YAML frontmatter, consumable as native Claude Code subagents
4. **Exec log includes model column** so `retro` can analyze cost/quality per tier

### Tier assignments

- **opus** (7 roles): strategic / judgment-heavy work — orchestrator, plan-reviewer, red-team-reviewer, retro, security-reviewer, production-auditor, investigate
- **sonnet** (17 roles): default for implementation and routine review
- **haiku** (2 roles): docs-writer, seo-auditor

### Why tier aliases, not pinned IDs

`opus` / `sonnet` / `haiku` resolve to the current version automatically. Pin exact IDs (`claude-opus-4-7`, etc.) only when you need reproducibility — migration tests, regression bisects, published benchmark runs. This is in the `routing.yaml` comments but worth repeating: the churn cost of hard-coding versions was visible immediately (Opus 4.6 → 4.7 shipped the same week we did this work).

---

## What we kept deliberately (do-not-rewrite list)

- **SSH-to-Mac-Mini dispatch.** Claude Code has no native cross-machine scheduler; Remote Control (Feb 2026) is UX, not a fleet orchestrator. For owned hardware avoiding cloud spend, SSH is still correct.
- **Bash dispatcher.** Rewriting via Agent SDK buys nothing when each worker already runs `claude` locally. Complexity up, workflow unchanged.
- **Wave-plan pipe-delimited format.** Human-readable flattened DAG. Works. Don't touch.
- **Learnings + retro system.** Few frameworks do this well. Keep.
- **Branch-per-task + preamble injection.** Both align with `isolation: worktree` and emerging conventions. No change needed.

---

## Deferred follow-ups (tracked in README)

These surfaced in research but were out of scope for the Tier 1 cut:

1. **Preamble prompt caching** — needs refactoring how context is delivered to `claude`. Currently the preamble is concatenated into the user prompt, which Claude Code does *not* auto-cache. System prompt and `CLAUDE.md` *are* auto-cached. The fix is non-trivial without moving to SDK-based invocation.
2. **Replace `guardrails.sh` regex scanning with `PreToolUse` hooks** — deterministic pre-execution blocking instead of post-hoc log scan. Keep the shell-level hook as a second safety layer.
3. **Idempotency keys on retries** in `dispatch.sh` — prevent double-commits / double-notifies when a task is retried.
4. **MCP memory server** for cross-agent state within a wave — stop passing state through commit messages.
5. **OpenTelemetry / tracing export** from `run-remote.sh` — per-task traces, cost attribution, eval replay. Worth it if fleet grows beyond 2 workers.

---

## Primary sources

All accessed April 2026. Dates are publication / last-update dates.

- [Anthropic — How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) (2025, updated 2026)
- [Anthropic — When to use multi-agent systems (and when not to)](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) (2026-01-23)
- [Anthropic — Building agents with the Claude Agent SDK](https://claude.com/blog/building-agents-with-the-claude-agent-sdk) (2025)
- [Claude Code — Subagents docs](https://code.claude.com/docs/en/sub-agents) (stable, v2.1.49 worktree support 2026-02-19)
- [Claude Code — Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Claude Code — Hooks reference](https://code.claude.com/docs/en/hooks)
- [Claude Code — Plugins](https://code.claude.com/docs/en/plugins) (GA after 2025-10 beta)
- [Claude Code — Scheduled tasks / Routines](https://code.claude.com/docs/en/scheduled-tasks) (launched 2026-04-14)
- [Claude Code — MCP integration](https://code.claude.com/docs/en/mcp)
- [Anthropic API — Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [Anthropic API — Pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Anthropic — 2026 Agentic Coding Trends Report](https://resources.anthropic.com/2026-agentic-coding-trends-report)
- [Anthropic — Building Effective AI Agents resource hub](https://resources.anthropic.com/building-effective-ai-agents)
- [AGENTS.md — open standard](https://agents.md/)
- [GitHub Blog — How to write a great agents.md](https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/) (2026)

---

## Files changed (PR #20 → main @ `7a12bae`)

- `config/routing.yaml` — added `model_routing:` block
- `scripts/dispatch.sh` — added `get_model()` + threaded tier through dispatch + exec log column
- `scripts/run-remote.sh` — accepts `AGENT_MODEL` env var or `--model` flag, forwards to remote `claude`
- `roles/*.md` — all 26 files gained `model:` frontmatter field
- `README.md` — v2 changelog + revert paths
