# Handoff: feat/ac-w2c-update-and-hosts, update_trip and the enforcement matrix (go-backend)

Branch `feat/ac-w2c-update-and-hosts` off `origin/main` at `98fa907b` (W2-B merged), head `c4d14be7`. Draft PR #2833, Refs #2800, not merged.

## Built

services/iris (Wave 2-C):

- `internal/tools/update.go`: `update_trip`, contract section 3.3.7 and section 5. Title, depart/return dates (null clears the return), traveller counts, `select_option_id` / `deselect_option_id`, a note of at most 500 characters. Writes the traveller's own trip record through `PATCH /result-sessions/{id}` and nothing else; not metered (no supplier, no ranker). Reads the record, checks the host's revision, takes the per-record lock `Registry.refining` (the one refine uses), re-reads, merges the patch key by key into the raw `parsed_fields` object (the API replaces the blob wholesale), PATCHes, and returns the get_trip payload from the PATCH response. A PATCH the API accepted but did not apply (a record whose trip state is owned by a website conversation) answers `not_available` rather than a phantom edit.
- Revision codes: revision moved on since the host read it: `stale_revision`; moved between the pre-check and the locked re-read (a write raced another): `revision_conflict`. Both carry the current get_trip payload in `current` (new optional field on `mcp.ErrorPayload`, `mcp.ConflictResult`). Nothing is written on either.
- Two counters on the record: `assistant_revision` (search revision, what option ids bind to; bumped by refine only) and the new `assistant_trip_revision` (bumped by refine and by update_trip; what get_trip / list_trips report and update_trip takes). A title edit therefore never invalidates the option ids the host holds. `tripRevision()` falls back to the search revision on records written before the counter existed.
- Note scan on write (`scanNote`): email, card (13 to 19 digits passing Luhn), phone (9+ digits, ISO dates stripped first), and stated card / passport / date-of-birth words. Refusal logs tool, reason `forbidden_content` and the class name; never the value. Stored under `assistant_note` on the record only.
- Selection writes the supplier handle at the option's position into `selected_offer_id` (what a web card click writes); the handle never reaches a payload or a log (`supplierHandleAt`).
- `internal/olympus/client.go`: `UpdateSession` (PATCH). `tools.API` interface gained it; the test fake implements it (`linked` map simulates an authority-managed record).
- Manifest: update_trip description and the three field descriptions updated to match; annotations unchanged (readOnlyHint false).

apps/api:

- `internal/handler/assistant_enforcement_matrix_test.go`: `TestAssistantScope_EnforcementMatrix` walks every route on `handler.NewRouter` (chi.Walk, with Stays, trip-confirm, Duffel client-key, orphan-admin and Duffel webhook routes registered via a new `newHermesScopeFixtureWith` services hook), fires each with a live assistant token and anonymously, classifies: assistant surface (7), scope gate 403 with the gate's own body (39), public with bearer inert (16), non-bearer gate (6). Every money-vocabulary route (20) must be scope-gated or non-bearer gated; an unclassified route fails. Plus the revoked token on the whole surface. `TestAssistantScope_MoneyRoutesAreLiveForAFullAccessToken` is the control: same routes, full-access JWT, never the scope gate's verdict.

## Decisions

- Stale vs conflict: section 3.4 gives `stale_revision` = "the revision has moved on" and `revision_conflict` = "a write raced another write"; section 3.3.7's one sentence names only `revision_conflict` for a stale write. Implemented both by their 3.4 definitions (the task text also says stale_revision with the current state). Flagged in the PR for the PRD owner to settle 3.3.7's wording; the code follows whichever is chosen with a one-line change in `updateTrip`.
- The W1-A `result_sessions.revision` column is not exposed by the API (no field in the ResultSession shape, `UpdateResultSessionFields` matches on id alone, both outside go-backend scope). The trip revision therefore lives in `parsed_fields` under the same per-record lock refine already relies on. Follow-up named in the PR: db-architect (query takes `expected_revision`), api-designer (`revision` on the wire, PATCH takes it), then Iris drops its counter.
- Title is written to `original_query`: the label both the trips page (`labelFromParsedFields`) and get_trip derive first, so the website shows the same title. Capped at 80 runes because that label is truncated at 80 on read.
- Note never becomes a preference: `service.ResolveScopes` only carries its enumerated `stickyFields`; an `assistant_note` key cannot reach `user_profiles`. Iris side pinned by test (note on the record only).
- `go.work.sum` was touched by tooling and restored; not committed (devops).

