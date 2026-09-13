# Handoff: ci/2747-lint-no-network-dep (PR #2748)

## Built

One line of behavior in `.github/workflows/ci.yml`: `verify: false` on the
`golangci/golangci-lint-action@v9` step in `go-lint`, plus a block comment
recording why and what it costs. No other file changed.

## Decisions

- **`verify` is a real v9 input, confirmed before use, so the binary-install
  fallback was not needed.** `action.yml` on the `v9` tag
  (`db9de0fc1a667e1a49d2291a1a042dff081d78f6`) declares
  `verify: description: "If set to true, the action verifies the configuration
  file against the JSONSchema." default: 'true'`. The diff stayed at one file.
- **The schema is genuinely fetched, not embedded.** `strings` on the v2.11.4
  release binary shows only the URL template
  `https://golangci-lint.run/jsonschema/golangci.v%d.%d.jsonschema.json`. There
  is no offline path while `verify` is on.
- **The residual gap is measured and written down, not hand-waved.** Ran v2.11.4
  against a copy of our real config, one mutation at a time. `run` exits 3 on
  malformed YAML, unsupported `version:`, wrong value type, unknown linter name,
  and "no linters enabled". It does NOT reject an unrecognised KEY
  (`defaults:` for `default:`, stray top-level sections) - those load silently.
  `config verify` was not a superset either: it PASSES an unknown linter name
  that `run` rejects. Both directions are in the workflow comment so the next
  person does not have to rediscover them.
- **Did not vendor the schema.** v2.11.4 has a hidden `config verify --schema`
  flag that accepts a local path, so the unknown-key class could be closed
  offline by committing the schema. That means a large generated JSON file in
  the repo, coupled to the version pin, going stale on every bump. Named as a
  deliberate trade in the comment rather than done silently.

## Do not repeat

- Do not assume `golangci-lint run` rejects any bad config. It does not reject
  unknown keys. Measured, see the table in the PR body.
- Do not expect a plain `git push` of a throwaway branch to produce a CI run.
  `ci.yml` triggers on `pull_request` to main and `push` to main only, so each
  proof branch needed an actual (draft) PR.
- `gh pr close --delete-branch` failed here and deleted NEITHER the local nor
  the remote branch, because the local branch was checked out in a worktree.
  Remove the worktree first, then `git push origin --delete` explicitly, then
  verify with `git ls-remote`.
- `gh api .../logs` refuses to print without `--allow-escape-sequences`.

## Evidence

```
$ git ls-remote --heads origin 'refs/heads/throwaway/*'
count=0

$ make check-ci-wiring   # exit code captured directly, not after a pipe
CI job wiring OK - 25 job(s) wired into both `ci-passed` and `report-main-red`, 1 exempt
self-test passed - 15 cases
EXIT_CODE=0

go-lint in ci-passed needs:       True
go-lint in report-main-red needs: True
```

Invalid config still fails (exit 3, config never loaded):
https://github.com/Arlencho/olympus-platform/actions/runs/33317750395/job/99274208755

Real gocognit violation still fails:
https://github.com/Arlencho/olympus-platform/actions/runs/33317773092/job/99274270042

Valid config on this branch passes:
https://github.com/Arlencho/olympus-platform/actions/runs/33317745601/job/99274200004

Neither failing log contains a `config verify` step or a reference to the schema
host, which is the whole point of the change.

Branch head: `30a226e7`. PR #2748. Not merged.

## Open questions

- Worth a follow-up issue to vendor the schema and restore unknown-key checking
  offline via `config verify --schema`? Only if a typo'd key actually bites us.
  Today it is a documented, bounded gap.
