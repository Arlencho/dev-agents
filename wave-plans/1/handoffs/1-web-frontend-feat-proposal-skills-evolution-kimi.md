# Handoff — Skills Evolution Proposal (Kimi Version)

## Built
- Created `docs/proposals/skills-evolution-proposal-kimi.md` (405 lines) covering every required section from the brief.
- Committed as `ce428d9` on branch `feat/proposal-skills-evolution-kimi` and pushed to `origin`.
- Proposed directory layout: `skills/global/` in `dev-agents`, `<product-repo>/skills/` for project scope, plus `config/role-skills.yaml` for role-to-skill mapping.
- Proposed runtime changes to `providers/kimi/launch.sh` and `providers/grok/launch.sh` to inject skill packs before the task prompt (Claude loads via existing `--agent` path or orchestrator prepend).
- Draft PR creation was attempted but failed because `gh` is not authenticated in this environment (`HTTP 401`).

## Decisions (+why)
- **Plain markdown skill packs with YAML frontmatter.** Matches existing role-charter format, works with the existing `strip_frontmatter` helper in `providers/lib.sh`, and is diff-reviewable in GitHub without new parsers.
- **Project skills override global skills.** Keeps ownership clear and avoids merge ambiguity; a project that diverges carries an explicit explanation.
- **Project-first promotion rule.** New rules must prove themselves in a project skill before graduating to global, preventing fleet-wide poisoning by one-off ideas.
- **Critic + human/CTO gate for global skills.** Global changes have fleet-wide blast radius, so they require adversarial review and a trusted merge authority.
- **No new daemon, no vendor-native skill sync.** The fleet already runs on bash + git; skills are just more repo files injected into prompts.
- **No `npm run build/lint/tsc` checks.** This task is a markdown design proposal in `dev-agents`, not a Next.js app change; the task's charter override explicitly removes the UI scope.

## Open questions
- What should the initial global starter pack set be? I proposed 6–8 packs but the owner may want a smaller seed.
- Should project skills live inside product repos under `skills/` or be inlined in `companies/<product>.md`?
- Can the `cto` agent approve global skill merges under delegation, or must a human always merge?
- Should `config/role-skills.yaml` pin exact skill versions or always follow `main`?
- How do we track skill effectiveness — a lightweight ledger or just git history + `learnings.sh stats`?
- `gh` CLI is unauthenticated here, so the draft PR must be created manually if the owner wants one.

## Do not repeat
- Do not invent new CLI flags or auth paths in skill content; the brief explicitly flags this as a poisoning vector.
- Do not attempt to edit `skills-evolution-proposal-claude.md` or `skills-evolution-proposal-grok.md`; each vendor writes its own file.
- Do not implement product UI or app code for this task; it is design-only.

## Evidence
```bash
$ git log --oneline -1
ce428d9 docs(proposals): skills evolution design - Kimi version

$ git diff --stat main...HEAD
 docs/proposals/skills-evolution-proposal-kimi.md | 405 ++++++++++++++++++++++
 1 file changed, 405 insertions(+)

$ git push -u origin feat/proposal-skills-evolution-kimi
 * [new branch]      feat/proposal-skills-evolution-kimi -> feat/proposal-skills-evolution-kimi
```

Draft PR attempt:
```bash
$ gh pr create --draft -R Arlencho/dev-agents ...
HTTP 401: Requires authentication (https://api.github.com/graphql)
Try authenticating with: gh auth login
```

## Next hint
- The critic should focus on whether the proposed `skills/global/` layout and `config/role-skills.yaml` mapping integrate cleanly with the existing `providers/*/launch.sh` injection model, and whether the project-first / global-gate promotion rule is strong enough to prevent skill poisoning.
