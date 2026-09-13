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

## Wave 2 (devops, 2026-09-13): docs, env examples, deploy workflow

### Built

Commit `4e1faf5b` on `fix/ac-resource-is-iris`, pushed. Seven files: `docs/operations/env-vars-api.md` (`ASSISTANT_RESOURCE_URI` row rewritten, `ASSISTANT_ISSUER` row added), `docs/operations/env-vars-iris.md` (`OLYMPUS_API_URL` and `ASSISTANT_RESOURCE_URI` rows, `gh variable set` line, bootstrap comment, verify step), `.github/workflows/deploy-iris.yml` (comments, plus the URL-contract step now asserts `ASSISTANT_RESOURCE_URI == IRIS_PUBLIC_URL/mcp` before deploying), `docs/operations/assistant-hosts.md` (preflight items 1, 2 and 5, MCP server URL row), root `.env.example` (`ASSISTANT_RESOURCE_URI` example to `http://localhost:8082/mcp`, `ASSISTANT_ISSUER` line added), `services/iris/.env.example` (same value), `services/iris/README.md` (two rows and the run line). PR #2837 body: the two docs-checklist lines ticked.

### Decisions

- `ASSISTANT_ISSUER` row was not in the task text but `check-env-vars.py` was red on it at the branch tip (read by `config.go`, no doc row), so the VERIFY step forced it.
- Added a pre-deploy assertion to `deploy-iris.yml` rather than a comment only: a mismatched resource now produces exactly the dead revision that step exists to name before deploying.
- Item 1 of the preflight was rewritten from "not set, 404" to the live state: `olympus-api-00452-jsc` (commit `1dba9b74`) has the route group ON with the API-path resource and both slots, no `ASSISTANT_ISSUER`; Iris and the repository variable carry the same API path. Order of operations is stated there: issuer plus resource on the API before its #2837 deploy (the new revision refuses to start without the issuer), repository variable before the Iris deploy.
- Item 5 cites the Iris request log, not the host: three `GET /.well-known/oauth-authorization-server` on the Iris origin (08:47:35, 08:49:18, 08:49:55 UTC) then `GET /authorize?...scope=assistant` there at 08:49:56, all 404. Client id and user agent strings were left out of the doc on purpose (vendor names).
- `docs/prd/pages/assistant-channel.md` was not touched: the contract says the API hosts the authorization server, which still holds; no page copy changes.

### Do not repeat

- Do not put the slot client ids or the `_NAME` values from the live API env into shared docs; they are vendor names.
- `timeout` does not exist on macOS; a `timeout 60 gcloud ...` line silently does nothing and the batch still reports exit 0.
- Nothing gates `env-vars-iris.md` or `services/iris/.env.example`; boot the edge from the example file to verify.

### Evidence

- `python3 scripts/check-env-vars.py` -> `check-env-vars exit: 0` (baseline on `f7af6f60` was exit 1, `ASSISTANT_ISSUER`)
- `make check-prd-index` -> `check-prd-index exit: 0`
- `actionlint .github/workflows/deploy-iris.yml` -> `actionlint exit: 0`
- Dash, vendor and trailer scans on the 73 added diff lines, on the commit message and on the PR body: clean.
- `services/iris`: `go build` then boot from `.env.example` -> `/health` 200, `/.well-known/oauth-protected-resource` served `"resource":"http://localhost:8082/mcp"`, `"authorization_servers":["http://localhost:8080"]`; probe logged `iris.issuer_probe` inconclusive (API down) and booted.
- Live 2026-09-13: Iris still advertises `resource` = API path; API `/.well-known/oauth-authorization-server` 200 with `issuer` = API origin; repository variable `ASSISTANT_RESOURCE_URI` = API path.

### Next hint

Operator order (preflight item 1 in `assistant-hosts.md`, second commit on this branch): set `ASSISTANT_ISSUER=https://olympus-api-964499096147.europe-north1.run.app` on `olympus-api` now (the running build `1dba9b74` ignores it; the #2837 build refuses to start without it). Merge #2837. Once `make deployed-version` shows the new API commit, change `ASSISTANT_RESOURCE_URI` on `olympus-api` to `https://olympus-iris-964499096147.europe-north1.run.app/mcp`; on the OLD build that value would advertise Iris as its own authorization server. `gh variable set ASSISTANT_RESOURCE_URI --body "https://olympus-iris-964499096147.europe-north1.run.app/mcp"` before the Iris deploy, or re-run `make deploy-iris` after the URL-contract step fails on the old value. Then the item 2 checks must print `resource ok` and `issuer ok`.
