# Handoff: feat/ac-w1d-authserver (assistant-channel authorization server, #2799)

## Built

The OAuth 2.1 + PKCE authorization server that lets a third-party AI
assistant obtain a scoped Olympus token, and nothing else. All in
`apps/api`:

- `internal/service/assistant_auth.go` (new): `AssistantAuthService`,
  the authorization-code + PKCE + refresh-rotation + revoke core.
  In-memory pending/code/refresh stores (same pinned posture as
  `ConciergeService` and the OAuth exchange store), Postgres-backed
  channel binding via the existing `ChannelBindingStore`.
- `internal/service/auth.go`: `MintAssistantAccessToken`,
  `ValidateAccessTokenScopedAudience`, `generateScopedAudienceToken`.
  Every assistant token now carries a non-empty `aud` claim
  (`jwt.RegisteredClaims.Audience`); every other token's wire shape is
  byte-identical (`omitempty`).
- `internal/middleware/auth.go`: `AudienceScopedTokenValidator`,
  `WithAssistantAudience`. `enforceScope` now rejects a
  `ScopeAssistant` token whose audience does not match the route
  group's wired value, checked before the existing binding-liveness
  I/O.
- `internal/handler/assistant_oauth.go` (new): discovery
  (`/.well-known/oauth-protected-resource`,
  `/.well-known/oauth-authorization-server`, both root-mounted),
  `GET /oauth/assistant/authorize`, the magic-link login POSTs, the
  Google login GET, `POST /oauth/assistant/consent`,
  `POST /oauth/assistant/token`, `POST /oauth/assistant/revoke`.
  Minimal server-rendered HTML; every string PROPOSED.
- `internal/handler/google_oauth.go`: additive-only
  `BeginForReturnContext` + `AssistantReturnHandler` so the assistant
  flow reuses the existing Google sign-in mechanics without a second
  registered redirect_uri. Default `Begin`/`Callback` path is
  unchanged (regression test included).
- `internal/config/config.go`, `cmd/server/main.go`,
  `internal/handler/routes.go`: wiring, all nil-safe (no DB pool or no
  `ASSISTANT_RESOURCE_URI` = every route 404s).

## Decisions

- **Static client registration, not Dynamic Client Registration.** The
  MCP spec lists DCR as a SHOULD, and explicitly names hardcoding a
  client ID as the alternative for a server that skips it. D4 already
  closes the host list at two named pilots, so DCR would add an
  unauthenticated registration surface for a generality this pilot
  never exercises. Full rationale is in `AssistantClient`'s doc
  comment in `assistant_auth.go`.
- **Login reuse, not reimplementation.** Magic link: the flow calls
  `service.MagicLinkService.Request` / `.VerifyWithCode` directly (OTP
  code path, self-contained, no dependency on `apps/web`), reusing the
  same handler-level invite-gate helpers (`checkInviteGate`,
  `writeInviteGateDenial`) the existing web endpoint uses. Google: the
  flow reuses the *exact same* registered `redirect_uri` (Google's
  callback URL never changes) by adding an optional return-context
  cookie to the existing `GoogleOAuthHandler`, so no second OAuth
  client needs registering in Google Cloud Console. Password
  login/signup was deliberately NOT built: the epic says magic link
  and Google specifically, and password signup is off under the
  Soft-live invite gate anyway.
