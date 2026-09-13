# Handoff: feat/ac-two-hosts, one live assistant binding per traveller per host (db-architect)

Branch `feat/ac-two-hosts` off `origin/main` at `601ec639`, head `62f51ebd`. Draft PR #2835, Closes #2825, Refs #2800. Not merged.

## Built

All under `apps/api/db/`:

- `migrations/20260913080426_channel_bindings_assistant_per_host.sql` (generated with `make migrate-create`, no `-s`). Up: drops `idx_channel_bindings_active_user_channel` and recreates it with the same name and key `(channel, user_id)`, predicate `revoked_at IS NULL AND channel <> 'assistant'`; creates `idx_channel_bindings_active_user_channel_assistant` on `(channel, user_id, external_id)` with predicate `revoked_at IS NULL AND channel = 'assistant'`. Down: drops both, restores 000033's index verbatim.
- `queries/channel_bindings.sql`: new `RevokeReplacedUserChannelBindings(channel, user_id, external_id) :many RETURNING id`, predicate `revoked_at IS NULL AND (channel <> 'assistant' OR external_id = $external_id)`. The `CreateChannelBinding` comment now names all three partial indexes.
- `generated/channel_bindings.sql.go`, `generated/querier.go`: sqlc v1.30.0 output.
- `migrations_test/channel_bindings_assistant_per_host_integration_test.go`: five `TestAssistantPerHost_*` tests (index definitions pinned via `pg_indexes`, Telegram 23505 under the unchanged constraint name, two hosts live at once, the query's per-channel behaviour, down round trip).

## Decisions

- Two partial indexes with disjoint predicates rather than one expression index (`CASE WHEN channel = 'assistant' THEN external_id ELSE '' END`). The task asked for Telegram to be byte-for-byte unchanged; keeping 000033's index name and key columns means the same 23505 constraint name reaches `disambiguateBindingConflict` in `store/postgres/channel_bindings.go`, which matches on the string `idx_channel_bindings_active_user_channel`. An expression index would have changed the key and forced a Go change to keep the error naming.
- The assistant index is knowingly implied by `idx_channel_bindings_active_identity` (external_id already encodes `(client_id, user_id)` since #2815). Kept anyway because the issue asks for the user axis to be stated in its own terms and it survives a future change to the identity derivation.
- The replace flow's user side was a Go loop over `GetChannelBindingsByUser` filtering on channel only, not a query. Added one query that encodes the rule in SQL so the index and the replace predicate live side by side; did not touch the Go call site (out of scope).
- Down is exact and will fail with 23505 if a traveller holds two live assistant rows at rollback time. Documented in the file header as intended.
- No CONCURRENTLY: goose wraps the file in a transaction, and the file follows the 000033 / 20260911080505 precedent at pilot table sizes.

## Do not repeat

- `make migrate-create` fails with `goose not found` unless `~/go/bin` is on PATH (`export PATH="$PATH:$HOME/go/bin"`); goose is installed there already.
- `make check-migration-filenames` exits 2 with `GITHUB_REPOSITORY env var not set` unless you export `GITHUB_REPOSITORY=Arlencho/olympus-platform`; the runbook's "inferred from gh" claim is wrong (noted in the PR's first comment, devops owns the doc).
- `psql` is not installed locally; use `docker exec olympus-postgres psql -U olympus -d olympus -Atc "..."`.
- `PIPESTATUS` is bash; in this zsh shell use `${pipestatus[1]}` or avoid pipes when you need the exit code.
- Do not commit `handoff.md`; the scope hook only allows `apps/api/db/`.

## Evidence

```
make migrate-create NAME=channel_bindings_assistant_per_host   exit 0 -> 20260913080426_channel_bindings_assistant_per_host.sql
make migrate       exit 0   (goose: successfully migrated database to version: 20260913080426)
make migrate-down  exit 0   (pg_indexes: idx_channel_bindings_active_user_channel ... WHERE (revoked_at IS NULL); assistant index gone)
make migrate       exit 0
cd apps/api/db && sqlc generate                                   exit 0
go build ./...                                                    exit 0
go vet -tags=integration ./db/migrations_test/...                 exit 0
go test -tags=integration -count=1 -v ./db/migrations_test/...   exit 0   13 PASS, 0 FAIL, 0 SKIP
go test -tags=integration -count=1 ./internal/store/postgres/...  exit 0
golangci-lint run --build-tags integration ./db/...              0 issues
GITHUB_REPOSITORY=Arlencho/olympus-platform PR_NUMBER=2835 make check-migration-filenames   exit 0
house style: no U+2014/U+2013/U+2015 or " -- " in new files or added lines; no vendor names; no Co-Authored-By trailer
```

## Next hint

go-backend, one function plus its mirror: replace the loop in `revokeActiveUserChannelBindings` (`apps/api/internal/store/postgres/channel_bindings.go`) with `qtx.RevokeReplacedUserChannelBindings(ctx, db.RevokeReplacedUserChannelBindingsParams{Channel, UserID: uid, ExternalID: externalID})` and map the returned ids; make `MemoryChannelBindingStore.CreateBindingReplacingActive` in `service/concierge.go` apply the same rule (`r.ExternalID == externalID || (r.UserID == userID && channel != model.ChannelAssistant)`); optionally add `idx_channel_bindings_active_user_channel_assistant` to `disambiguateBindingConflict`. Update the comment block above `CompleteConsent` in `service/assistant_auth.go` that describes #2825 as pending. Until that lands the database permits two hosts but the store still revokes host A on host B's consent.

## Open questions

- Should #2825 stay open until the go-backend swap merges? The PR says `Closes #2825` per the task; the orchestrator may prefer to reopen or track the Go half under #2800.
