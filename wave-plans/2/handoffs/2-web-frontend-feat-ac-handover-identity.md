# Handoff: web half of the assistant handover identity (feat/ac-handover-identity)

## Built

- `apps/web/components/conversation-strip.test.tsx`, `components/session-right-panel/use-refine-session.test.tsx`, `components/snapshot-view.test.tsx`: each ResultSession fixture now carries `origin: "web"` (required by the wave 3 generated client). Schema untouched. Web typecheck and build were red on this branch from exactly these three; both are green now.
- `apps/web/app/r/[id]/atlas-result-session-page.tsx`: the PRD assistant-channel section 7.4 landing. Split into an outer shell (stable `display: contents` wrapper, owns the router, the S20 line, and the copy handoff) plus `ResultSessionBody` keyed by session id. 401 keeps the shell on the chat-loading placeholder and opens the in-page modal via `requestAuth("Sign in to continue where you left off")`, re-fetching in place on resolve; 403 `not_owner` clones once and `router.replace`s to the copy; 404 calls `notFound()`; 200 hydrates as before (issue 2842 landing with the record-carried selection). S20 (`This trip is now saved in your account.`) renders once after a copy.
- `apps/web/lib/auth-context.tsx`: new `requestAuthForExpiredSession(reason)` for a 401 answered to a held token; `requestAuth` no-ops while a token exists, which would have made the clone-401 gate unreachable.
- `apps/web/components/chat/chat-v2.tsx`: `tabIndex={-1}` on the chat root so the landing can move focus into the trip after the modal closes.
- `apps/web/app/r/[id]/handover-landing.test.tsx`: all fifteen contract probes (H1-H15) from the frontend-critic comment on issue 2340, retyped to full ResultSession/User literals (no `as unknown as`).

## Decisions (and why)

- Body keyed by session id: after `router.replace` to the copy, every per-session state (parsed fields, snapshot writer, search controller) must start clean under the new id. Keying beats reset effects, which would flash the old record for one commit.
- The shell wrapper is `display: contents`: the page shell's first DOM child must keep identity across sign-in and hydrate (probe H4), and `.ra-chat-page` uses a fixed `calc(100dvh - chrome)` height that any ordinary wrapper would break.
- Focus moves into `[data-qa-view="chat"]` after a gate-resolved or copy hydration (contract C4). jsdom only focuses elements with a tabindex, hence the ChatV2 root change.
- Clone failures other than 401 stay on the placeholder rather than settling into the interview: a non-owner must never see actionable UI under the source id (contract C3). Not pinned by any probe; a product call worth confirming.
- The 404 fix (probe H15, pre-existing drift for web records too) is included per the critic's "fix in the wave or quarantine H15"; it is fixed, not quarantined.

## Do not repeat

- Do not rely on `requestAuth` for a 401 that carried a token: it resolves synchronously when a token is held, which first produced an infinite GET/403/clone loop in H11.
- Do not assign `ref.current` during render in this repo: `react-hooks/refs` errors (use an effect). Same for writing module-scope probe variables during render (`react-hooks/globals`).
- Playwright locally needs `npx playwright install chromium` (the pinned chromium_headless_shell-1234 was missing; the first E2E run failed 7/11 on exactly that, an environment gap, not the product).

## Evidence

- `make test-web`: exit 0, 335 files / 4707 tests.
- `make lint`: exit 0 (includes web eslint --max-warnings 0).
- `cd apps/web && npm run typecheck`: exit 0 (before the fixture fix: exit 2, the three errors the issue 2340 comments name).
- `cd apps/web && npm run build`: exit 0. Note: the Makefile has no web typecheck/build target; these are the ci.yml commands.
- E2E: `npx playwright test --project=critical` over the four specs covering /r/[id]: exit 0, 10 passed / 1 skipped, dual-booted real Go API + Next dev.
- PR #2845 updated (title unchanged), marked ready; issue 2340 labelled status:in-review. Head: 689c6738.

## Open questions / next hint

- On a held-token 401 the real api-client still fires the section 8.4 session-expiry redirect (toast, then /auth?redirect= after 1 s) alongside the in-page gate. The page behavior the probes pin is the in-page gate; whether section 8.4 should gain an opt-out for the handover surface is a call for the api-client owner, not this PR.
- Critic should focus on: the S20 banner styling (a fixed Tailwind pill under the header; no PRD wireframe exists for it), the notFound() call from a client component (works through the app router boundary; the probe mocks it), and whether H10's now-strict `lines.length === 1` (S20 is ACCEPTED, so it must render) matches their reading.
