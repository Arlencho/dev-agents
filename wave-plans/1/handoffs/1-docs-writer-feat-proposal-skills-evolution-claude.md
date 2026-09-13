# Handoff — Skills evolution proposal (Claude seat)

## Built
- `docs/proposals/skills-evolution-proposal-claude.md` — complete design proposal per `docs/proposals/skills-evolution-BRIEF.md`. All 12 required sections present: executive summary, basic skills catalog, runtime load model (claude/kimi/grok), experience capture, promotion/evolution, global vs project split, trust & safety, retros at scale, phased rollout, success metrics, non-goals, open questions.
- No product code, no launcher changes, no edits to other vendors' proposal files, no OpenAPI/spec/infra touches.

## Decisions (+why)
- **Preamble injection as the vendor-neutral runtime** — `scripts/preamble.sh` already assembles charter-adjacent context for all three CLIs; one code path beats syncing three vendor-native skill dirs. Vendor-dir sync explicitly marked speculation/deferred.
- **10 shared packs, not per-role sets** — brief §6 demands few-and-shared; packs seeded only from documented failures (plan `|` bugs, critic branch checkout, Keychain/SSH, docs confabulation) so day-one content is evidence-backed.
- **Reuse `learnings.sh`/handoffs for capture** — added only a `promote` verb + `--pack` tag as proposed extensions to our own script (no invented vendor flags). Candidate queue is a JSONL filter, not a new store.
- **Retro role is sole skill-diff author; global merges are human-only** — matches brief's "human or critic gate before global skill changes" and blast-radius logic.
- **Per-bullet `[ev:]` citations + proposed `skills-lint.sh`** — directly targets brief §2.5 poison/confabulation failure mode; command flags must be greppable in repo scripts.
- Grounded facts by reading `scripts/learnings.sh`, `scripts/preamble.sh`, and listing `roles/`, `config/`, `scripts/`, `learnings/`, `providers/` before writing.

## Open questions
- Seven owner questions listed in proposal §12 (skills-critic seat vs plan-critic reuse, pilot repo, retro cadence, demotion window, learning IDs, preamble budget, private-learning citability in global evidence).

## Do not repeat
- Do not edit `skills-evolution-proposal-grok.md` / `-kimi*.md` or the BRIEF.
- Do not claim the auto-evolution loop exists — it does not; proposal is design-only.
- `gh` is not installed on this host (`command not found`) — do not assume PR automation works here.

## Evidence
```bash
$ git log --oneline -1
5a12ece docs(proposals): skills evolution proposal — claude seat

$ git push -u origin feat/proposal-skills-evolution-claude
 * [new branch]  feat/proposal-skills-evolution-claude -> feat/proposal-skills-evolution-claude
```
- Draft PR **not** created: `gh` binary unavailable on this host (exit 127). GitHub offered the create-PR URL on push:
  `https://github.com/Arlencho/dev-agents/pull/new/feat/proposal-skills-evolution-claude`

## Next hint
- Human (or a gh-equipped seat) should open the draft PR from the URL above; then compare against the grok/kimi proposals per brief §5, mirroring the multi-vendor context transparency review flow.
