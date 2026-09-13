# Handoff: #2751 vendored golangci-lint schema

Branch: `ci/2751-vendor-lint-schema` (commit `77699e10`)
PR: https://github.com/Arlencho/olympus-platform/pull/2756 (open, NOT merged)

## Built

- `.github/golangci/golangci.v2.11.jsonschema.json` (170K) - vendored config
  schema for golangci-lint v2.11.x.
- `.github/golangci/README.md` - provenance, sha256, refresh procedure.
- `.github/workflows/ci.yml`, job `go-lint`:
  - job-level `env.GOLANGCI_LINT_VERSION: v2.11.4` (single pin, read by both
    the action and the verify step)
  - new step `golangci-lint config verify (vendored schema, no network)` after
    the action, running `golangci-lint config verify --schema <vendored>`
  - `verify: false` kept on the action; comment rewritten to explain it must
    stay off because the action cannot be passed `--schema`

Nothing under `apps/` is touched by the PR. `make lint` deliberately unchanged.

## Decisions

- **The `--schema` flag DOES exist on v2.11.4** but is HIDDEN from `--help`.
  Registered in `pkg/commands/config.go`:
  `verifyFlagSet.StringVar(&c.verifyOpts.schemaURL, "schema", "", ...)` then
  `_ = verifyFlagSet.MarkHidden("schema")`. In `config_verify.go`,
  `createSchemaURL` returns the flag value immediately when set, so no URL is
  constructed and no HTTP client is used. The compiler is wired with a `file`
  loader, and the upstream in-source example is a relative local path.
  Marked "For debugging purpose only" upstream. Accepted because the failure
  mode is loud (`unknown flag: --schema`), not silent.
- **Schema lives in `.github/`, not next to `.golangci.yml`.** `apps/api/` is
  outside devops scope in `scripts/hooks/scope-check.sh`, and the schema is CI
  infrastructure. The verify step resolves it via `$GITHUB_WORKSPACE`.
- **Filename encodes major.minor**, derived from the pin at runtime. A version
  bump without a refreshed schema hard-fails the step instead of silently
  becoming a no-op. That was the deciding property.
- **Vendored from the immutable tag**, not from `main` and not from the
  website, then proven byte-identical to the website copy.
- **Verify runs AFTER the action** because the action is what installs the
  binary (`core.addPath` in `src/main.ts`). No coverage lost: lint failing
  already reds the job, and a green Go Lint always ran both steps.
- **`make lint` untouched**: `make tools` installs golangci-lint `@latest`, so
  local versions drift from the pin and a version-coupled schema would produce
  false local failures.

## Do not repeat

- Do not trust `golangci-lint config verify --help`: it does not list
  `--schema`. Probe the flag or read `pkg/commands/config.go` at the tag.
- Do not try to make `golangci/golangci-lint-action@v9` do the verification.
  `runVerify` in `src/run.ts` builds `<bin> config verify` plus an optional
  `--config` and nothing else. There is no input that reaches `--schema`.
- Do not put the schema under `apps/api/` from a devops session; the scope
  hook blocks it.
- `gh api .../logs` needs `--allow-escape-sequences` or it prints only a
  refusal line, and `gh run view --log` refuses while any job in the run is
  still in progress. Use the per-job logs endpoint.

## Evidence

```
$ /tmp/gcl2751/bin/golangci-lint version
golangci-lint has version 2.11.4 built with go1.26.1 from 8f3b0c7e on 2026-03-22T17:35:14Z

$ cd apps/api && golangci-lint config verify --schema <vendored>   # clean config
CLEAN EXIT=0

$ golangci-lint config verify --config typo.yml --schema <vendored>
jsonschema: "linters.settings.gocognit" does not validate ...: additional properties 'min_complexity' not allowed
TYPO EXIT=3

$ shasum -a 256 (tag copy) (website copy)
985af311f9448d5b0964c3eda502204326dcf35d8f757192684cddc9b6615676  both -> IDENTICAL

$ make check-ci-wiring > out 2>&1; echo "REAL_EXIT_CODE=$?"
REAL_EXIT_CODE=0     # 25 jobs wired into both lists, 1 exempt, self-test 15/15
```

CI runs:

- typo proof, Go Lint FAILED at the verify step while the lint step PASSED:
  https://github.com/Arlencho/olympus-platform/actions/runs/33336391534
- real lint violation, Go Lint FAILED at the lint step:
  https://github.com/Arlencho/olympus-platform/actions/runs/33336393175
- clean tree, full CI green incl. `CI passed`:
  https://github.com/Arlencho/olympus-platform/actions/runs/33336385917

Throwaway branches deleted:

```
$ git ls-remote --heads origin 'refs/heads/tmp/*'
(no output)
```

## Open questions

- Upstream calls `--schema` a debugging flag. Worth watching on the next
  golangci-lint bump; if it is ever removed the step fails loudly and the
  fallback is to re-open #2751 rather than to set `verify: true`.