- **No new store method for binding creation.** `CompleteConsent`
  reuses `ChannelBindingStore.CreateBindingReplacingActive` verbatim
  with `external_id = client_id`. This is correct AND is a known
  limitation: `idx_channel_bindings_active_user_channel` (migration
  000033) is still unique on `(channel, user_id)` alone, so a second
  pilot host's consent revokes the first host's binding for the same
  user, same as today's Telegram/WhatsApp collapse-to-one. Issue #2799
  itself calls out "one binding per assistant, not per channel value"
  as a Wave 1 requirement; the merged W1-A migration (#2803) did not
  widen that index. **Flagging as a follow-up for db-architect**
  (widen the index to include `external_id`, or an equivalent) rather
  than attempting a migration myself, which is out of `go-backend`
  scope.
- **Revoke never accepts a client secret.** These are public clients
  (PKCE, no client authentication). `POST /revoke` takes `client_id` +
  `token` and answers 200 unconditionally (RFC 7009: never an
  existence oracle), after trying the token as an access token via our
  own `AuthService` validator first, then as a refresh token.
- **`AssistantServiceToken` (W1-B) is intentionally unused here.** It
  guards a future *internal* service-to-service surface for the
  connector (`services/iris`, a later wave); every route in this PR is
  public-facing OAuth surface a host's browser or back-channel calls
  directly, not an internal endpoint.

## Do not repeat

- Do not assume the shared clone at `~/dev/olympus-platform` keeps
  its HEAD stable across a long session. Twice during this task
  another process checked the working directory out to a different
  branch (`docs/live-booking-docs-sweep`) mid-session. Uncommitted
  work survived, since `checkout` does not discard changes to files
  the target branch leaves untouched, but every subsequent read or
  write would have landed on the wrong branch if not caught. Commit
  and push early, and once something is at risk, do the rest of the
  session in a dedicated `git worktree` (`git worktree add /tmp/x
  <branch>`), never the shared directory.
- Do not write em/en dashes in new code comments even though most of
  the existing codebase is full of them: a prior commit (#2807) had
  to retroactively strip them from PR 2804's comments. Check added
  lines only (`git diff -U0 | grep '^+' | grep -P
  '\x{2014}|\x{2013}'`), never the whole file: most files here have
  100+ pre-existing dashes that are not this PR's business to touch.
- `make check-api-spec` is FAILING on this branch and will keep
  failing until `api.yaml` (api-designer) or
  `scripts/check-openapi-routes.py`'s `RUNTIME_ALLOWLIST` (devops)
  gets the 9 new routes. This is a deliberate scope boundary, not an
  oversight: see the PR body.

## Evidence

Every command run directly (never through a pipe) so `$?` is the real
exit code, from a clean worktree checked out at `2529fb49`.

```
$ go build ./... ; echo BUILD_EXIT=$?
BUILD_EXIT=0

$ go vet ./... ; echo VET_EXIT=$?
VET_EXIT=0

$ go test ./... -race ; echo TEST_EXIT=$?
... (all packages ok)
TEST_EXIT=0

$ golangci-lint run ./apps/api/... ; echo LINT_EXIT=$?
0 issues.
LINT_EXIT=0

$ make check-api-spec ; echo APISPEC_EXIT=$?
FAIL: routes in Go code with NO matching OpenAPI path: (9 assistant-oauth + well-known routes)
APISPEC_EXIT=2
```

Parent-commit proof (throwaway worktree at `f911691d`, only the new
and modified TEST files copied in, production code left at parent
state):

```
$ go vet ./... ; echo PARENT_VET_EXIT=$?
internal/middleware/auth_scope_test.go:440: undefined: WithAssistantAudience
internal/handler/assistant_oauth_test.go:42: undefined: AssistantOAuthHandler
internal/service/assistant_auth_test.go:38: undefined: AssistantClient
... (every new API surface undefined)
PARENT_VET_EXIT=1

$ go test ./internal/middleware/... ./internal/handler/... ./internal/service/... ; echo PARENT_TEST_EXIT=$?
FAIL github.com/.../internal/middleware [build failed]
FAIL github.com/.../internal/handler [build failed]
FAIL github.com/.../internal/service [build failed]
PARENT_TEST_EXIT=1
```

New test names covering the nine required proofs (#2799): PKCE
required/S256-only (`TestAssistantAuthorize_PKCERequired`,
`TestAssistantAuthorize_PKCEMethodMustBeS256`), audience enforcement
(`TestAuthMiddleware_AssistantAudienceEnforcement`,
`TestAssistantExchangeCode_TokenCarriesAssistantScopeAndAudience`),
consent creates exactly one binding
(`TestAssistantCompleteConsent_CreatesExactlyOneActiveBinding`),
revoke kills the next request and the refresh
(`TestAssistantRevoke_DeactivatesBindingAndInvalidatesRefreshToken`,
`TestAssistantRevoke_ByRefreshTokenAlsoDeactivatesBinding`), refresh
rotation (`TestAssistantRefresh_RotationInvalidatesOldToken`),
not-invited refused before any row
(`TestAssistantOAuth_NotInvitedLogin_RefusedBeforeAnyRow`), foreign
bearer 401 (`TestAuthMiddleware_ForeignBearerToken_Rejected401`),
unregistered redirect refused
(`TestAssistantOAuth_UnregisteredRedirectURI_NeverRedirects`,
`TestAssistantAuthorize_UnregisteredRedirectURIRefused`).

PR: https://github.com/Arlencho/olympus-platform/pull/new/feat/ac-w1d-authserver
(opened separately after this handoff was written; see the actual PR
number in the issue thread).

## Open questions

- Real redirect URIs for the two pilot hosts are still "Unread"
  placeholders per `docs/prd/pages/assistant-channel.md` § 6 (Wave 0,
  PR #2802, not yet merged/signed off). `ASSISTANT_OAUTH_CLIENT_A/B_*`
  env vars are wired and tested but nothing is configured in any real
  environment: someone needs to read each host's current OAuth
  documentation before the pilot can actually connect.
- `idx_channel_bindings_active_user_channel` needs a db-architect
  follow-up (see Decisions) before D4's "two hosts at once, same
  traveller" can work end-to-end.
- `api.yaml` / `RUNTIME_ALLOWLIST` need an api-designer or devops pass
  before `make check-api-spec` and CI's `api-spec-completeness` job go
  green.
