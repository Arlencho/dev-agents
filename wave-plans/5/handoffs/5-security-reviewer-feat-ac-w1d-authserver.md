# Handoff: gate + docs gaps on feat/ac-w1d-authserver (PR #2815)

Scope of this pass: CRITIC W1D AUTHSERVER items B2 and B6, plus the two
SECURITY W1D AUTHSERVER MEDIUM findings about routes and env vars.
Nothing else on either review was touched: B1, B3, B4, B5 and the
remaining security findings are the producer's, and several already have
commits on this branch ahead of mine.

## Built

- `scripts/check-openapi-routes.py`: nine `RUNTIME_ALLOWLIST` entries for
  the assistant OAuth surface (two `.well-known` discovery documents,
  authorize, Google login, magic-link request and verify, consent, token,
  revoke). One-line reason per entry, `#2799` on each.
- `docs/operations/env-vars-api.md`: new section "Assistant-channel
  authorization server env vars" with a row per var
  (`ASSISTANT_RESOURCE_URI` plus the six
  `ASSISTANT_OAUTH_CLIENT_A/B_{ID,NAME,REDIRECT_URIS}`), the
  comma-separated parsing and exact-match semantics spelled out, and what
  leaving each one unset actually does.
- `scripts/check-env-vars.py`: the six client-slot vars added to
  `ALLOWLIST_DOC_NOT_IN_CODE` with the reason and a delete-when condition.
- `.env.example`: commented entries for the same seven vars. This file IS
  in the DevOps scope (`.env.example` at any level), so it was not skipped.

Four files, additions only, no production Go code touched.

## Decisions

- **Allowlist, not `api.yaml`.** Root `CLAUDE.md` names OAuth browser
  redirects and back-channel endpoints as exactly what `RUNTIME_ALLOWLIST`
  is for, and `api.yaml` is API Designer's file. Publishing these would
  also put methods on the generated TypeScript client for legs that have
  no JSON body to type and do not use the `{ "data": T }` envelope.
- **`.well-known` entries written in the `/api/v1/...` shape.** They are
  mounted at the root (`routes.go`, RFC 5785), but `extract_go_routes`
  assumes a single `/api/v1` prefix for everything in `routes.go`, so the
  script reports them prefixed. Allowlisted in the shape the script
  produces and the mismatch is recorded in the comment. Fixing the parser
  is a behaviour change to a shared gate and did not belong in this pass.
- **`scripts/check-env-vars.py` was touched, which is one file beyond the
  three the task named.** It was unavoidable: the six slot vars are read
  via a computed key (`getEnv(prefix+"_NAME", id)`), which `ENV_READ_RE`
  cannot see, so documenting them as table rows fails the gate's
  doc-to-code direction. Options were (a) allowlist, (b) prose-only
  documentation that the gate does not parse and
  `check-cloud-run-env-parity.py` cannot use, (c) change `config.go` to
  use literal keys, which is out of scope for DevOps. (a) is the honest
  one and it is the hole the comment above `ENV_READ_RE` already warns
  about.
- **`docs/operations/migrations.md` unchanged.** The branch's migration
  `20260912120437_assistant_oauth_durable_storage.sql` follows the
  timestamped convention and the gate passes, so there is nothing to
  document.
- **`handoff.md` is deliberately NOT committed.** Critic B6 flagged the
  previous one as committed working notes; commit `99e159b3` removed it.
  This file stays untracked.

## Evidence

```
$ python3 scripts/check-openapi-routes.py    # before
EXIT:1   (9 undocumented routes)
$ make check-api-spec                        # after
EXIT:0   OK: 88 Go routes / 83 OpenAPI paths in sync (allowlists honoured)

$ make check-env-vars                        # before
EXIT:2   ERROR: ASSISTANT_RESOURCE_URI read by config.go, not in the doc
$ make check-env-vars                        # after
EXIT:0   98 read / 108 documented / 28 secret rows, all accounted for

$ GITHUB_REPOSITORY=Arlencho/olympus-platform PR_NUMBER=2815 \
    make check-migration-filenames
MIGRATION_GATE_EXIT:0   PR #2815 adds ['20260912120437'], no collisions

$ git diff --stat origin/feat/ac-w1d-authserver..HEAD   (pre-push base bd20c07e)
 .env.example                    | 48 +
 docs/operations/env-vars-api.md | 23 +
 scripts/check-env-vars.py       | 26 +
 scripts/check-openapi-routes.py | 48 +
 4 files changed, 145 insertions(+)
```

Commits: `1965c32c` (route allowlist), `d6f1da43` (env docs). Pushed to
`feat/ac-w1d-authserver`; PR #2815 confirmed still `draft: true`.

Facts checked against source rather than the reviews, since both reviews
predate the last four commits on this branch: the disable condition and
its startup log line (`cmd/server/main.go`), `redirectAllowed`'s `==`
compare and `getEnvOriginList`'s split/trim (`config.go`),
`assistantMetadataOrigin`'s absolute-URL requirement, and the consent
template's actual copy ("Connect <name> to Olympus", not the "Allow ..."
phrasing I first wrote).

## Do not repeat

- Do not add these nine paths to `api.yaml` as a "cleaner" fix. Generated
  client methods for 302 legs and form-encoded token/revoke calls are
  worse than an allowlist entry, and `api.yaml` is not this agent's file.
- Do not delete the `ALLOWLIST_DOC_NOT_IN_CODE` entries without either
  making `config.go` read literal keys or teaching `ENV_READ_RE` to expand
  `assistantOAuthClientSlots`. Deleting alone turns the gate red.
- The repo is full of long dashes in older text; do not copy that style
  into new lines. Added lines were checked for U+2014, U+2013, U+2015 and
  the double-hyphen substitute: zero hits.

## Open questions

- `ASSISTANT_RESOURCE_URI` has no ratified production value. The doc gives
  the shape (absolute URL, `scheme://host` becomes the advertised
  authorization-server origin) and a prod-shaped example built from the
  real Cloud Run origin. The PRD does not name one, so nothing here
  invents a value beyond that example. Whoever runs the pilot sets it.
- Both `*_REDIRECT_URIS` slots are still unfilled by design: the PRD marks
  both pilot hosts "Unread". They are read from each host's own current
  documentation before the pilot, not guessed.

## Next hint

The gate half of the reviews is closed. What is still open on this branch
is behavioural and belongs to the producer, and both reviews were written
against `96c6ac37`: re-read them against current `HEAD` before acting,
because `1102f8b5`, `a2c2f2cc`, `8a8080a1`, `8f1e36aa` and `bd20c07e`
already claim to address B1, B3, B4, B5, H1 and H3. Verify those claims
by running the critic's attached tests rather than trusting the commit
subjects.
