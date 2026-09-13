# Handoff: feat/ac-handover-identity, db wave (#2340)

## Built
- `apps/api/db/queries/result_sessions.sql`: `CreateResultSession` now carries `source` (nullable, `COALESCE(sqlc.narg(source)::text, 'web')`); new `CloneResultSessionForUser` (INSERT ... SELECT, atomic, strips `assistant_owner` and `assistant_revision`, empty transcript, zero rows when source missing / soft-deleted / already the caller's).
- `apps/api/db/generated/*`: sqlc output. `CreateResultSessionParams.Source pgtype.Text`; `CloneResultSessionForUserParams{OwnerUserID, SourceID pgtype.UUID}` returning `db.ResultSession`.
- Commit b1c3955f, draft PR #2845.

## Decisions
- No `origin` column and no migration. PRD 06-conversation-results 13.3.3 binds the origin to the existing `result_sessions.source` column (`'assistant'` vs anything else) and the clone contract says "Keeps the origin (`source`)". The column, `NOT NULL DEFAULT 'web'` and the CHECK admitting `'assistant'` already exist (000033, widened by 20260911080505). A second column for the same fact would be two sources of truth. If a separate `origin` column is still wanted, that is a PRD change first (co-founder sign-off), then a one-column migration; the queries here would then carry both.
- The nullable `source` parameter means the untouched Go caller in `internal/store/postgres/result_sessions.go` still inserts `'web'` rows at runtime. go-backend: extend `ResultSessionStore.Create` to pass `'assistant'` from the assistant channel, and wire `/clone` on `CloneResultSessionForUser` (service reads the source with `GetResultSessionByID` first to tell 404 from 409; the query's own predicate is the race guard).
- Key strip lives in SQL (`parsed_fields - 'assistant_owner' - 'assistant_revision'`) so the copy is one statement; nothing in Go needs to post-process it.

## Do not repeat
- Unaliased `INSERT INTO t ... SELECT ... FROM t WHERE id = $1` fails sqlc analysis with "column reference id is ambiguous" (Postgres accepts it). Alias the source table.
- `COALESCE(sqlc.narg(x), 'web')` types the param as `interface{}`; add `::text`.
- `make check-migration-filenames` needs `GITHUB_REPOSITORY=Arlencho/olympus-platform` and a real `PR_NUMBER` (script fetches PR files via gh).

## Evidence
- `sqlc generate` / `sqlc diff` / `sqlc vet`: exit 0.
- `go build ./...` (apps/api): exit 0. `go test ./internal/store/... ./db/...`: ok.
- Local DB, rolled-back transaction: `create-null-source=web`, `create-assistant=assistant`, clone `id_differs=true owner=<caller> source=assistant parsed={"destination": "Rome"} offer=off_1 chat_null=true revision=1`, `owner-clone-rows=0`, source row unchanged.
- `PR_NUMBER=2845 python3 scripts/check-migration-filenames.py`: "no new migration files", exit 0.

## Open questions
- Whether the orchestrator's plan wanted a distinct `origin` column for a reason not in the PRD. If so, see Decisions.

## Next hint
- go-backend: `Source` on create, `/clone` handler on `CloneResultSessionForUser`, api.yaml for the clone endpoint (api-designer).
