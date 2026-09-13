# Handoff: PR 2826 critic loop 1 fix (branch feat/ac-w1c-tile, head ab3aa670)

## Built

Second pass on the critic findings (issue #2340, comment "CRITIC ASSISTANT CHANNEL W1C TILE") against the PRD as amended by the 2026-09-12 co-founder ruling (`docs/prd/pages/assistant-channel.md` § 7.1 ruling paragraph, § 9 S10). The F1 to F10 code fixes landed in commit `64aa0283` (prior agent); this pass verified every one of them against the tree, re-ran all gates, and added two follow-up commits:

- `fc3348a9` reverts `ba9b7438` (the `apps/web/CLAUDE.md` agent-rules block). Verified the block is genuinely auto-written by `next dev` (`node_modules/next/dist/server/lib/generate-agent-files.js`, markers at lines 45 to 46), but its vendor-supplied text contains two em dashes, which trips the house-style gate on the PR diff. `next dev` re-adds it locally as an uncommitted change; keeping it out of the PR is the steady state.
- `ab3aa670` rewrites a box-drawing (`─`) comment banner at the top of `connected-assistants-section.test.tsx` into a plain docblock. The prior house-style scan missed it; the critic's mechanical gate scans added lines for exactly these characters.

Verified state of the findings (all held as the prior handoff claimed):

- F1: `apps/web/app/assistant-connect/` is gone; no `assistant-connect` references remain outside the tile's `assistant-connections-*` testids; the two comments claiming a PRD addition went with the deleted files (grep for "PRD addition" / "§ 7.0" in `apps/web`: zero hits).
- F3: nothing reads `host` or `step` from the query string for this channel; remaining `get("step")` hits are pre-existing chat/trip code.
- F4: not-connected state is S1 + S2 + S10 with no Connect control (`connected-assistants-section.tsx:189-229`); connected row S3, dialog S6/S7, S9 toast in `assistant-disconnect-dialog.tsx:101`; S8 toast fires from a localStorage seen-set (`olympus_ac_seen_bindings`), once per newly seen assistant `binding_id`.
- F5: `disconnect_error` uses the ratified generic `Something went wrong on our end. Try once more.`; confirmed verbatim at `docs/prd/01-conventions.md:253`.
- F6: `autoComplete="one-time-code"` intact at `app/auth/otp/page.tsx:386` and `components/auth-modal.tsx:673`.
- F7: the false `03-auth-otp.md` citation went with the deleted copy catalog.
- F8: no full-page surface remains; `app-shell.tsx` diff-clean against base.
- F9/F10: dead id and inline style gone.
- PR body updated with the ruling and fresh exit codes; PR kept a draft. Pushed `ba9b7438..ab3aa670`.

## Decisions (+why)

- **Reverted rather than force-pushed away `ba9b7438`.** It was already on the remote; a revert commit keeps history honest and removes the block from the final diff just the same.
- **Pilot-host names (ChatGPT, Claude) stay in the PR body and commit `1233b9f3`'s message.** They are the ratified product feature (`assistant-channel.md` § 6), not vendor provenance; the delivery-face ban is about model attribution, which is absent everywhere.
- **S8 detection via a localStorage seen-set, not a query param** (prior agent's call, confirmed sound): the API consent handler 302s to the host's `redirect_uri` (`apps/api/internal/handler/assistant_oauth.go:460-501`), so the browser never returns to an Olympus URL with a signal, and adding one is apps/api scope. Storage is written before the toasts fire, so a StrictMode double-mount cannot double-toast. Reconnect after disconnect mints a new `binding_id`, so the toast refires correctly.
- **F5 replacement rather than PROPOSED marker:** the ratified generic states the truth without inventing copy, and agents cannot sign off new strings. Trade-off: the failure line no longer names the host; the dialog title still does.
- **S10 rendered per not-connected row** (prior agent's call): § 7.1's table places the sentence "below that row", so both rows carry it when both hosts are unbound. If the critic reads the ruling's singular "the S10 sentence" as once per tile, this is the line to revisit.

## Do not repeat

- `npx tsc --noEmit` fails with a phantom `app/assistant-connect/page.js` error until you `rm -rf apps/web/.next`; the generated route validator is stale after deleting a route. Not a real type error.
- Do not re-commit the `next dev` agent-rules block in `apps/web/CLAUDE.md`: it is machine-written, contains em dashes, and will fail the house-style scan on any PR that includes it.
- macOS `grep -P` does not exist; `grep $'[—–─]'` works in bash for the dash scan.
- The e2e spec needs Postgres + Redis (containers `olympus-postgres` / `olympus-redis` were up and seeded; `e2e-concierge@olympus-test.local` exists in the local DB). Playwright boots the Go API and Next dev server itself with mocked providers.

## Evidence

```
cd apps/web
npx tsc --noEmit                     TSC_EXIT=0
npm run lint                         LINT_EXIT=0
npm test                             TEST_EXIT=0  (332 files, 4669/4669 passed)
npm run build                        BUILD_EXIT=0 (no /assistant-connect route emitted)
npx playwright test tests/e2e/critical/concierge-settings.spec.ts
                                     E2E_EXIT=0  (3 passed, 1 skipped fixme pin)
cd ..
VOICE_LINT_FILES=<changed-files> bash scripts/voice-lint.sh
                                     VOICE_LINT_EXIT=0
git push origin feat/ac-w1c-tile     PUSH_EXIT=0  (ba9b7438..ab3aa670)
gh pr view 2826                      isDraft=true, head ab3aa67044257ffd5fd0e036c8d8d787f323769c
```

Dash rescan of the full diff after the follow-ups: zero long dash / en dash / horizontal bar on added lines.

## Open questions / next hint

- The API-rendered consent pages (`assistant_oauth.go` templates) still carry unratified copy and no consent-checkbox gate (critic F2 lives there now). Not web scope.
- The § 7.1 opening paragraph still cites the connect dialog's consent-first gate as reused tile behaviour; with no Connect control that gate belongs to the consent surface. A docs-owner cleanup.
- `api.yaml`'s `ChannelBinding.channel` enum is still `[telegram]`; the `ChannelBindingLike` widening in `assistant-copy.ts` is the deliberate local bridge until an api-designer widens it.
- Critic should focus on: whether the S10 placement (per row) matches the ruling's intent, whether the localStorage seen-set is an acceptable reading of "lands back on the site" for S8, and whether the revert of the auto-generated CLAUDE.md block is the right call versus carrying the em dashes.
