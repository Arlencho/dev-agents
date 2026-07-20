# Handoff — Skills evolution proposal (Grok seat)

## Built
- Wrote independent design proposal: `docs/proposals/skills-evolution-proposal-grok.md`
- Covers all 12 required brief sections: executive summary, basic skills catalog, runtime model (claude/kimi/grok), experience capture, promotion/evolution, global vs project, trust/safety, retros at scale, phased rollout, success metrics, non-goals, open questions
- Plus appendices: implementation sketch touch-list, relation to parked handoff-brain phases, opinionated Grok positions

## Decisions (+why)
- **Fleet L2 skills live in git** (`dev-agents/skills/` + product `skills/`), not vendor-native dirs (`~/.grok/skills`, Claude marketplace). Multi-vendor SSH workers only share what git ships.
- **Injection via launchers + run-remote**, not folded into `preamble.sh` — keep L2 playbooks separate from L3 case/session noise.
- **Promotion is PR + human gate for global**; automation may only write `skills/_candidates/` or open PRs. Learns from Phase-1 handoff kill criterion: no unsupervised auto-brain.
- **Handoffs/learnings are raw fuel**, never auto-truth for skill bodies; frequency + evidence path checks required.
- **Project pack id overrides global body** (replace, not deep-merge) for predictability.
- **Starter catalog ≤12 shared/discipline packs**, not one novel per role.
- Did **not** read Claude/Kimi proposal files (independence per brief).

## Open questions
- Owner must freeze project skill path (`skills/` recommended), Claude inject preference, global merge policy — listed in proposal §12.

## Do not repeat
- Do not claim auto-promotion already exists.
- Do not invent CLI flags/auth paths; ground in `providers/*/launch.sh`, `preamble.sh`, `learnings.sh`, `run-remote.sh`.
- Do not edit `skills-evolution-proposal-claude.md` or `skills-evolution-proposal-kimi.md`.
- Do not implement launcher/skill code in this proposal wave.

## Evidence
```bash
$ test -f docs/proposals/skills-evolution-proposal-grok.md && rg -n '^## ' docs/proposals/skills-evolution-proposal-grok.md
# sections 1–12 present (+ appendices)

$ test -f scripts/learnings.sh && test -f scripts/preamble.sh && test -f providers/grok/launch.sh
# core runtime paths referenced in proposal exist
```

## Next hint
- Synthesis reviewer: compare three vendor proposals; watch for (a) auto-merge of skills from handoffs, (b) vendor-native skill SoT, (c) missing kill criterion, (d) preamble soup vs separate L2 inject.
