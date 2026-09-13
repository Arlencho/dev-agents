# Handoff: #2755 PRD index gate

Branch: `ci/2755-prd-index-gate` (commit `f9a820c7`)
PR: https://github.com/Arlencho/olympus-platform/pull/2759 (open, NOT merged)

## Built

- `docs/prd/00-INDEX.md`: `pages/atlas-chat.md` added as the **first row of the
  "Atlas v0.4 surfaces" table**. That section's heading claimed "(specs pending
  placeholders only)", already false for `booked-v2.md` (Locked) and the two
  PROPOSED modal specs, so the heading + intro were corrected to say the Status
  column decides. Row names § 6.0 (Conductor readiness) and § 10 (in-chat
  confirm modal / Duffel Balance settlement) since those are what other docs
  cite.
- `scripts/check-prd-index.py` (new, 338 lines, stdlib only): bidirectional gate
  in the shape of `check-openapi-routes.py`. PI001 page on disk not linked from
  the index; PI002 index link under `docs/prd/` that does not resolve; PI003
  stale/unreferenced `EXEMPT` entry; PI004 refuses to pass on an empty scan.
  `--selftest` pins all four.
- `Makefile`: `check-prd-index` target (check + selftest), added to `.PHONY` and
  to the `lint` target.
- `.github/workflows/ci.yml`: new `prd-index` job, `changes` filter output
  `prd_docs` (`docs/prd/**`, `scripts/check-prd-index.py`), listed in **both**
  `ci-passed` and `report-main-red` needs.

## Decisions

- **CI job, not lint-only.** `grep -rn "make lint" .github/workflows/*.yml`
  returns nothing: no workflow runs `make lint`, so lint-only would leave the
  gate unrun on the exact PR that adds a page spec. Every consistency gate CI
  actually enforces has its own job. Path-gated so a non-PRD PR pays nothing.
- **Links inside HTML comments do not count as references.** A commented-out
  row (as `18-hotels.md` is in the index today) is invisible to a reader, so it
  must fail rather than pass. Covered by a selftest case.
- **Direction 1 scoped to `pages/` only.** `docs/prd/03-voice-and-tone.md`
  exists on disk, is referenced by the PR template, and is linked from NOWHERE
  in the index. Requiring foundation docs to be indexed would have forced that
  content decision through a lint gate. Direction 2 does cover them (a link
  that does not resolve needs no judgement). Noted in the PR body, not fixed.
- Placement in the v0.4 table rather than the Public pages table: `atlas-chat.md`
  is a sub-surface of `/r/{session-id}`, and `travelers-step.md` already uses
  that route form in that table. It goes first because the other rows extend it.
- `docs/qa/prd-6.0-audit.md:231` (scattered copy strings) left alone, per issue.

## Do not repeat

- **Do not use `git checkout -- <file>` to undo a proof edit on an
  UNCOMMITTED file.** It reverted the part-one index edit along with the
  temporary ghost row and cost a redo. Use `cp` to a backup outside the tree,
  or commit first. The final proof run used `/tmp/00-INDEX.bak`.
- `Path.relative_to` fails on macOS temp dirs unless the base is `.resolve()`d
  too (`/var` vs `/private/var`). Hit in the selftest; fixed with `prd_root`.

## Evidence

Exit codes captured with `EXIT=$?` straight off the interpreter, never after a
pipe.

```
1. clean tree                       -> EXIT 0   "OK: all 31 page spec(s) ... resolve"
2. temp page file, not indexed      -> EXIT 1   PI001 pages/99-proof-not-indexed.md
3. temp index row, no such file     -> EXIT 1   PI002 pages/98-proof-ghost.md
4. tree restored                    -> EXIT 0   (git status --short docs/prd empty)
SUMMARY: clean=0  page-not-indexed=1  ghost-index-row=1  restored=0
```

Gate reproduces the reported bug against the pre-fix index:
`PI001 pages/atlas-chat.md exists on disk but no link in 00-INDEX.md points at it`, EXIT 1.

```
make check-ci-wiring     -> EXIT 0  (26 jobs in both lists, 1 exempt; 15 selftest cases)
actionlint ci.yml        -> EXIT 0
make check-prd-index     -> EXIT 0  (check + 7 selftest cases)
make -n lint             -> new step present, last in the chain
```

CI on the PR, job `PRD Index Completeness`: **success** (run 33337290156, job
99326387528; both steps, check and self-test, green).

## Open questions

- `03-voice-and-tone.md` is unlinked from the index. Foundation doc or orphan?
  Needs a PRD owner, not a gate.
- The PR is open and unmerged, as instructed.
