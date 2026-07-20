---
id: handoff-intent
version: 1
scope: global
summary: Write handoff.md at repo root before exit so the next seat has intent + evidence.
max_lines: 90
---

# Handoff intent

## Before exit (success path)

Write `handoff.md` at the **repo root** with:

- [ ] `## Built` — what changed (files/behaviors). [ev: docs/proposals/skills-evolution-BRIEF.md §2.3]
- [ ] `## Decisions` — choices and why. [ev: docs/proposals/skills-evolution-BRIEF.md §2.3]
- [ ] `## Do not repeat` — dead ends for the next agent. [ev: docs/proposals/skills-evolution-BRIEF.md §2.3]
- [ ] `## Evidence` — commands + results (or SHAs). [ev: docs/proposals/skills-evolution-BRIEF.md §2.3]
- [ ] `## Open questions` / `## Next hint` when useful. [ev: docs/proposals/skills-evolution-BRIEF.md §2.3]

## Notes

- Orchestrator records mechanical git fields; you own **intent**. [ev: docs/proposals/skills-evolution-BRIEF.md §2.4]
- Do not put secrets in handoffs. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.5]
