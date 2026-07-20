---
id: git-ship
version: 2
scope: global
summary: Branch hygiene, commit, push, draft PR; no AI branding on commits/PRs; never force-push main.
max_lines: 100
---

# Git ship

## Shipping a task branch

- [ ] Work on the task branch from the plan (create or checkout; do not commit to `main` unless the task says so). [ev: docs/plan-file-format.md]
- [ ] Commit with a clear Conventional Commit message; push to `origin` with upstream. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.4]
- [ ] Open a draft PR when `gh` works; if not, note the create-PR URL in the handoff. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.4]

## Delivery face (fleet law — no model branding)

Commits and PRs represent **the product / fleet owner**, not the vendor model.

- [ ] **Never** put in commit messages, PR titles, or PR bodies: `Co-Authored-By:` AI/bot trailers, "Made by/with Claude|Kimi|Grok|GPT|…", "Generated with …", or robot emoji attribution footers. [ev: README.md]
- [ ] Vendor/model provenance stays in handoffs/logs only — not on the public PR face. [ev: docs/proposals/skills-evolution-SYNTHESIS.md §2.4]
- [ ] Use Conventional Commits (`feat:`, `fix:`, `docs:`, …) without bot trailers. [ev: README.md]

## Never

- [ ] Force-push `main` / `master`. [ev: config/guardrails.yaml]
- [ ] `git reset --hard origin/main` on a shared branch without task authority. [ev: config/guardrails.yaml]
- [ ] Invent remotes or clone URLs — use the repo you were given. [ev: docs/proposals/skills-evolution-BRIEF.md §2.5]
