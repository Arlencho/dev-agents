# Handoff: feat/ac-host-carries-intent, wave 2 (services/iris)

Commit `cbe92c99` on `feat/ac-host-carries-intent`, on top of the PRD amendment `e2339afb`. Draft PR #2841 (the PR that already existed for this head; GitHub allows one PR per branch, so the code rides in it).

## Built

- `services/iris/internal/current/` (new): the per-binding current-search pointer. `Store` interface, `MemoryStore`, `RedisStore` over the quota's Redis client (`quota.RedisStore.Client()`), `Pointer` keyed `iris:current_search:<binding_id>`, TTL 30 days from the last set.
- `tools.Registry` gains `Current`; `resolveID` (host-named id, else the pointer, else `not_found` with `hint`), `remember` (set after every served search and refine, in `runSearch` and `runRefine` after `readSettled`).
- `refine`: `revision` gone from `refineArgs` and the schema; `search_id` optional. The record is read in `refine()`, its search revision becomes `searchRequest.ExpectedRevision` (internal, rides inside a clarification question), and the locked re-read in `runRefine` refuses a mismatch with `revision_conflict` carrying `searchPayload(sess)`. Lock and `readSettled` from PR #2838 untouched.
- `update_trip`: `revision` gone from `updateArgs` and the schema; `trip_id` optional. The PATCH is predicated on the revision read just before it; the API 409 maps to `revision_conflict` with the current trip. Log event renamed `iris.stale_revision` to `iris.revision_conflict`.
- `get_option`: optional `search_id`; the option must belong to the named or current search, else `not_found`.
- `intent_change` on refine: code `intent_change`, `hint: {next_tool: "search", reason: "stay_required_changed"}`, refused before any place is resolved or anything metered.
- `mcp.ErrorPayload.Hint`, `mcp.Hint`, `mcp.HintedResult`.
- `cmd/iris/main.go` wires the pointer beside the meter on the same Redis connection (memory store outside production, as for the quota).

## Decisions

- "Most recent search on that binding" means the last search this binding was served through `search` or `refine`. A refine that names an older search moves the pointer to it (pinned by `TestTwoSearchesThenARefineWithNoIDTargetsTheNewest`).
- A pointer that cannot be written does not un-serve a search that ran and was paid for: alert `iris_current_unset`, result still returned. A pointer that cannot be read is `upstream_unavailable`, never a guess at the newest record by other means.
- `get_option` with no `search_id` and no current search is `not_found` with a hint, as the task asked, even though the option id itself names its record. Strict reading of section 3.2 ("presenting it under a different binding resolves to nothing").
- Hint on `not_found`: `next_tool` is `search` for refine and get_option, `list_trips` for update_trip (the tool that yields a trip id).
- The burst guarantee ("a retry loop of identical refines costs one search") survives without a host revision because the predicate is the revision Iris read before the lock; the test uses a barrier (`burstAPI`) so all 80 first reads land before the winner commits.
- README stays with devops per the go-backend role brief; its section on revisions (line 108, "refine requires the host's revision") is now stale and is flagged in the PR body.

## Do not repeat

- Do not name a test helper `current` in package `tools`: it shadows the imported package (renamed to `currentState`).
- `failingStore` already exists in `search_test.go` (a quota double); the pointer double is `downPointerStore`.
- A blanket regex removing `"revision":N,` in `search_test.go` would also hit the API envelope fixture at line ~557; edit that file by exact string.
- The `cd` in a compound command drifts the working directory for the rest of the session; use absolute paths.

## Evidence

At `cbe92c99`, in `services/iris`:

- `go vet ./...` exit 0
- `go test -race -count=1 ./...` exit 0 (8 packages ok, including the new `internal/current`)
- `go test -race -count=5 -run 'TestRefine|TestIdentifier|TestTwoSearches|TestNoCurrentSearch|TestCurrentSearch|TestUpdateTrip|TestSchemasCarryNoRevision|TestCritic' ./internal/tools/` exit 0
- `golangci-lint run ./...` 0 issues, exit 0
- `make check-service-isolation` exit 0 (57 files, no `apps/api` imports, no database drivers)
- house-style scan over the 16 changed and new files: 0 hits for U+2014, U+2013, U+2015, ` -- `, and vendor names

## Open questions

- PRD section 3.4 describes `hint` on `intent_change` only. `not_found` with a `hint` when the host names no identifier and the binding has no current search is what the task asked for; it needs a one-line addition to section 3.4 (or 3.3.3/3.3.4/3.3.7) by whoever holds the PRD.
- `services/iris/README.md` line 108 still says refine requires the host's `revision` and describes the pre-amendment concurrency; devops owns that file.
- `create_checkout` (Wave 3) also lost `revision` in the PRD; nothing to do in Iris until Wave 3 exists.

## Next hint

The pointer TTL (30 days) is a constant in `internal/current/current.go` (`DefaultTTL`); if the pilot wants a shorter memory, that is the one place.
