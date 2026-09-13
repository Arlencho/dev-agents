# Handoff: fix/ac-resource-is-iris

Untracked on purpose: the repo root is outside the go-backend commit scope. Do not commit this file.

## Built

- `apps/api/internal/config/config.go`: `AssistantIssuer` (`ASSISTANT_ISSUER`), `validateAssistantAuthServer` (resource absolute; issuer required and a bare origin whenever the resource is set). `AssistantResourceURI` doc now says: the Iris MCP endpoint.
- `apps/api/internal/handler/assistant_oauth.go`: `WithIssuer`, `discoveryConfigured`; both discovery documents use the issuer for `issuer`, `authorization_servers` and endpoint URLs; `assistantMetadataOrigin` removed; token endpoint validates a `resource` form parameter (`invalid_target`).
- `apps/api/internal/handler/routes.go`: `.WithIssuer(cfg.AssistantIssuer)`.
- `apps/api/cmd/server/main.go`: boot log carries `issuer`.
- `apps/api/internal/middleware/auth.go`: comments only (pointer is the Iris origin by design).
- `services/iris/cmd/iris/main.go`: `Issuer = APIURL`; `issuerOrigin` removed; `checkIssuerParity` asserts bare API origin and `ResourceURI == PublicURL + "/mcp"`; `probeIssuer` boot probe of the API's AS metadata; wired in `main` after the parity gate.
- Tests: `apps/api/internal/config/assistant_issuer_test.go`, `apps/api/internal/handler/assistant_audience_roundtrip_test.go`, updated `assistant_oauth_test.go`, `services/iris/cmd/iris/{edge,issuer_parity}_test.go`, `internal/token/token_test.go`, `internal/mcp/mcp_test.go`.

## Decisions

- New env var `ASSISTANT_ISSUER` rather than reusing an existing value: `MAPS_IMAGE_BASE_URL` is tied to the Maps flag and https-only, `GOOGLE_OAUTH_REDIRECT_URI` is a Google callback. Neither names the API origin unconditionally.
- The API's own copy of `/.well-known/oauth-protected-resource` is kept (resource = Iris URL, authorization_servers = API origin) so an operator starting from the API origin reads the same answer Iris serves.
- Iris probe semantics: refuse to boot only on a proven mismatch (200 with a different `issuer`); unreachable, non-200 or unreadable is logged (`event=iris.issuer_probe`) and boots. A hard dependency on the API being up would turn every API deploy into an Iris outage, and today the API's assistant route group is off (404).
- Did not touch `.env.example` (root or `services/iris/`) or `docs/operations/*`: devops-owned by convention. Listed as blocking follow-ups in the PR. Note that `services/iris/.env.example` currently carries the old value, so `make dev` Iris will refuse to boot until devops updates it.
- Middleware tests keep their legacy API-path audience literals; they are self-consistent (pointer derives from the audience) and the new round-trip test pins the Iris shape.

## Do not repeat

- Do not derive the issuer from `ASSISTANT_RESOURCE_URI` anywhere; the two live on different origins now.
- Do not compare resource URIs with any normalisation; `aud` is minted and checked byte for byte on both sides.
- Do not reassign an `httptest.Server` handler after start in tests (racy); derive the issuer from `r.Host`.

## Evidence

- `cd apps/api && go test -race -count=1 ./...` -> `api race exit: 0`, 24 packages ok
- `cd services/iris && go vet ./... && go test -race -count=1 ./...` -> `iris test exit: 0`, 7 packages ok
- `make check-service-isolation` -> exit 0
- `golangci-lint run ./internal/handler/... ./internal/config/... ./internal/middleware/... ./cmd/...` -> 0 issues
- Dash scan on added diff lines: clean
- Commit `f7af6f60` on `fix/ac-resource-is-iris`, pushed; draft PR opened (Refs #2800, #2340)

## Next hint

Devops PR: `ASSISTANT_ISSUER` row in `env-vars-api.md` + `deploy-api.yml`; `ASSISTANT_RESOURCE_URI` rows and the `gh variable set` bootstrap line to the Iris MCP URL; `assistant-hosts.md` preflight items 1 and 5; both `.env.example` files. Then set the two repository variables / service env vars before the pilot day.

## Re-verification (second session, 2026-09-13)

Treated the section above as claims and re-ran everything from the branch tip `f7af6f60` (origin and local in sync, draft PR #2837).

- Deliverable ONE: `assistantMetadataOrigin` gone; `issuer` and `authorization_servers` come from `config.AssistantIssuer` via `WithIssuer`. Evidence for adding the variable: `git show main:apps/api/internal/config/config.go | grep -i url` lists `WebBaseURL` (web origin), `MapsImageBaseURL` (API origin, but flag-bound and https-only), nothing that names the API origin unconditionally.
- Deliverable TWO: authorize path still returns `service.ErrAssistantResourceMismatch` (assistant_auth.go:644); token path gained the `invalid_target` check; middleware compares `audience != cfg.assistantAudience` (auth.go:486).
- Deliverable THREE: Iris `Issuer = cfg.APIURL`; `checkIssuerParity` asserts bare API origin and `ResourceURI == PublicURL + mcpPath`; token gate compares `c.Audience[0] != g.Audience` (token.go:149). Critic test rewritten.
- Deliverable FOUR: all seven named tests exist (grep pasted in session).
- `cd apps/api && go build ./... && go vet ./... && go test -race -count=1 ./...` -> `api race exit: 0`
- `cd services/iris && go build ./... && go vet ./... && go test -race -count=1 ./...` -> `iris race exit: 0`
- `make check-service-isolation` (from repo root; the target does not resolve from inside `services/iris`) -> `isolation exit: 0`
- Dash scan (U+2013/2014/2015, " -- ") on commit message, PR body and added diff lines: no hits.
- Vendor-name scan: one hit, the PR template's literal filename line for the agent instructions file. Reworded that checklist line in the PR body; rescan clean. Commit message was already clean and untouched.
- No Co-Authored-By trailer and no generator footer on the commit or the PR, by project rule (board directive OLY-4), which overrides the harness default.
