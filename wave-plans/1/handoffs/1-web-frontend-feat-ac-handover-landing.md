# Handoff: critic B1 fix on feat/ac-handover-landing (PR #2844)

## Built

- `apps/web/lib/chat-step-machine/project-snapshot.ts` - `skipUnansweredBudgetLanding` now renumbers the thread (`msg-${i}`) after filtering out the budget ask and resets `messageIdCounter` to the filtered length, so the appended confirmSearch ask and every later in-page message get collision-free ids. Also restored the missing EOF newline (critic N4).
- `apps/web/lib/chat-step-machine/project-snapshot.test.ts` - added the critic's pin test: after the budget skip, thread ids are unique and `hydrate(snap).messageIdCounter` exceeds the max id number on the thread. Red without the fix (1 failed / 28 passed with the source stashed), green with it.
- `apps/web/components/chat/chat-step-renderer-helpers.ts` - un-collapsed `flightSelectionId` onto multiple lines (critic N4).
- PR #2844 body gained a `## Round 2` section with real commands and exit codes. Pushed as 88a5cae3.

## Decisions (+why)

- Chose renumbering over the critic's other option (reuse the removed ask's id): renumbering restores the exact invariant `hydrate` assumes (`messageIdCounter === thread.length`, ids `msg-0..length-1`), instead of a one-off hole-patch that still leaves ids non-contiguous.
- Did NOT run `prettier --write` on the touched files: prettier also wants to collapse pre-existing branch style (multi-line imports, multi-line expects) that predates this PR and is not CI-enforced; only the regions this PR touched were brought to prettier's preferred form manually.
- No issue label changes: task scope was the code fix + PR body; #2842 stays linked via the existing `Closes #2842`.

## Do not repeat

- `npx vitest` before `npm ci` resolves to a global npx cache and fails with MODULE_NOT_FOUND on the vite config; run `npm ci --workspace apps/web --include-workspace-root` first (exit 0, ~4s).
- Makefile has no `lint-web` / `typecheck-web` target; the web equivalents are `cd apps/web && npm run lint` / `npm run typecheck`. `make test-web` exists and runs the full vitest suite.

## Evidence

- `make test-web`: Test Files 333 passed (333), Tests 4686 passed (4686), exit 0 (one more test than the critic's 4685 - the new pin).
- `cd apps/web && npm run lint` (eslint --max-warnings 0): exit 0.
- `cd apps/web && npm run typecheck` (tsc --noEmit): exit 0.
- Pin check: `git stash push -- project-snapshot.ts` then vitest on the test file - 1 failed / 28 passed; `git stash pop` - 29 passed.
- Head after push: 88a5cae3 on origin/feat/ac-handover-landing.

## Next hint

Critic round 2 should confirm B1 is gone (no duplicate `msg-8` key on the F3 click path) and can then re-review the advisory items N1-N3, none of which this commit touched. N3's follow-on (sign-in-first supersedes the amendment sentence) belongs to the identity PR, not this one.
