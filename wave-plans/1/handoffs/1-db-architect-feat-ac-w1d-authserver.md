# Handoff: durable Google return-context association (PR #2815, wave 1 db)

Scope of this pass: SECURITY W1D AUTHSERVER ROUND 2 finding N1 (MEDIUM)
only, and only the database half of it. No Go code was touched: wave 2
wires the queries into the handler and service.

## Built

- `apps/api/db/migrations/20260912131511_assistant_authorize_request_google_state.sql`
  Adds one nullable column, `assistant_authorize_requests.google_state_nonce_hash`,
  with a `^[0-9a-f]{64}$`-or-NULL CHECK, a column COMMENT, and a unique
  partial index (`WHERE google_state_nonce_hash IS NOT NULL`). Down drops
  index, constraint and column.
- `apps/api/db/queries/assistant_authorize_requests.sql`
  `SetAssistantAuthorizeRequestGoogleState` (by `request_id_hash`, guarded
  on `consumed_at IS NULL AND expires_at > cutoff`) and
  `PopAssistantAuthorizeRequestByGoogleState` (by nonce digest, sets the
  column back to NULL and RETURNS the row in one statement). Both `:one`,
  both `RETURNING *`.
- `apps/api/db/generated/` regenerated (sqlc v1.30.0, the version CI pins).

## Decisions

- **Column, not a table.** The association has exactly the lifetime of the
  pending request (same 10 minute TTL), so it inherits the request's
  expiry, cleanup sweep and `user_id ON DELETE CASCADE` for free. This is
  also the fix N1 itself proposed.
- **Hashed at rest.** The nonce travels in a query string, so Google and
  every proxy see it; only the SHA-256 hex digest is kept, matching the
  hashes-only posture of migration 20260912120437. The caller hashes
  (`hashAssistantSecret`) and the CHECK rejects a raw value with 23514.
- **Pop returns the whole request row**, so wave 2 continues by
  `request_id_hash` (mark authenticated) and never needs the raw request
  id back. The raw id is deliberately never at rest, so a pop that had to
  return it would have forced plaintext into the table.
- **`::text` casts on both parameters.** On a nullable column sqlc would
  otherwise hand the caller a `pgtype.Text`; a zero value on the setter
  would silently CLEAR the association instead of setting it. With the
  cast both params are plain non-null `string`. This is a type-forcing
  cast in the parameter position, not an inert predicate of the kind the
  `ci.yml` db-integration note warns about.
- **Set overwrites.** A second Google leg on the same request replaces the
  nonce; the abandoned nonce then finds nothing and falls through to the
  ordinary web sign-in, the same fail-closed outcome as expiry. The
  in-memory map kept both. Documented in the query comment.

## Wave 2 notes (not done here, by instruction)

- `handler/google_oauth.go:74` (`returnContextMu`/`returnContexts`), `:151`
  (`storeReturnContext`) and `:183` (`popReturnContext`) are what these two
  queries replace. `:295` is the call site, already correctly placed after
  the state HMAC verifies.
- The store seam takes digests, the service hashes: keep that split, hash
  the nonce in the service and pass the digest down.
- `HandleGoogleReturn` currently takes a raw `authorizeRequestID`. The pop
  returns the row, not the raw id, so that signature has to change (or the
  service exposes a mark-authenticated path keyed by `request_id_hash`).
  That is a handler-side decision, hence wave 2.
- N4 from the same review (the stale "no Go code is changed here" header on
  20260912120437) is untouched: that file is applied elsewhere and is not
  mine to rewrite in this pass.

## Do not repeat

- `make migrate-create` needs goose on PATH: it is at `$(go env GOPATH)/bin/goose`
  (v3.27.0), not in `/opt/homebrew/bin`.
- The filename gate reads the PR's ADDED files from the GitHub API, so it
  fails misleadingly ("older than the base branch") when the new migration
  exists only locally. Run it AFTER pushing. It also needs both
  `GITHUB_REPOSITORY` and `PR_NUMBER`.
- You cannot seed an already-expired `assistant_authorize_requests` row:
  the `expires_after_created` CHECK forbids it. Test expiry by moving the
  `cutoff` parameter forward instead.
- psql without an explicit `BEGIN` cannot use SAVEPOINT, so negative checks
  need either a transaction block or their own invocation.

## Evidence

```
$ make migrate-create NAME=assistant_authorize_request_google_state
Created new file: db/migrations/20260912131511_assistant_authorize_request_google_state.sql
EXIT:0

$ cd apps/api/db && sqlc generate
SQLC_EXIT:0
$ make sqlc-generate && git status --porcelain apps/api/db
SQLC_MAKE_EXIT:0        (no output: generated tree matches the queries)

$ GITHUB_REPOSITORY=Arlencho/olympus-platform PR_NUMBER=2815 python3 scripts/check-migration-filenames.py
PR #2815 adds migration version(s): ['20260912120437', '20260912131511']
OK - timestamped, no collisions across 13 open PR(s).
FILENAME_GATE_EXIT:0    (run after the push; before it, exit 1, see Do not repeat)

$ cd apps/api && go build ./...
GO_BUILD_EXIT:0
$ go vet ./internal/store/... ./internal/service/...
GO_VET_EXIT:0
```

Migration up/down/up on a throwaway database (`migtest_w1d`, postgres:16-alpine,
dropped afterwards):

```
GOOSE_UP_EXIT:0     ... OK 20260912131511_... (6.52ms), migrated to version: 20260912131511
GOOSE_DOWN_EXIT:0   ... OK 20260912131511_...
  columns_after_down:0    index_after_down:0
GOOSE_UP_AGAIN_EXIT:0
  columns_after_reup:1
```

Query behaviour, same database, statements identical to the two sqlc bodies:

```
SET on an open request          -> UPDATE 1   (SET_OPEN_ok)
SET with cutoff past the TTL    -> UPDATE 0
POP by nonce                    -> UPDATE 1, returns the row, cleared = t
POP again (replay)              -> UPDATE 0
POP with an empty nonce         -> UPDATE 0   (NULL never matches)
POP on a consumed request       -> UPDATE 0
raw unhashed nonce              -> ERROR 23514 assistant_authorize_requests_google_state_nonce_hash_format
two requests, one nonce         -> ERROR 23505 idx_assistant_authorize_requests_google_state_nonce_hash
```

Commit `d65edf25`, pushed to `feat/ac-w1d-authserver`. Files touched: five,
all under `apps/api/db/`.
