# Handoff: assistant-channel W1-C web surfaces (branch `feat/ac-w1c-tile`)

Two web surfaces for the assistant channel (epic #2797, Wave 1 #2799),
built against the signed W0 contract (`docs/prd/pages/assistant-channel.md`,
accepted 2026-09-12). PR not yet opened by me in this session; branch is
pushed to `origin/feat/ac-w1c-tile`, three commits ahead of `main`.

## Built

1. **Connected assistants tile** (`apps/web/components/concierge/`):
   `connected-assistants-section.tsx` + `assistant-disconnect-dialog.tsx`
   + `assistant-copy.ts` + `format-date.ts`, wired into the existing
   `concierge-section.tsx` as a further section within the same panel
   (§ 7.1). Two fixed rows (ChatGPT, Claude, per D4 § 6), each showing
   `Not connected.` or `Connected {date}.` (S3) plus a Disconnect
   control when bound. Shares the existing `GET /concierge/bindings`
   fetch rather than adding a second call — that endpoint already
   returns assistant bindings alongside Telegram's.
2. **Consent screen** (`apps/web/app/assistant-connect/`): `page.tsx`
   (server component), `assistant-connect-view.tsx` (pure presentational,
   unit tested), `assistant-connect-copy.ts`. Login-or-signup (reused
   `GoogleSignInButton`, extended with an optional `href` override, plus
   a native magic-link form) then a consent step stating S4/S5 verbatim
   with ratified Connect/Cancel actions.

## Decisions

- **api.yaml drift found and NOT worked around silently.**
  `ChannelBinding.channel` is still `enum: [telegram]` in `api.yaml`,
  but the Wave 1 authorization server already writes
  `channel_bindings.channel = "assistant"`
  (`apps/api/internal/model/concierge.go`'s `ChannelAssistant`
  constant, confirmed by reading the Go source, not by trusting the
  task's claim that api.yaml already carries it — it does not). `tsc`
  correctly refused a direct literal comparison against `"assistant"`.
  Fixed by giving the assistant-connections UI a locally widened
  `ChannelBindingLike` type (`Omit<ChannelBinding, "channel"> & { channel: string }`)
  in `assistant-copy.ts`, not by casting past the compiler. Flagged in
  the PR body for an api-designer follow-up to widen the real enum.
- **No Connect button on the not-connected assistant rows.** The task
  only asked for "a disconnect control per row"; § 1's division of
  labour has the HOST start the OAuth flow, not this settings panel, so
  there is nothing for a web Connect click to do. Flagged as an open
  question in the PR body rather than inventing a control or its copy.
- **`/assistant-connect`'s route, step contract and most of its copy are
  PROPOSED, not in the signed PRD.** `assistant-channel.md` specs only
  the settings tile (§ 7.1); the login/consent SCREEN was, until this
  PR, only a server-rendered stopgap inside
  `apps/api/internal/handler/assistant_oauth.go`, whose own doc comment
  names it "W1-C ships the real screen." I ported its already-written
  (self-described unratified) strings into the real screen rather than
  inventing new ones, and marked every one PROPOSED in
  `assistant-connect-copy.ts`. A PRD addition proposing this formally is
  in the PR body (I could not commit it myself: this agent's scope is
  `apps/web/` only).
- **`/assistant-connect` is not reachable from a live host yet.** The
  Go authorization server self-renders HTML at every step
  (`renderLogin` / `renderCode` / `renderConsent`) instead of
  redirecting to a web page; there is no `WEB_BASE_URL`-style config for
  it to redirect to. Wiring that is an `apps/api` change, out of my
  scope. I built the page assuming a future redirect will pass
  `request_id` / `host` / `step` / `email` / `error` as query params
  (documented in `page.tsx`'s own doc comment) and read the
  `olympus_ac_bind` CSRF cookie server-side via `next/headers`
  `cookies()` (the only way to populate the consent form's hidden
  `csrf_token` field: it is HttpOnly, unreadable from client JS).
- **Forms are native `<form method="post">`, not fetch.** The Consent
  step's success redirect leaves Olympus entirely for the host's own
  `redirect_uri`; only a real top-level navigation follows a
  cross-origin redirect without a CORS failure. Kept all three forms on
  this page consistent with that constraint rather than mixing fetch
  and native POST.
- **Separated the presentational `AssistantConnectView` from the async
  server `page.tsx`** specifically so the view is unit testable with
  plain `render()` under the existing jsdom/RTL setup, since there is no
  existing precedent in this codebase for testing a server component
  that calls `next/headers`.

## Do not repeat

- Don't trust a task's claim that `api.yaml` already reflects a backend
  change without reading `api.yaml` (or the generated types) directly.
  It didn't here.
- Don't assume Next.js rewrite proxying + a plain client component can
  solve every OAuth browser-hand-off problem. The CSRF double-submit
  cookie here is HttpOnly by design; only a server-rendered response can
  echo it. If a task asks for a login/consent screen wrapping an OAuth
  authorization server you don't control, check whether any step needs
  to read a cookie or set headers server-side before assuming a client
  component works.
- Don't add a Connect button to a row just because a sibling row
  (Telegram) has one. Check what actually triggers the connection for
  that specific channel first.

## Evidence

```
cd apps/web
npx tsc --noEmit                                    TSC_EXIT=0
npx eslint . --ext .ts,.tsx --max-warnings 0         LINT_EXIT=0
npx vitest run                                       VITEST_EXIT=0 (4674/4674 passed, 333 files)
NEXT_PUBLIC_API_URL=http://localhost:8080 \
  npx next build                                     BUILD_EXIT=0 (/assistant-connect built as
                                                       "dynamic, server-rendered on demand")
cd ..
VOICE_LINT_FILES=/tmp/oly-voice-lint-files.txt \
  bash scripts/voice-lint.sh                          VOICE_LINT_EXIT=0 (0 banned phrases in
                                                       changed files; pre-existing apps/api
                                                       violations unrelated to this PR)
```

Disconnect-test-fails-on-parent proof: `git worktree add /tmp/oly-parent-check 27624641`
(the commit `feat/ac-w1c-tile` branched from), copied only
`connected-assistants-section.test.tsx` in, ran `npx vitest run` there:
failed (module `./connected-assistants-section` does not exist on that
commit). Worktree removed afterward (`git worktree remove --force`).

Visual baseline check: `apps/web/tests/e2e/critical/visual-*.spec.ts`
covers only `explore`, `landing`, `stories`. Nothing covers
`/account/settings` or the Concierge panel — no baseline to refresh, so
none was touched.

E2E triage: `apps/web/tests/e2e/critical/concierge-settings.spec.ts`
targets specific `data-testid`s, not the panel's full row count or
structure; both surfaces here are pure additions (a new section, a new
route) to an existing panel, not a rewrite of it, so nothing needed
quarantining.

## Open questions

- Should a not-connected assistant row carry ANY explanatory copy
  ("Connect from {host}'s settings.") given there is no button? Left
  blank rather than invented; flagged in the PR body.
- Whether "Connect" as the consent-screen Allow-action label collides
  or needs to stay distinct from the ratified Concierge row's "Connect"
  (opens a dialog) — flagged in `assistant-connect-copy.ts` and the PR
  body, not resolved here.
- The `apps/api` wiring gap (self-rendering vs. redirecting to
  `/assistant-connect`) needs a decision + a tracking issue; not filed
  by me (no `gh` write scope exercised for a new issue in this session).
