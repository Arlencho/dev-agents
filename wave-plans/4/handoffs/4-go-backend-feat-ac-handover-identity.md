# Handoff: assistant handover identity, Go wave (#2340)

Branch `feat/ac-handover-identity`, commit `e4249fc6` on top of the PRD, db and api.yaml waves. Draft PR #2845 (retitled "Assistant handover identity: sign in first, then own-or-copy"; one PR per branch, so the db wave's draft was rewritten rather than duplicated).

## Built
- `apps/api/internal/service/result_sessions.go`: `ResultSessionOrigin` (`web`, `assistant`) and `originFromSource`; `ResultSession.Origin` on both projections; `CreateRequest.Source`; store seam `Create(..., source)` and `CloneForUser(sourceID, ownerUserID)`; `Get` answers an assistant-originated record by caller identity (401 / 403 `not_owner` / 200) after the assistant scope's existing owner-only 404; new `Clone` (404 first, then 401, then 409 `already_owner`, then the atomic copy).
- `apps/api/internal/store/postgres/result_sessions.go`: `Create` passes `source` as a nullable text; `CloneForUser` runs `CloneResultSessionForUser`.
- `apps/api/internal/store/memory/result_sessions.go`: same two changes, key stripping mirrored with `stripAssistantBinding`.
- `apps/api/internal/handler/result_sessions.go`: create sets `Source` from the token scope; `Get` maps the two new sentinels; new `Clone` handler; the 4xx strings are the api.yaml examples.
- `apps/api/internal/handler/routes.go`: `POST /result-sessions/{id}/clone` on plain `authOpts` under `RateLimitGuest(GuestRouteResultSessions)`.
- Tests: `apps/api/internal/handler/result_sessions_handover_test.go` (six tests); the fixture mux mounts the clone route; every existing `store.Create` test call passes the trailing `""`.

## Decisions
- Origin is decided in the handler from `middleware.TokenScopeFromContext`, not from `caller.OwnerOnly`: the two facts are the same bit today but mean different things (who may read vs where the record came from).
- The store `Create` gained a trailing `source` parameter rather than a second create method; the compiler enumerated the ~20 test call sites and they were patched mechanically.
- The clone route sits on plain `authOpts`, so assistant and concierge tokens are 403 at the middleware (default-deny). The api.yaml security block is BearerAuth only and neither channel's tool set includes a copy. If Iris ever needs a copy, add `WithScopeAllowed(ScopeAssistant)` on that group and decide what `OwnerOnly` means for clone.
- `Clone` resolves the id before the auth check so an unknown id is the GET 404 whatever the caller (api.yaml: "regardless of the caller's auth"); a guest with a real id gets 401, as on GET.
- The assistant scope's owner-only rule (canonical 404 for another traveller's record) runs before the 13.3.3 matrix, so a host still cannot learn that an id exists for someone else; the existing assistant-scope tests are unchanged and green.
- `handoff.md` is not committed: the scope hook admits `apps/api/` only.

## Do not repeat
- Do not put a comment line inside the `ResultSession` struct's aligned field block; gofmt re-aligns the block and the diff balloons. Document the field on the type comment.
- `go vet` reports at most the first batch of "not enough arguments" per package; loop patch-and-vet until clean instead of trusting one listing.
- The lessons note that `GET /api/v1/result-sessions/{uuid}` needs no token is now true only for `origin: web` records; an assistant record answers 401 to an unauthenticated probe.

## Evidence
- `cd apps/api && go test -race ./...` : exit 0 (no failures, no races)
- `cd apps/api && go vet ./...` : exit 0
- `golangci-lint run ./internal/handler/... ./internal/service/... ./internal/store/...` : `0 issues.`
- `make check-api-spec` : exit 0, `OK: 89 Go routes <-> 83 OpenAPI paths are in sync`
- New tests by name: `Create_OriginFollowsTokenScope`, `Get_AssistantRecordAnswersByIdentity`, `Get_WebRecordKeepsShareModel`, `Clone_CopiesNamedFieldsOnly`, `Clone_WebRecordKeepsOriginWeb`, `Clone_Refusals`, all PASS
- House style scan of added lines: no U+2014 / U+2013 / U+2015, no double-hyphen dash, no vendor names (each grep exit 1)
- `git push origin feat/ac-handover-identity` : exit 0; `gh pr edit 2845` : exit 0

## Open questions
- `PostgresResultSessionStore.FindByChatConversationID` uses a raw SELECT that does not read `source` or `revision`, so a row found that way projects as `origin: web` and revision 0. Pre-existing; only the chat-only `last_activity_at` bump uses it, which never projects the row. Worth a follow-up to switch it to a sqlc query.
- Iris's `olympus.Session` does not decode `origin`; nothing in Iris needs it yet.

## Next hint
Web wave: on `GET /result-sessions/{id}` 401 mount the sign-in modal over the shell and re-issue the GET; on 403 with `error_code: not_owner` call `POST /result-sessions/{id}/clone` and move the URL to `data.id`. `data.origin` says which model the page is in.
