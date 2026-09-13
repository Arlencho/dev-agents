# Handoff: fix/ac-tile-followups rebase (PR #2836, issue #2827)

## Built

- Rebased `fix/ac-tile-followups` onto `origin/main` (`3a05544e`), which had landed the per-host How to connect disclosure (`acb8f856`) under the same Connected assistants tile. Force-pushed as `35c19e3b` (was `7ff4b944`).
- Both behaviours kept: the connect guide (per-host disclosure, copyable `{mcp_url}`/`{client_id}`, return refetch, Coming soon host A row) and the three follow-ups (disconnect failure-class mapping in `assistant-disconnect-dialog.tsx`, `min-h-11 md:min-h-0` on both retry controls, S8 toast gated on `consented_at` within five minutes plus the per-device seen set).
- Appended a `## Rebase` section to the PR #2836 body with the real verification commands and exit codes.

## Decisions (+why)

- Only `connected-assistants-section.test.tsx` conflicted (diff3 hunks where main added the required `assistantHosts` prop and this branch swapped the bindings under test). Resolution kept both sides: the branch's binding values plus `assistantHosts={null}`.
- Two test renders from the original branch commit predated the `assistantHosts` prop and only failed `tsc` after the rebase (vitest passed regardless). Fixed by adding `assistantHosts={null}` and amending, so the branch stays a single clean commit.
- The em dash in `disconnect dialog` test expectations is the ratified `01-conventions.md` section 3 string in `apps/web/lib/error-copy.ts`, reused verbatim; PRD section 9 says reused strings ship unchanged, so it stays. The "no long dash" house rule was applied to everything authored here (commit message, PR body, this file).

## Open questions

- None blocking. The server-side acknowledged flag for the S8 toast remains the documented follow-up (contract change, out of scope per the issue).

## Do not repeat

- Piping `npm run typecheck` to `tail` masks the real exit code (`$?` is tail's). Use `npx tsc --noEmit; echo $?` directly.
- `npx vitest` fails with MODULE_NOT_FOUND when `apps/web/node_modules` is absent; run `npm ci` at the repo root first (workspaces).
- The Makefile has no typecheck target; `make lint` covers web lint only. Typecheck is `npm run typecheck` (or `npx tsc --noEmit`) inside `apps/web`.

## Evidence

- `git rebase origin/main`: 1 conflict (`connected-assistants-section.test.tsx`), resolved; `git rebase --continue` exit 0.
- `cd apps/web && npx vitest run components/concierge/assistant-disconnect-dialog.test.tsx components/concierge/connected-assistants-section.test.tsx components/concierge/concierge-section.test.tsx components/concierge/return-refetch.test.tsx`: 4 files / 36 tests passed, exit 0.
- `make lint`: exit 0. `cd apps/web && npm run lint`: exit 0. `cd apps/web && npx tsc --noEmit`: exit 0.
- `git push --force-with-lease origin fix/ac-tile-followups`: `7ff4b944...35c19e3b`, exit 0. PR head ref oid confirmed `35c19e3b...` via `gh pr view 2836`.
- String audit: every entry in `apps/web/components/concierge/assistant-copy.ts` cites section 9 (S1 to S19) or a ratified reuse; grep of the touched components shows no hardcoded user-facing strings.

## Next hint

For the critic: cold-read `connected-assistants-section.tsx` lines 140 to 175 (the toast gate) and confirm the seen-set recording still happens for stale bindings, then spot-check that the guide disclosure renders on the not-connected row only and never toasts from a tile action, per section 7.1's ruling.
