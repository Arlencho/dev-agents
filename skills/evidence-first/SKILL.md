---
id: evidence-first
version: 1
scope: global
summary: Prefer command+result over prose; never invent paths or CLI flags.
max_lines: 80
---

# Evidence-first

## Before claiming a path, flag, or infra fact

- [ ] Confirm the path exists with `test -f` / `ls` / Read — do not invent absolute paths. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- [ ] Confirm CLI flags with `--help` or by grepping this repo's scripts — do not invent flags. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- [ ] Prefer pasting a short command + result in handoffs over narrative claims. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.5]

## Anti-patterns

- Stating auth/credential file locations from memory (e.g. inventing Codeium or Keychain paths). [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
- “Should exist on the worker” without checking. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
