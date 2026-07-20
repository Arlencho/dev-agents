---
id: git-ship
version: 1
scope: global
summary: Branch hygiene, commit, push, draft PR; never force-push main.
max_lines: 90
---

# Git ship

## Shipping a task branch

- [ ] Work on the task branch from the plan (create or checkout; do not commit to `main` unless the task says so). [ev: docs/plan-file-format.md]
- [ ] Commit with a clear message; push to `origin` with upstream. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.4]
- [ ] Open a draft PR when `gh` works; if not, note the create-PR URL in the handoff. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.4]

## Never

- [ ] Force-push `main` / `master`. [ev: config/guardrails.yaml]
- [ ] `git reset --hard origin/main` on a shared branch without task authority. [ev: config/guardrails.yaml]
- [ ] Invent remotes or clone URLs — use the repo you were given. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
