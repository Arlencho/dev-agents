# Handoff — Experience Console design proposal (Seat A)

## Built

- Wrote independent design proposal `docs/proposals/experience-console-proposal-claude.md` (619 lines).
- Product name: **Fleet Desk** (working name Experience Console retained in title).
- Sections: pitch, user journeys, dual-scope IA + ASCII wireframes + component inventory, data joins from existing artifacts, role usage + Playbook Maturity Band formula, UX craft, Phase 0 ship list, risks/non-goals/open questions, freeze fit, success mapping.
- Did **not** read or edit `experience-console-proposal-grok.md` or `experience-console-proposal-kimi.md`.
- No product UI code, scripts, or skills implemented (design markdown only).
- Committed `d6ae616` on `feat/proposal-experience-console-claude`, pushed to origin.

## Decisions

- **Name Fleet Desk:** "Console" implies control/mutation; Phase 0 is a read-only projection desk.
- **Architecture:** offline generator (`make desk` / `scripts/desk-build.sh`) → static `site/desk/` (gitignored); no daemon; complements `make evidence`.
- **Dual scope:** sticky Global | Company switcher; same components, different data roots; companies from `companies/*.md` only; unjoined waves under Unattributed; ad-hoc labels (e.g. black-aces) without fake company files.
- **Seniority:** Playbook Maturity Band with five-term formula (coverage, reliability, volume, critic proxy, versioning) - not agent IQ badges; low-n provisional asterisk.
- **Skills UI:** read-only; candidates visible; no promote/write (obeys skills-evolution SYNTHESIS).
- **Conductor:** first-class work source via `wave-plans/conductor/`; no session-mode control UI (session-modes SYNTHESIS).
- **Stack secondary:** Python stdlib + semantic HTML/CSS preferred for Phase 0 speed.

## Do not repeat

- `gh` is unauthenticated (HTTP 401 on `gh pr create`) - do not burn cycles retrying; use branch compare URL.
- Do not implement `desk-build.sh` or site in a proposal-only task - gated on SYNTHESIS.
- Do not open/merge other seats' proposal files for "alignment"; independence is the point.
- Do not invent company entries for black-aces; use ad-hoc project labels until owner decides.
- Prior root `handoff.md` may be leftover from another seat/task - overwrite expected for this task.

## Evidence

```bash
$ test -f docs/proposals/experience-console-BRIEF.md && echo OK
OK

$ test -f docs/proposals/skills-evolution-SYNTHESIS.md && test -f docs/proposals/session-modes-SYNTHESIS.md && echo OK
OK

$ ls companies/
aegis.md  olympus.md  rios-operator.md  safeplace.md  wearforrun.md

$ wc -l docs/proposals/experience-console-proposal-claude.md
     619 docs/proposals/experience-console-proposal-claude.md

$ git log --oneline -1
d6ae616 docs(proposals): Experience Console design proposal - Fleet Desk (seat A)

$ git push -u origin feat/proposal-experience-console-claude
   6d25842..d6ae616  feat/proposal-experience-console-claude -> feat/proposal-experience-console-claude

$ gh pr create --draft ...
HTTP 401: Requires authentication
```

Sources read (not other seat proposals): brief, skills-evolution-SYNTHESIS, session-modes-SYNTHESIS, session-modes.md, operator-guide Ground Truth/Evidence/handoff sections, skills/README + role-skills.yaml, companies/*.md, sample handoffs, wave-report header, proposals README.

## Open questions

- Site location: gitignored only vs committed snapshot under `docs/experience/`.
- black-aces → company manifest vs permanent ad-hoc label.
- Maturity weight tuning; product name freeze (Fleet Desk vs Experience Console).

## Next hint

- Owner: open draft PR via https://github.com/Arlencho/dev-agents/compare/main...feat/proposal-experience-console-claude?expand=1 after `gh auth login` (or browser).
- After three seats land: SYNTHESIS freeze before any `desk-build` implementation wave.
