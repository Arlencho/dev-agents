# Handoff — session modes proposal (Claude seat)

**Task:** design proposal for Conductor / Wave / Auto session modes (docs-writer, `feat/proposal-session-modes-claude`)
**Date:** 2026-07-23

## Built

- `docs/proposals/session-modes-proposal-claude.md` (362 lines) — all 15 required sections from `session-modes-BRIEF.md` §6: executive summary, mode contracts (with Wave sub-states), activation & persistence, Auto decision table + thrash prevention, Conductor runtime path, Wave runtime path, role routing, task-packet template with the ABarranges worked example, L1/L2/L3 integration, learnings policy, phased rollout, success metrics, failure modes, non-goals, owner open questions.
- Nothing else changed: no code, no launchers, no skills, no config. Grok/kimi proposal files untouched.

## Decisions

- **Mode = state, not skill.** Contract text in a future `docs/session-modes.md`; current mode in `logs/session-mode/<product>.mode` (mirrors `logs/provider-state/` precedent); inject via one new L2 pack mapped to `orchestrator` — ships through a normal human-merged skill PR, so the skills-evolution freeze is untouched.
- **No new role file.** Conductor is a mode of the orchestrator seat (`roles/orchestrator.md` gains a slice), keeping "one contract, multi inject" (brief R11).
- **Human gates everywhere in MVP.** Conductor proposes + waits for "go"; Wave arms + waits for "trigger"; Auto only selects, never adds autonomy. "Auto single-seat when confidence high" deferred to Phase C, off by default.
- **Anti-thrash:** Auto locks per pin; at most one gear change per pin; upgrades only (chat→conductor→wave), proposed not silently taken; fixed grep-able announce format.
- **Default Auto** accepted (strawman), with product override proposed as `default_session_mode:` frontmatter in `companies/*.md` (marked speculative).
- **Single-seat dispatch** prefers a 1-line plan through existing `dispatch.sh` (inherits failover/logging/handoffs); local launcher (`providers/<vendor>/launch.sh <role> <task>`) as quick fallback. No new orchestration product.
- Commit/PR face follows fleet law (`skills/git-ship` v2): no AI branding, no bot trailers.

## Do not repeat

- `git commit <pathspec>` fails for untracked files — `git add` the file first, then `git commit --only <path>` (needed here because dispatch had pre-staged `wave-plans/dev-agents-20260723.plan`, which must NOT ride along in this commit; it remains staged and uncommitted).
- Don't renumber sections by folding one into another; the brief's 15-section list is checked literally. First draft had a "§4 folded into §5" hack — fixed with a full renumber + cross-ref sweep before commit.
- Don't add the standard Co-Authored-By/Generated-with footers in this repo — the commit-msg guardrail and git-ship pack ban them.

## Evidence

- File exists: `docs/proposals/session-modes-proposal-claude.md`; heading check shows all 15 `## N.` sections (grep `^## ` → 15 headings, 1–15 in order).
- Commit: `5a6303d` — "docs(proposals): session modes design proposal (Claude seat)", 1 file, 362 insertions.
- Push: `origin/feat/proposal-session-modes-claude` created, upstream set.
- Draft PR: `gh pr create --draft` succeeded → https://github.com/Arlencho/dev-agents/pull/33
- Other proposals untouched: `git status` shows `session-modes-proposal-grok.md` / `-kimi.md` still untracked and unmodified.
- Grounding reads: README.md, `config/workers.yaml`, `config/routing.yaml`, `docs/plan-file-format.md`, `roles/orchestrator.md`, `docs/proposals/skills-evolution-SYNTHESIS.md`, `scripts/preamble.sh`, `scripts/learnings.sh`, `skills/handoff-intent`, `skills/git-ship`.

## Open questions / Next hint

- Owner open questions are in proposal §15 (mode-file scope, packet storage location, conductor verification depth, bounce ceiling, etc.).
- Next step after all three seats land: owner synthesis (same pattern as `skills-evolution-SYNTHESIS.md`).
- This handoff is intentionally left uncommitted at repo root so PR #33 stays single-file; prior waves collect handoffs under `wave-plans/<n>/handoffs/`.
