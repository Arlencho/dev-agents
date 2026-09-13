# Handoff: feat/ac-handover-identity

## Built
- `docs/prd/pages/assistant-channel.md`: 3.2 gains the landing sentence; new 7.4 The handover landing (three cases plus the owner-only rule); section 9 gains the copy-case line as S20, PROPOSED.
- `docs/prd/pages/06-conversation-results.md`: section 4 gains the assistant-origin Direct URL row; new 13.3.3 Assistant-originated records (401 / 403 not_owner / 200 / byte-identical 404); 13.6 clone row is now contract with the field list, key stripping, and 401 / 404 / 409.
- Commit `0a07e409`, pushed. No PR opened (not requested).

## Decisions
- The sign-off names the new string S19, but S19 was already taken the same day by the `How to connect` label (commit acb8f856). Recorded as S20 with the collision noted in the row; renumbering a ratified string would break its reference.
- "Origin" is expressed as `result_sessions.source = 'assistant'` (migration 20260911080505). `assistant_owner` and `assistant_revision` are keys inside `parsed_fields` (Iris writes them), so 13.6 says "from the copied parsed_fields".
- The default modal line lives in `01-conventions.md` 8.2 (the comment says 9.1, which is the soft wall that reaches it); cited both.
- No Co-Authored-By trailer: task, board directive OLY-4 and git-ship rule all forbid it.

## Do not repeat
- Do not add a top-level `origin` field to the entity shape; the column is `source`.
- Do not renumber S19.

## Evidence
- `make check-prd-index` exit 0 (32 pages, 38 links, self-test OK).
- Added-lines scan: no U+2014 / U+2013 / U+2015, no " -- ", no vendor names, no trailer.
- `git log --oneline -1` -> `0a07e409 docs(prd): assistant handover identity, sign in first then own-or-copy (#2340)`.

## Next hint
- Implementation slices per the comment: API clone endpoint (`POST /result-sessions/{id}/clone`, 13.6) and the 401/403 gate on GET for `source = 'assistant'` (13.3.3); web landing gate with the mounted modal (7.4). `docs/prd/00-INDEX.md` row for assistant-channel still says "Nine new strings"; stale, out of this task's scope.
