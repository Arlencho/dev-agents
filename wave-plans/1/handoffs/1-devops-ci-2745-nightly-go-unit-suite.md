# Handoff: ci/2745-nightly-go-unit-suite (PR #2746)

## Built

One job, `go-unit-nightly`, in `.github/workflows/ci-deep.yml`: the full
`apps/api` unit suite, `go test -race -count=1 ./...`, unconditional, on the
existing 06:00 UTC nightly schedule. Added it to `open-failure-issue`'s
`needs` and gave the tracker body a triage step 7. Documented the placement
in `docs/operations/branch-protection.md` under a new "Jobs that are
deliberately outside the gate" section.

`ci.yml` is untouched. Two files in the diff, nothing else.

## Decisions

- **Service blocks copied byte-for-byte from `ci.yml`'s `go-test`, and the
  goose bring-up with them.** This is the part worth not re-litigating.
  DB-backed tests in this repo SKIP rather than fail when `DATABASE_URL`
  points at nothing, so a job with a drifted or missing postgres service
  would pass every night while running a fraction of the suite, and look
  like coverage. Asserted equality mechanically rather than by eye:
  `yaml.safe_load` both jobs, compare the `services` dicts and the test
  step's `env`. Both `True`.
- **No `EXEMPT` entry in `scripts/check-ci-job-wiring.py`, and none is
  wanted.** That script parses `ci.yml` only. `EXEMPT` exists for jobs
  DEFINED IN the gate's own workflow that must not gate (`labs-check`).
  Adding a `ci-deep.yml` job there would be wrong, and would also fire CW004
  (stale exemption naming a job that does not exist in `ci.yml`).
- **Dropped the `go mod verify` / `go mod tidy` diff step** that `ci.yml`'s
  `go-test` runs. It is dependency hygiene, not test breakage, and on an
  unconditional nightly it would file `ci:deep-failure` trackers for a
  different problem than the one this job is here to see.
- **`-count=1` is deliberate**: the failure class targeted (a test that turns
  red because the calendar moved, not because the code did) is precisely the
  one the Go test cache would hide on a re-run.
- **Reported the hermes / web exposure in the PR body, did not implement it.**
  `hermes-test` and `ts-test` are path-gated identically and have no
  unconditional nightly counterpart (`ci-deep.yml` covers hermes only via
  `go-vulncheck`, a scan, and `apps/web` only via `npm-audit-moderate`).
  Hermes is the higher-severity of the two.

## Do not repeat

- **`open-failure-issue` will NOT file an issue on a `workflow_dispatch` run.**
  It carries `if: failure() && github.event_name == 'schedule'` from #1047.
  #2745's acceptance line asks a manual run to "produce a filed tracker
  issue"; it cannot without changing that guard, and changing it would file
  junk. Do not go looking for a bug here. The proof run shows it `skipped`,
  which is correct. Called out explicitly in the PR body.
- Don't try to prove this by breaking a test on the task branch itself. The
  break must live on a throwaway branch, because `workflow_dispatch --ref`
  runs the workflow file AND the code from that ref.
- Local `go test` on the whole api module is slow. Scoping the pre-flight to
  `-run TestRecapGate ./internal/service/` confirmed the break in ~30s before
  spending a CI run on it.

## Evidence

```
$ make check-ci-wiring; WIRING_EXIT=$?; echo "REAL_EXIT_CODE=$WIRING_EXIT"
CI job wiring OK - 25 job(s) wired into both `ci-passed` and `report-main-red`, 1 exempt
self-test passed - 15 cases
REAL_EXIT_CODE=0
```

```
$ python3 ... compare ci.yml go-test vs ci-deep.yml go-unit-nightly
services identical: True
test-step env identical: True
```

Proof the job fails on a broken Go unit test. Throwaway worktree at
/tmp/oly-2745-proof, branch throwaway/2745-proof-do-not-merge, one-line break
reintroducing the #2744 class (`futureStayWindow` returning a window 30 days
in the past), dispatched via `gh workflow run ci-deep.yml --ref ...`:

  run: https://github.com/Arlencho/olympus-platform/actions/runs/33316447944
  job: https://github.com/Arlencho/olympus-platform/actions/runs/33316447944/job/99270674501

```
--- FAIL: TestRecapGate_ConfirmingUnlocksWhenTheRecapAlsoAsked (0.00s)
--- FAIL: TestRecapGate_AffirmativeSurvivesATypo (0.04s)
FAIL	github.com/Arlencho/olympus-platform/apps/api/internal/service	69.553s

failure   Go unit suite (apps/api, full, race)
success   Go vulnerability scan (apps/api)
success   Go vulnerability scan (services/hermes)
success   npm audit (moderate threshold)
success   Docker entrypoint rebuild (nightly safety net)
success   Postgres store integration tests (#2018)
skipped   Open tracking issue on failure
```

DB was live, not skipped: `goose: successfully migrated database to version:
38`, and 0 lines matching a DB-skip pattern in the job log.

Cleanup:
```
$ git push origin --delete throwaway/2745-proof-do-not-merge   ->  [deleted]
$ git worktree remove --force /tmp/oly-2745-proof
$ git branch -D throwaway/2745-proof-do-not-merge
$ git ls-remote --heads origin 'throwaway/*'                   ->  (empty)
$ git diff --name-only origin/main...HEAD -- apps/api | wc -l  ->  0
```

Commit: 7e8bb698. PR: https://github.com/Arlencho/olympus-platform/pull/2746
(open, not merged, per instruction).

## Next hint

If the hermes/web follow-up is wanted, it is a near-copy of this job twice
over: same placement in `ci-deep.yml`, same `open-failure-issue` wiring, same
"not in either `ci.yml` needs list" stance. Hermes first, it has the longer
blind window and terminates untrusted webhook traffic.
