# Handoff: feat/ac-w1b-scope env-var documentation (PR 2804)

## Built

- `docs/operations/env-vars-api.md`
  - Secrets table row for `ASSISTANT_SERVICE_TOKEN`, source token
    `olympus-assistant-service-token`, stating that an operator creates the
    Secret Manager entry and that the value is deliberately distinct from
    `HERMES_SERVICE_TOKEN` because a leaked service token equals user
    impersonation across every identity bound to that channel.
  - Plain env var row for `CORS_ALLOWED_ORIGINS`: comma-separated list,
    default is the two localhost origins and is unchanged, setting it
    replaces the list wholesale, a wildcard is refused at load.
- `.env.example`: matching stanzas for both vars.
- `scripts/check-env-vars.py`: `getEnvOriginList` added to `ENV_READ_RE`
  plus a keep-in-sync comment.

Commit `ca08ae84`, pushed to `feat/ac-w1b-scope`. No new PR, no merge.
Nothing under `apps/api/internal` touched (`git diff --name-only -- apps/api/internal`
returns 0 lines).

## Decisions

The task asked for exactly two files. It is three, deliberately.

Only `ASSISTANT_SERVICE_TOKEN` was actually red. `CORS_ALLOWED_ORIGINS` is read
through `getEnvOriginList`, a helper this branch introduces, and the gate's
reader-helper regex did not list it. The var therefore never entered the code
set, so its missing doc row passed silently, and adding the doc row produced a
different failure ("declared in the doc but not read by config.go"). Reproduced
before editing the script, see Evidence.

`ALLOWLIST_DOC_NOT_IN_CODE` was the two-file option and was rejected: the var IS
read in code, so the allowlist entry would have been a false statement that also
leaves the gate blind to every future var using that helper.

## Do not repeat

- Do not allowlist `CORS_ALLOWED_ORIGINS` in `ALLOWLIST_DOC_NOT_IN_CODE`.
- Do not document a var read through a helper that `ENV_READ_RE` does not list;
  the doc row alone turns the job red in the other direction.
- Do not put `CORS_ALLOWED_ORIGINS` in the Secrets section. It is not a secret,
  and `envdoc.parse_secret_rows` would then demand a source token.

## Evidence

```
$ python3 scripts/check-env-vars.py   # before any edit
   ASSISTANT_SERVICE_TOKEN
EXIT=1

$ python3 scripts/check-env-vars.py   # doc rows added, script untouched
   CORS_ALLOWED_ORIGINS
EXIT=1

$ python3 scripts/check-env-vars.py > /tmp/envcheck.txt 2>&1; echo "REAL_EXIT=$?"
REAL_EXIT=0
OK: all 97 env vars read by config.go are documented.
OK: all 101 documented env vars are accounted for.
OK: all 28 secret rows declare a source.

$ make check-env-vars > /dev/null 2>&1; echo "MAKE_EXIT=$?"
MAKE_EXIT=0

$ git diff --stat   # pre-commit
 .env.example                    | 24 ++++++++++++++++++++++++
 docs/operations/env-vars-api.md |  2 ++
 scripts/check-env-vars.py       | 12 ++++++++++--
```

Secrets rows went 27 to 28, so the `MIN_SECRET_ROWS = 27` floor needed no change.

## Open questions

The `olympus-assistant-service-token` Secret Manager entry does not exist yet.
The doc says so and the empty value is the safe state (no route reads it in this
wave), but someone owns creating it before the assistant connect / redeem /
confirm endpoints land.
