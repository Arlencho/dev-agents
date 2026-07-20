---
id: docs-no-hallucinate
version: 1
scope: global
summary: Docs seats must not invent infra paths, auth locations, or CLI flags.
max_lines: 90
---

# Docs — no confabulation

## Before writing any operational fact

- [ ] Every absolute path or auth location must be verified with Read/grep in-repo or on the machine — never invent (e.g. Codeium, Keychain, credential JSON paths). [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- [ ] Every CLI flag named in docs must appear in `--help` or in `scripts/` / `providers/` sources. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- [ ] Prefer linking to existing files (`docs/…`, `scripts/…`) over restating procedure from memory. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.5]

## Anti-patterns

- Documenting “standard” install paths without checking this fleet. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- Claiming a multi-vendor feature exists without grepping launchers. [ev: docs/proposals/skills-evolution-BRIEF.md §2.1]
