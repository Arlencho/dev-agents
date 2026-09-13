# PRODUCER HANDOFF — PR #49 `feat/fleet-desk-phase1-ui`, loop 2 (REVISE fixes)

Critic verdict `edffe2e` (REVISE) had 2 blocking defects, both renderer-only.
Both fixed in `scripts/experience_build.py` plus assertions landed in
`tests/run-experience-tests.sh`. No `experience_data.py` change, no visual
redesign, no new CSS — scope held.

## Built

- **C1 — sub-P3 role no longer reads as P3-gate-satisfied**
  (`scripts/experience_build.py`, roles loop). The evidence branch now splits
  on `pmi["band"]`:
  - band P3 + evidence → unchanged positive framing `Proven loop evidence (P3 gate):` + list.
  - band ≠ P3 + evidence → keeps the literal `Proven loop evidence (P3 gate):`
    label but states `recorded, but the P3 gate is not met — the role is still
    short of the P2 outcome bar (band P1), so this evidence cannot promote it
    yet.` before listing the evidence.
  - no evidence → unchanged honest negative branch.
- **C2 — Links row unions resolved + unresolved refs** (trail_pages). Resolved
  gh entries render first (link + state + title), then every raw `issue_links`
  entry whose ref is not already covered by a resolved entry. `none parsed`
  only when both lists are empty. No ref is silently dropped on partial
  resolution anymore.
- **Tests**: critic's failing assertions landed verbatim in spirit —
  - C1: 3 greps on `$FIXOUT/role/fixture-runner/index.html` (P1 badge
    precondition, evidence-label precondition, "not met" honesty).
  - C2: the A2.3c injection now sets
    `issue_links = ["#12", "https://github.com/other/product/issues/9", "#77"]`
    with only `#12` in `issue_links_resolved`; 3 `grep -qF` assertions on the
    rendered trail page.

## Decisions (+why)

- Kept the literal string `Proven loop evidence (P3 gate)` in the sub-P3
  branch: the critic's precondition grep asserts that label stays present on
  the P1 page, and it is still the accurate section name — the dishonesty was
  the missing "gate not met", not the label.
- Non-P3 + evidence always means "short of the P2 outcome bar", never
  "evidence insufficient": `compute_pmi` (`experience_data.py:948-950`) makes
  p2_ok ∧ evidence ⇒ P3 unconditionally, so evidence on a sub-P3 role can only
  come from a failed P2 gate. The copy can state that safely.
- C2 dedupes on the raw ref string (`x["ref"]`), not on normalized URLs —
  matches how `apply_gh` records refs (verbatim from `issue_links`).
- Did NOT add a `resolved[:8]` truncation note: critic flagged it as an aside,
  the mandate was the union only. Left for a future pass if wanted.

## Do not repeat

- Don't "verify" new assertions by `git stash` — that reverts the tests too.
  Revert only `scripts/experience_build.py` (`git checkout -- <file>`) with the
  new tests in place; that reproduces the critic's exact 3 FAILs.
- The C1 precondition greps must stay green: any rewording of the P3 branch
  must keep both `Proven loop evidence (P3 gate)` and a `not met` phrase on
  sub-P3 pages.

## Evidence

- Non-vacuity (old renderer `fd3e78c` + new tests): `218 passed, 3 failed` —
  `FAIL P1 role with evidence states the P3 gate is still unmet`,
  `FAIL Links row still shows cited ref other/product/issues/9`,
  `FAIL Links row still shows cited ref #77`. Matches critic's observed RED.
- With fixes: `bash tests/run-experience-tests.sh` → `== 221 passed, 0 failed ==`.
- `make test` → `== 221 passed, 0 failed ==` / `All test suites passed.`
- Diff scope: `git status --short` → only `scripts/experience_build.py`,
  `tests/run-experience-tests.sh` (+ this handoff).

## Next hint (critic, loop 2)

Re-run C1 + C2 from the verdict, then the full suite. Check the C1 copy on the
P1 page reads as gate-unmet (not merely "not yet P3" hedging) and that the C2
union does not duplicate a ref when `resolved[:8]` coverage and raw refs
overlap. Everything else in the verdict was already PASS and untouched.
