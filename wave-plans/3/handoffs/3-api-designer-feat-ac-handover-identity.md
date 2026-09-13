# Handoff: feat/ac-handover-identity (wave 3, api-designer)

## Built

Commit `aa195627` on `feat/ac-handover-identity`, pushed with upstream.

- `api.yaml`
  - `ResultSession.origin` (enum `web`, `assistant`), required, present on both projections. `assistant` when `result_sessions.source = 'assistant'`, `web` for any other stored source (the column also admits telegram, whatsapp, ios, android; the access matrix keys only on the assistant bit, so the wire enum stays at two values).
  - `GET /result-sessions/{id}`: security now `BearerAuth`, `AsidCookieAuth`, anonymous. Documents 401 (guest on an assistant record), 403 `not_owner` (signed-in non-owner on an assistant record), 200 interactive for the owner, and the 404 body being identical whatever the caller's auth. Web records unchanged.
  - `POST /result-sessions/{id}/clone` rewritten to PRD 06 section 13.6 / 13.3.3: 201 full interactive entity with example, 401, 404 (same body as the GET 404), 409 `already_owner`. No 403. Description lists what is copied, the stripped `assistant_owner` / `assistant_revision` keys, origin kept, transcript not copied.
  - The PATCH 409 example gained `origin: "web"` so it still conforms to the schema.
- `scripts/check-openapi-routes.py`: clone entry removed from `SPEC_ALLOWLIST`; comment updated (claim and DELETE remain, still pointing at #856).
- `packages/api-client/types.ts` and `apps/web/lib/generated-types.ts` refreshed by `make generate` and committed (#2834).

## Decisions

- `origin` is required. The column is NOT NULL DEFAULT 'web' since wave 2 (`b1c3955f`), so every row has a value; the handler in wave 4 must emit it on every read.
- No 400 or 500 on the clone operation: the task asked for the PRD row exactly (201, 401, 404, 409) and the neighbouring create operation has no 500 either.
- 401 carries no `error_code`: the PRD names a code only for the 403 (`not_owner`) and the 409 (`already_owner`); the page maps the 401 on status alone.
- The GET keeps a single 404 shape for all origins, as the PRD's last matrix row requires.

## Do not repeat

- Adding a `required` property to `ResultSession` breaks every existing example of the envelope; redocly's type-gen pass reports it as `Example value must conform to the schema`. Grep for `view_mode: "interactive"` examples when touching that schema's required list.
- `grep ... | head; echo $?` reports head's exit code. Redirect grep to a file and read its exit code directly.
- The attribution trailer the harness asks for is blocked by the live commit-msg hook and by the project's board directive; leave it off.

## Evidence

- `npx @redocly/cli lint api.yaml`: exit 0, "Your API description is valid", 13 warnings (14 before the PATCH example fix; none reference result-sessions or origin).
- `make generate`: exit 0; `cmp packages/api-client/types.ts apps/web/lib/generated-types.ts` identical.
- `make check-api-spec`: exit 2, expected until wave 4 wires the handler:

```
Go routes registered:        88
OpenAPI paths declared:      83
Runtime allowlist (Go-only): 13
Spec allowlist (spec-only):  4

FAIL: OpenAPI paths with NO matching Chi handler:
  Either implement the handler, fix the spec path, or add to
  SPEC_ALLOWLIST with a tracking issue.

   POST    /api/v1/result-sessions/{param}/clone

  1 ghost route(s) — see issue #806.

make: *** [check-api-spec] Error 1
```

- After the commit: `make generate` exit 0 and `git status --short` empty.
- Dash and vendor scans over every added line of the four committed files: zero hits.

## Open questions

- PRD 06 section 13.1 (the entity table) does not list `origin` as a wire field; the concept appears only in prose (section 1 direct-URL row, section 13.3.3). A one-line table entry is due from whoever owns the PRD edit in this wave; `docs/` is outside this agent's grant.
- PRD 06 section 13.6 says "409 Conflict when the caller already owns the source" without naming the code. The spec names it `already_owner` per the task; the PRD row should say so too.

## Next hint

Wave 4 (go-backend): the handler must emit `origin` on every ResultSession read, answer 401 / 403 `not_owner` on GET for assistant records, and wire `POST /result-sessions/{id}/clone` on top of `CloneResultSessionForUser` (404 when the source is missing or deleted, 409 `already_owner` when the caller owns it). `make check-api-spec` goes green when the route is registered.
