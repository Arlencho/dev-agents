# Handoff: #2760 + #2761 CI hygiene

Branch: `ci/2760-2761-ci-hygiene` (commit `2d432c1f`)
PR: https://github.com/Arlencho/olympus-platform/pull/2764 (open, NOT merged)

## Built

- `.github/workflows/ci.yml`: `.github/golangci/**` added to the `go` path
  filter (#2760), plus a corrected `prd_docs` comment now that the PRD gate
  scans recursively.
- `scripts/check-prd-index.py`: F1 fenced code blocks stripped alongside HTML
  comments (`strip_html_comments` became `strip_non_reference_regions`), F2
  `glob` became `rglob`, F3 target split on `#` or `?`, F4 reference-style
  `[label]: ./x.md` definitions now count, F5 `README.md` and `_`-prefixed
  files under `pages/` are not page specs. Self-test 6 cases to 17.

## Decisions

- **F4 implemented rather than the comment narrowed.** Fail-closed was safe,
  but a reference-style row raised PI001 with a message naming the wrong
  problem, the same complaint F3 makes.
- **F5 as a naming rule, not `EXEMPT`.** `EXEMPT` is a claim that a real spec
  is deliberately undiscoverable; using it for a README would make the escape
  hatch look routine, which the script header explicitly discourages.
- **Unclosed fence runs to EOF.** Drops more links rather than fewer, so the
  failure direction stays closed. Pinned by a self-test case.
- **#2760 proven with an isolated probe.** A PR whose diff against `main`
  contains the schema cannot isolate the filter, because editing `ci.yml` in
  the same PR sets `ci_workflows` true and `Go Lint` runs either way. Solved
  with a throwaway base branch carrying the fix plus a temporarily widened
  `pull_request` trigger (`branches: [main, 'tmp/**']`), so the probe PR's
  diff against its base was the schema file and nothing else. That widening
  never touched the work branch.

## Do not repeat

- Do not try to prove the path filter with `workflow_dispatch`. paths-filter
  defaults its base to the default branch on that event, so the `ci.yml` fix
  itself shows up in the diff and `ci_workflows` masks the result.
- Do not read an exit code after a pipe. Every code below was captured
  directly from the command under test.

## Evidence

```
Go Lint on a schema-only commit (RUNS):
  https://github.com/Arlencho/olympus-platform/actions/runs/33367709779
  [modified] .github/golangci/golangci.v2.11.jsonschema.json
  ##[group]Filter go = true
  Changes output set to ["go"]        <- ci_workflows false, go alone triggered
Corrupted schema on the same branch (FAILS):
  https://github.com/Arlencho/olympus-platform/actions/runs/33368410563
  compile schema: ... unexpected EOF / exit code 3
Web-only negative control (SKIPS):
  https://github.com/Arlencho/olympus-platform/actions/runs/33367712673
  ##[group]Filter go = false ; Go Lint skipped, Go Test skipped

python3 scripts/check-prd-index.py --selftest    -> exit 0 (17 cases)
python3 scripts/check-prd-index.py (clean tree)  -> exit 0
make check-prd-index                             -> exit 0
make check-ci-wiring                             -> exit 0
F1 real row fenced:  old exit 0, new exit 1 (PI001 pages/atlas-chat.md)
F2 nested page:      old exit 0, new exit 1 (PI001 pages/atlas/99-nested.md)
F3 ?plain=1 suffix:  old exit 1 (false PI001), new exit 0
F4 ref-style row:    old exit 1 (false PI001), new exit 0
F5 pages/README.md:  old exit 1 (false PI001), new exit 0
drift 1 (orphan page):    exit 1, PI001
drift 2 (row, no file):   exit 1, PI002
PR CI run 33369072660 -> success
git ls-remote --heads origin 'refs/heads/tmp/*' -> empty (3 probe branches deleted)
```

## Open questions

- `Go Build` runs on `ts`, so a web-only change does not skip it. Pre-existing
  and documented at the job (it uploads the artifact `e2e-critical` needs), not
  a regression from this PR.
