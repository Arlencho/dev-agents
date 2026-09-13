# Handoff: feat/ac-tile-connect-guide, Wave 2 backend (#2340)

## Built

- `GET /api/v1/concierge/bindings` now returns `data.assistant_hosts` next to `data.bindings`: one entry per registered assistant OAuth slot, in slot order, with `slot`, `name`, `client_id`, `mcp_url`. Always present (`[]` when `ASSISTANT_RESOURCE_URI` is unset or no slot has an `_ID`). Never nil, never a secret.
- `config.AssistantOAuthClientConfig.Slot` ("A"/"B"), set by `loadAssistantOAuthClients` from the env prefix.
- `handler.AssistantHostsFromConfig(cfg)` derives the list once; `NewConciergeHandler(svc, hosts)` takes it; `ListBindings` attaches it. Service layer untouched.
- `api.yaml`: `assistant_hosts` (required, maxItems 2) on `ChannelBindingListEnvelope.data`, new `AssistantHost` schema. `make generate` refreshed `packages/api-client/types.ts` and `apps/web/lib/generated-types.ts` (the generate script syncs the web copy by design).
- Tests: `TestConciergeListBindings_AssistantHosts`, `TestAssistantHostsFromConfig` (handler), `TestLoadAssistantOAuthClients_Slot` (config).

## Decisions

- Values attached in the handler, not the service: they are configuration, the PRD names `handler/concierge.go`, and the service keeps no knowledge of the OAuth registry.
- `name` is `DisplayName` (falls back to the id when `_NAME` is unset), matching the consent page's `{host}` and the binding's `display_identifier`, so the tile matches by `name`.
- `mcp_url` is `cfg.AssistantResourceURI` verbatim; no URL building in Go.
- Spec and client committed separately from the Go code so the api-designer-scope crossing is visible; done on explicit task instruction.
- Test fixtures use "Host A"/"Host B", not product names, per the shared-repo branding rule.

## Do not repeat

- The commit-message guardrail rejects the phrase "regenerated with" (matches its attribution-footer pattern). Say "make generate refreshed ..." instead.
- `make generate` needs `node_modules` in the worktree (`npm ci --ignore-scripts` at the root, about 1 min); `npx openapi-typescript` alone would not resolve the pinned 7.13.0.
- Bash session cwd drifts after a `cd` inside a compound command; run `make` targets with the absolute repo-root path.
- `gofmt -l ./internal/` lists many pre-existing files; check only the touched ones.
- PRD "Today" column in `assistant-channel.md` § 7.1 still says "Served nowhere"; docs are devops scope, left for that owner.

## Evidence

- `cd apps/api && go test -race -count=1 ./...` : 24 packages ok, `go test exit=0` (log `/tmp/go-test-race-ac-tile.log`); race rerun of handler/config/service after fixture rename: exit 0.
- `go vet ./...` : exit 0. `gofmt -l <touched files>` : none listed.
- `make check-api-spec` : `OK: 88 Go routes <-> 83 OpenAPI paths are in sync`, exit 0.
- `npx --yes @redocly/cli lint api.yaml` : valid, exit 0, no warning on the new lines.
- `make generate` : exit 0; diff limited to the new field and schema (19 lines per TS file), sqlc unchanged.
- Dash and vendor-name scans over added lines: clean.
- Commits: `5486547e` (apps/api), `c7d0852a` (api.yaml + client). Pushed: `8a80a422..c7d0852a  feat/ac-tile-connect-guide -> feat/ac-tile-connect-guide`.

## Next hint

- web-frontend: read `data.assistant_hosts` from the existing bindings fetch; the type is non-optional in the client. Match a binding to a slot by `name`.
- devops (optional): refresh the "Today" column of `assistant-channel.md` § 7.1 and the `ASSISTANT_OAUTH_CLIENT_*` rows in `docs/operations/env-vars-api.md` to note the field.