## Do not repeat

- Do not bump `assistant_revision` from update_trip: it stales every option id the host holds and forces a paid refine to select anything.
- Do not mint the revoked assistant token in the matrix with `mintHermesToken(tokAssistantRevoked)` after the live one: same external id, the memory store replaces the live binding.
- `/internal/concierge/*` and `/webhooks/*` are not bearer-gated; classify, do not expect 403.
- `critic_failing_test.go` untouched; `sharingAPI` embeds `*fakeAPI`, so new API methods go on the fake.

## Evidence

```
services/iris: gofmt -l . (0 files); go vet ./...; go test -race -count=1 ./...   exit 0 (7/7 ok)
services/iris: golangci-lint run ./...                                            0 issues
apps/api:      go vet ./internal/handler/; golangci-lint run ./internal/handler/  0 issues
apps/api:      go test -race -count=1 -v -run 'TestAssistantScope_' ./internal/handler/   PASS (matrix in the PR body)
apps/api:      go test -race -count=1 ./...                                       exit 0 (24 packages ok)
make check-service-isolation                                                      passed (51 files, 2 services)
perl scan of the diff and new files for the three long dashes, the double-hyphen substitute and vendor names   no hits (one case-insensitive false positive on an identifier)
```

## Open questions / next hint

- PRD owner: settle 3.3.7's revision code sentence (see Decisions); add `current` to the error shape in 3.4 for the two write codes; note that get_trip's `revision` is the trip revision and option ids are bound to the search revision.
- devops: `services/iris/README.md` lines 23, 77 and 108 still say update_trip answers not_available and that the check-and-bump moves into the API query in this slice; the second part became a follow-up (above).
- web-frontend / Atlas: read `assistant_note` from the record when the traveller lands on `/r/{id}` (issue #2800 fact 5, "so Atlas is not blind"); nothing reads it yet.

## Reconciled (second go-backend session, same dispatch, 01:10 local)

The "foreign edits" the section below described were this session's: the same task was dispatched twice and both seats worked in this one checkout, which the root instructions forbid. This session had read the tree before `c4d14be7` landed, found `update.go` and the client, tools and trips changes uncommitted, and started writing tests and a matrix of its own; the commit and PR #2833 arrived while it was reading. On noticing, it stopped and re-planned: nothing of its own was kept.

- `services/iris/internal/tools/update_test.go`: this session's rewrite (did not compile, `updateArgs` redeclared) reverted from HEAD with git checkout; the committed file is back byte for byte.
- `apps/api/internal/handler/assistant_scope_matrix_test.go`: this session's duplicate matrix, deleted.
- `apps/api/internal/handler/hermes_scope_enforcement_test.go`: this session's second services hook (`newHermesScopeFixtureWithServices`, a duplicate of the committed `newHermesScopeFixtureWith`) reverted.
- `git status` after: only this untracked `handoff.md`. Local HEAD and `origin/feat/ac-w2c-update-and-hosts` are both `c4d14be7`. No second commit, no second PR.

Independent verification of `c4d14be7` by this session (the handoff above was treated as a claim, not as proof):

```
services/iris: gofmt -l . (0 files); go vet ./...; go test -race -count=1 ./...      7/7 ok
services/iris: golangci-lint run ./...                                               0 issues
apps/api:      go test -race -count=1 -v -run 'TestAssistantScope_' ./internal/handler/   PASS, 68 rows
               diff of the 68 matrix rows + summary line, live run vs PR #2833 body   identical
apps/api:      go vet ./internal/handler/ ./internal/middleware/; golangci-lint run ./internal/handler/   0 issues
apps/api:      go test -race -count=1 ./...                                          exit 0, every package ok
make check-service-isolation                                                         passed (51 files, 2 services)
git log -1 --format=%B                     no Co-Authored-By, no "Generated with", no vendor name
commit message + PR body + commit diff     no U+2014, U+2013 or U+2015, no double-hyphen substitute
PR body + added lines                      no AI tool or vendor name
gh pr view 2833                            OPEN, draft, head feat/ac-w2c-update-and-hosts, Refs #2800, matrix pasted through the final "ok" line
gh pr checks 2833                          Iris Build + Test pass, Go Lint pass, API Spec Completeness pass; Go Test / Go Build pending at 01:12
services/iris tools_test.go                TestWave3ToolsAnswerNotAvailableInTheSection34Shape covers create_checkout and get_checkout_status
```

Task requirements, checked against the tree rather than the text: update_trip writes only the traveller's own record through the one PATCH the assistant scope is allowed (`update.go`, `client.go` doc header); a stale revision answers `stale_revision` with `current` and nothing written (`TestUpdateTrip/"a stale revision returns the current state and writes nothing"`); the note is stored under `assistant_note` on the record only (`"edits the record under its revision..."` asserts no other record carries it); the matrix exercises `middleware.Auth` / `OptionalAuth` over `chi.Walk` and pins the scope gate's own body on every 403; the two Wave 3 names answer `not_available`.

Lesson for the dispatcher: one task, one seat, one worktree. Use `make parallel AGENT=go-backend TASK=...` for a second seat.

## Session 3 (devops, same branch, 2026-09-13): docs/operations/assistant-hosts.md

Head `baa880a0` at the time, pushed to `origin/feat/ac-w2c-update-and-hosts` (draft PR #2833 carries it). Message-only amend in session 4: now `f6ed9fef`, same tree.

### Built

- `docs/operations/assistant-hosts.md`: per host (slot A, slot B), the values and steps to add Olympus, the three API-rendered screens (sign-in, code, consent) with their exact copy, disconnect from the tile (DELETE `/concierge/bindings/{id}`, audit `concierge_unbind`) and why removing the connector inside a host reaches nothing on our side, the per-host kill switch on both doors with the `gcloud` confirm block and the three log queries (`iris.host_denied`, `iris.tool_call` with `refusal_reason=host_denied`, `assistant.client_denied`), and per-binding session queries (`iris.tool_call`, refusals, `iris.quota_exhausted`, `iris.auth_refused`).
- Index rows in `README.md` (Documentation table) and `CLAUDE.md` ("Where to find X"). No docs/operations index file exists; `docs/prd/00-INDEX.md` is PRD pages only, and the new page is not a PRD page, so it was not added there. `make check-prd-index` passes.

### Decisions

- Hosts named by slot only. The four cited URLs (and the two callback URLs) are the only places vendor strings appear, because the task requires citing URL and date; the page says so in its second paragraph. Commit message and this handoff carry no vendor name.
- Host-side facts come only from the four pages the contract's section 6 table cites, fetched live with curl on 2026-09-13 and read as text; nothing from memory. Neither authentication page describes its own UI click path, and the page states that gap instead of inventing one.
- Two live production findings recorded in the preflight rather than fixed (both outside devops scope): `olympus-api-00449-bsg` carries no `ASSISTANT_*` env var, so `GET /.well-known/oauth-authorization-server` on the API answers 404 and no host can connect today; and host B's page says the advertised `resource` must equal the MCP URL the tester types (path included), while ours is the API path `/api/v1/assistant` (Iris advertises it, live 2026-09-13). The second is a go-backend question, flagged as "settle on the first connection attempt".
- Default attribution trailer omitted on purpose: project directive OLY-4 and the task both forbid it.

### Do not repeat

- Do not scan for U+2014/U+2013/U+2015 with plain `perl -ne`: it matches bytes, not code points, and reports zero hits on files full of them. Use `LC_ALL=en_US.UTF-8 grep -nP '\x{2014}|\x{2013}|\x{2015}'` with a positive control file (CLAUDE.md has 34).
- `gcloud run services describe --format 'value(...env)'` prints python-dict text; use `yaml(spec.template.spec.containers[0].env)` and `grep -A1` for a readable check (the page does).
- zsh: `--include=*.go` and `echo =====X` both fail unquoted (glob and `=cmd` expansion).

### Evidence

```
curl $IRIS/.well-known/oauth-protected-resource        200 0.07s, resource=.../api/v1/assistant, authorization_servers=[API], scopes_supported=[assistant]
curl $API/.well-known/oauth-authorization-server        404 "page not found"
curl -si -X POST $IRIS/mcp -d '{}'                       401, WWW-Authenticate resource_metadata=<iris>/.well-known/oauth-protected-resource, scope="assistant"
gcloud run services describe olympus-api ... env        no ASSISTANT_* var (only DATABASE_URL matched); revision olympus-api-00449-bsg
gcloud run services describe olympus-iris ... env       ENVIRONMENT, IRIS_PUBLIC_URL, ASSISTANT_RESOURCE_URI, OLYMPUS_API_URL, OLYMPUS_WEB_URL; revision olympus-iris-00001-mfv
make check-prd-index                                     self-test OK
UTF-8 dash scan, new page + added README/CLAUDE lines    0 hits (control: CLAUDE.md 34)
vendor scan of the new page outside URLs                 0 hits
relative links in the new page                           5/5 resolve
git rev-parse HEAD origin/feat/ac-w2c-update-and-hosts   both baa880a0845bcc0524ae57f5949eb71a72b929f1
```

### Open questions / next hint

- go-backend: the host B `resource` equality requirement above. Either the PRM's `resource` becomes the Iris MCP URL (and the API mints `aud` to match) or the pilot proves host B accepts the mismatch on the first attempt.
- Operator: set `ASSISTANT_RESOURCE_URI` and the six `ASSISTANT_OAUTH_CLIENT_*` values on `olympus-api` before the pilot; the page's preflight step 1.
- Whoever runs the first host A connection: copy the redirect URI from the host's management page into `ASSISTANT_OAUTH_CLIENT_A_REDIRECT_URIS`; the cited page gives two possible shapes and only the management page says which applies.

## Session 4 (devops, verification pass, 2026-09-13)

Dispatched with the same task as session 3. Found the work already at `baa880a0` on local and origin, so the page was not rewritten; the session 3 claims were re-checked against the tree, not taken from the handoff.

### Evidence

```
git rev-parse HEAD origin/feat/ac-w2c-update-and-hosts          both baa880a0 before the amend, both f6ed9fef after
docs/operations/assistant-hosts.md                                226 lines; sections: Sources (4 URLs, same four as contract section 6, dated 2026-09-12 + re-read 2026-09-13), preflight, host B steps, host A steps, consent page (3 screens), Disconnecting, kill switch + confirm queries, per-binding session queries
make check-prd-index                                              self-test OK
LC_ALL=en_US.UTF-8 grep -P U+2014/2013/2015 and " -- "            0 hits in page, in the README/CLAUDE index lines and in the commit message (control: 34 in CLAUDE.md)
vendor scan, page with URLs stripped by sed                       0 hits
commit message                                                    no Co-Authored-By, no "Generated with", no vendor name
relative links in the page                                        5/5 resolve
README.md:144, CLAUDE.md:159                                      index rows present; no docs/README.md or docs/operations index file exists
gh pr view 2833                                                   OPEN, draft, head feat/ac-w2c-update-and-hosts
```

### Built

- PR #2833 body: appended a short section describing the docs page (it carried the commit without mentioning it) and ticked the project-instructions-file checklist line, which was stale.
- Tip commit message amended (message only, tree unchanged) to say "the project instructions file" instead of that file's name, matching the PR template's wording; pushed with --force-with-lease, `baa880a0` -> `f6ed9fef`. The session 3 evidence line "no vendor name" for the commit message had missed the filename.

### Do not repeat

- Do not write the project instructions file's name into commit or PR text; the PR template says "Project instructions file" for that reason. Grep exit codes: 0 means a hit was found, read them before writing "0 hits".
- Do not re-dispatch this task a third time; the page is on the branch. Remaining work is the two open questions in session 3 (API `ASSISTANT_*` env vars unset in production; host B `resource` equality), both outside this page.

## db-architect slice (same branch, revision predicate, #2340 item 1)

### Built

- `apps/api/db/queries/result_sessions.sql`: `UpdateResultSessionFieldsAtRevision :one` (WHERE id, deleted_at IS NULL, revision = expected_revision; SET revision = revision + 1; RETURNING *), `GetResultSessionRevision :one`, and `UpdateResultSessionFields` unchanged in predicate and signature but now bumping revision on every write.
- `apps/api/db/generated/{querier.go,result_sessions.sql.go}` regenerated. New params struct `UpdateResultSessionFieldsAtRevisionParams` carries `ExpectedRevision int32`.

### Decisions

- The unguarded query bumps revision too. A predicate only catches a stale writer if every writer moves the counter; without this the website's refine leaves revision where it was and the guarded write with the old value still matches (the critic's exact scenario). The bump is invisible to the unguarded caller.
- Not-found, soft-deleted and stale all surface as zero rows (`pgx.ErrNoRows` on `:one`). The service tells them apart with `GetResultSessionByID` after the miss; the query stays a single atomic statement.

### Do not repeat

- Do not add a second migration for this; the column from 20260911080505 is already applied and sufficient.
- Do not make the unguarded query soft-fail on revision; the website does not send one yet and must keep working.

### Evidence

```
cd apps/api/db && sqlc generate                   exit 0
cd apps/api && go build ./... ; go vet ./internal/store/... ./db/...   exit 0 / exit 0
docker exec olympus-postgres psql ... (BEGIN ... ROLLBACK)             exit 0
  read revision -> 1; unguarded write -> 2; guarded with expected 1 -> UPDATE 0, row intact;
  guarded with expected 2 -> revision 3; soft-deleted + guarded with expected 3 -> UPDATE 0
long-dash / vendor-name scan of the db diff                            no hits
```

### Next hint (wave 2, go-backend + api-designer)

- `store/postgres/result_sessions.go:105`: add a store method around `UpdateResultSessionFieldsAtRevision`; on `ErrNoRows` re-read with `GetResultSessionByID` to split 404 from conflict.
- PATCH `/result-sessions/{id}` takes `revision`; the ResultSession shape exposes it; Iris then drops `assistant_trip_revision` from `parsed_fields`.

## Critic fix (go-backend, same branch, 2026-09-13): #2340 "CRITIC W2C UPDATE AND HOSTS" items 1, 2, 4 and the red Iris job

Head `c699bb58` on top of the db wave `d37c855b`, pushed; PR #2833 still a draft.

### Built

- apps/api: `ResultSessionRow.Revision` and `ResultSession.Revision` (`revision` on the wire); `PatchRequest.ExpectedRevision` / `expected_revision`; `ResultSessionStore.UpdateFieldsAtRevision` in both stores (postgres over `UpdateResultSessionFieldsAtRevision`, re-read on zero rows to split 404 from stale; memory with a counter that every write bumps); `service.Update` goes through `updateAtRevision` when the field is present, with the blob merged key by key (`mergeParsedFieldsDelta`, null removes a key); `ResultSessionStaleRevisionError{Current}` mapped to 409 with the current record in `data`; the assistant scope (`caller.OwnerOnly`) must send `expected_revision`, checked after ownership (`ErrResultSessionRevisionRequired`, 400).
- services/iris: `olympus.Session` gained `revision` and `chat_conversation_id`; `SessionPatch.ExpectedRevision` always sent; `doJSON` returns the raw 409 body as `conflictBody`, `UpdateSession` turns it into `*ConflictError{Current}`. `update_trip`: one read, linked pre-check (`not_available`), host revision check (`stale_revision` + `current`), delta PATCH, 409 mapped to `stale_revision` + `current`. No lock, no second read, no `assistant_trip_revision` key anywhere. get_trip / list_trips report `sess.Revision`.
- Matrix fixture wires every conditional service; 88 routes; dev-only class with a production-router proof; must-be-present list extended.
- Test harness: JSON log handler drops `time` (the CI flake root cause).

### Decisions

- The guarded PATCH is a key-by-key delta, not a replace. Forced by critic test 1 as written (a direct edit of the blob without any counter must survive a title edit) and correct on its own: the predicate proves the merge base is the stored blob. The website's PATCH keeps replace semantics; two behaviours on one route, selected by the presence of `expected_revision`, documented on `PatchRequest.ExpectedRevision`.
- A searched record is at revision 2 (POST creates at 1, the refine that runs the search bumps). Every test that assumed 1 was shifted; the critic's first test had its `revision` literal replaced by the record's value (documented in the file header and the PR). Do not make the fake skip the bump on refine to keep a literal alive: the real API bumps.
- 409 maps to `stale_revision`, per the dispatch. `revision_conflict` is emitted by no tool now; flagged again for the PRD owner.
- `/dev/duffel-raw` names Duffel and sits under OptionalAuth; classified "dev-only, absent in production" only after a production-environment fixture proves it is not registered there. Not argued into the public class.

### Do not repeat

- `echo =====` unquoted fails in zsh (`=cmd` expansion); quote it. `${PIPESTATUS[0]}` is bash; in zsh use `$pipestatus[1]` or run the command without a pipe and read `$?`.
- The Edit tool needs a Read-tool read first; `cat` in bash does not count.
- `gofmt -l .` in apps/api lists pre-existing unformatted files (places_photo.go, maps.go and others); check only the files you touched.
- Do not write `Co-Authored-By` or a "Generated with" footer; the task and OLY-4 forbid them even when the session preamble asks for them.

### Evidence

```
services/iris  go test -race -count=1 ./...      7/7 ok, exit 0; golangci-lint 0 issues; gofmt -l . empty
apps/api       go test -race -count=1 ./...      24 packages ok, exit 0; golangci-lint handler/service/store 0 issues
critic tests   iris 2/2 PASS exit 0; api 1/1 PASS exit 0
matrix         routes=88 assistant_surface=7 scope_gated=47 public=27 non_bearer_gated=6 dev_only=1 money_routes=21 money_blocked=21
make check-service-isolation   passed (52 files); make check-api-spec   OK 88 routes
dash / vendor scan of added lines   0 hits (identifier false positive mergeStringPtr)
```

### Open questions / next hint

- api-designer: `revision` on `ResultSession`, `expected_revision` on `PatchResultSessionRequest`, `409` on PATCH in api.yaml; `make generate`.
- PRD owner: `stale_revision` vs `revision_conflict` in 3.3.7 / 3.4 (see the PR).
- devops: `services/iris/README.md` still says update_trip answers not_available (lines 23, 77) and describes the blob counter.
- Refine's search revision is still a blob counter with the Iris lock; its API write (refine) has no predicate. Not in this slice.

## Critic item 6 (devops, same branch, 2026-09-13): docs/operations/assistant-hosts.md lines 47, 62, 74

Head `9b670168`, pushed; PR #2833 still a draft. One file, three lines, nothing else.

### Built

- Line 47 (client secret row): stated per source instead of "both hosts, contract section 6". Our side: no secret registered (`env-vars-api.md`, six `ASSISTANT_OAUTH_CLIENT_*` rows, no secret row) and the discovery document advertises `token_endpoint_auth_methods_supported: ["none"]` (`assistant_oauth.go:188`). Host B: blank secret field means public client (host B Authentication, "Custom connectors"). Host A: PKCE `S256` required (host A Authentication, "Support the authorization-code flow"); the cited pages do not say whether the predefined client takes a secret, so the line says to stop and report if the screen asks.
- Line 62: dropped "prompts before update_trip". `update_trip` declares `readOnlyHint` false, `destructiveHint` false (`services/iris/README.md` manifest table, `tools.go:374`); the checklist binds the always-prompt behaviour to `destructiveHint` true. The line now states what the annotations cause, says the cited page is silent on a tool that is neither, and notes a prompt would need `destructiveHint` true, a contract decision (sections 3.3.7 and 6).
- Line 74: same UI disclaimer as line 18 (cited pages do not describe the screen; stop and report on an unlisted field).

### Do not repeat

- Do not cite "contract section 6, both rows" for a host-side fact; the contract rows summarise the same four pages, so cite the page and section that carries the fact, per host.
- Do not write "prompts before X" for any tool with `destructiveHint` false; the prompt is bound to the hint, and the hint is a contract field, not a doc claim.

### Evidence

```
make check-prd-index                                              exit 0 (32 pages, self-test OK)
LC_ALL=en_US.UTF-8 grep -P U+2014/2013/2015 and " -- " on the page   exit 1, no hits (control: CLAUDE.md 34)
vendor scan of added lines with URLs stripped                     exit 1, no hits
git diff --stat before commit                                     1 file, 3 insertions, 3 deletions
git rev-parse HEAD origin/feat/ac-w2c-update-and-hosts            both 9b670168
commit message: Co-Authored-By / Generated with / dash scan       exit 1, clean
```
