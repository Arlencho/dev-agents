# Handoff: feat/ac-handover-landing

## Built

- `docs/prd/pages/06-conversation-results.md`, one commit `060e4f34` on `feat/ac-handover-landing` (branched from `origin/main` at `c90a2978`), pushed.
- Section 4: dated blockquote after the entry-points table. Direct URL rows: a record with a non-empty `result_snapshot` lands on the results picker and never asks an unanswered optional step such as budget. Cross-references section 13.1 (record), 6.6 (picker), 6.13.0 (step machine), `assistant-channel.md` 3.2 (web_url handover), 13.3.1 (sign-in at Book, referenced only).
- Section 6.6.5: dated blockquote after the click-behaviour table. Third Highlighted trigger: the record's `selected_offer_id` when present in `result_snapshot`; identical rendering to the two existing triggers; an id absent from the snapshot lands on the picker with nothing selected.
- Section 6.6.4 Highlighted row: the parenthetical trigger list names the third trigger and points at 6.6.5. The pre-existing em dash in that row's right cell became a colon, because the line was being rewritten and house style forbids long dashes on any written line.

## Decisions

- The Highlighted trigger list physically lives in the 6.6.4 card-states table; the ratification names 6.6.5. Amended both so they cannot disagree, with the full rule in 6.6.5 as instructed and a one-clause pointer in 6.6.4.
- Section 4 rule is written as a blockquote covering all Direct URL rows rather than editing the "own session" row, because the assistant-channel case (issue 2842) is an unsigned browser, which the "own session" row (logged-in user) does not describe.
- Kept to the ratification text: no right-panel summary sentence (that appears in issue 2842 but not in the ratification comment), no new traveller-facing copy.
- Section 13.3 untouched. No `Co-Authored-By` trailer (task, OLY-4, house rule).

## Do not repeat

- `grep -c $'—\|–'` in zsh returns 0 on a file full of em dashes; `\|` inside `$'...'` is not alternation. Use `grep -E $'—|–|―'`.
- `scripts/voice-lint.sh` scans only `apps/` by default; to lint a PRD page pass `VOICE_LINT_FILES=<list file>`.

## Evidence

- `make check-prd-index` exit 0 (32 pages, 18 self-test PASS), run before and after the edit.
- `VOICE_LINT_FILES=/tmp/vl-files.txt bash scripts/voice-lint.sh` exit 0 on the page.
- `git diff -U0 | grep '^+' | grep -cE $'—|–|―| -- '` = 0 on the final diff.
- Commit message scan for `co-authored|claude|anthropic|dashes` = 0.
- `git ls-remote origin refs/heads/feat/ac-handover-landing` = `060e4f3419fc4dd9aeb51dcccabe5cb9698bd4c1` = local HEAD.

## Next hint

- Open the PR with the standard template; tick the PRD line in the docs checklist. Web-frontend implementation of the rule lives in `apps/web/lib/chat-step-machine/project-snapshot.ts` (`buildRehydratedResultsSnapshot`) and `apps/web/app/r/[id]/atlas-result-session-page.tsx` per issue 2842; that is out of devops scope and was not touched.
