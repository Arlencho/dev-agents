# Handoff: ac-handover-identity web wave, stopped

## Built

Nothing in code. The task was the web-frontend wave of #2340 on `feat/ac-handover-identity` (PR #2845): sign-in modal on 401, clone-and-redirect on 403 `not_owner`, in-place hydration on 200, S19 line gated on build-time acceptance. It was not implemented because its stated precondition failed. What was done:

- Verified the branch `feat/ac-handover-identity` is already based on the `origin/main` tip (`c90a2978`), so the requested rebase was a no-op and nothing was pushed.
- Reported BLOCKED ON 2842 at the top of the PR #2845 body, with the evidence commands and results. The rest of the PR body (backend waves 1 to 4, all verified) is unchanged below the block.

## Decisions (+why)

- Stopped instead of implementing. The task explicitly said the #2842 fix (budget never re-asked, chosen offer selected on landing) must be on main, and if not, stop and do not reimplement it. The fix lives in PR #2844 (`feat/ac-handover-landing`), which is OPEN with `mergedAt: null`; nothing on main reads `selected_offer_id` and `buildRehydratedResultsSnapshot` on main still falls back to the budget question for committed records without a budget.
- Did not stack this branch on `feat/ac-handover-landing` either: the task says the fix must be on main, and stacking would smuggle the 2842 implementation into this wave's diff, which the task forbids.
- Wrote the blocked note into the PR body rather than only a comment, because the task named the PR body as the report channel and #2845 is the same PR this wave was told to push to.

## Do not repeat

- Do not assume an issue's `status:in-review` label means its fix merged. #2842 carries both `status:in-progress` and `status:in-review`; its PR #2844 is still open. Check `gh pr view <pr> --json mergedAt` and grep main for the actual code, not the labels.
- `git log --oneline <range> -m5` fails on this git version; use `| head` instead.

## Evidence

- `git merge-base --is-ancestor origin/main HEAD` : true (rebase no-op), `git rev-parse origin/main` = `c90a2978c83ad03e8bd83f71912ff80d8fe5b5d6`
- `gh pr view 2844 --json state,mergedAt` : `{"state":"OPEN","mergedAt":null}`, head `feat/ac-handover-landing`, commits `060e4f34`, `13d5a952`
- `git log --oneline origin/main | grep -iE "2842|budget|selected_offer"` : no match
- `git show origin/main:apps/web/app/r/[id]/atlas-result-session-page.tsx | grep -c selected_offer_id` : 0
- `git show origin/main:apps/web/lib/chat-step-machine/project-snapshot.ts` : `buildRehydratedResultsSnapshot` still returns null unless `createInitialState` lands on `confirmSearch`
- `gh pr edit 2845 --body-file ...` : succeeded, blocked section confirmed at the top of the body

## Open questions

- Who merges #2844: it is open with no review state checked here. The web wave of #2340 resumes only after it lands on main and this branch is rebased.

## Next hint

For the next web-frontend run, once #2844 merges: the work is in `apps/web/app/r/[id]/atlas-result-session-page.tsx`. On 401 keep the shell mounted and open the in-page sign-in modal via `requestAuth` with the existing 01-conventions 9.1 string "Sign in to continue where you left off", then re-fetch in place. On 403 `not_owner` call `cloneResultSession` from the generated client and `router.replace` to the new id, then hydrate through the same landing. On 200 hydrate through the existing landing (which post-2844 selects the record's chosen offer). S19 renders only if `docs/prd/pages/assistant-channel.md` section 9 marks S19 ACCEPTED at build time. No full reload, no interview flash, no 404 flash at any step. Triage the `/r/[id]` E2E specs per `docs/operations/e2e-flake-diagnosis.md` in the same PR.
