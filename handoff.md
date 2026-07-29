# Handoff — Fleet Desk v2 Phase A, critic loop 1 revision (web-frontend)

Task: REVISE-only on PR #57 `feat/fleet-desk-v2-phase-a` — pin the three surviving mutations (M5/M7/M8) from the loop-1 verdict with tests. No production logic changed; critic found no functional bug.

## Built

- **`tests/run-experience-tests.sh` only** (one file touched). In the injected-contract mission block:
  - Fixture injection extended: unlinked trail `2-fixture-builder-gadget` now gets `issue_links: ["#77"]`, so the bare-ref-on-unlinked-join path (the path all 19 real trails take) is exercised.
  - +4 assertions: (C1a) missions index renders `unlinked / repo — / #77`; (C1b) no fixture company (`acme|ghostco`) appears in the `#77` path — pins `experience_build.py:178` against the `or companies[0]["id"]` mutation; (C2) `prefers-reduced-motion` present in built `assets/site.css`; (C3) no empty `<span class="st st-*"></span>` pill (text+color, WCAG 1.4.1).
- Suite count 261 → 265 passed, 0 failed.

## Decisions (+why)

- **C1b regex uses `acme|ghostco`, not the critic's `acme|aegis|olympus`.** Those are the real repo's companies; the injected site is built from `tests/fixtures/experience-mini`, whose only companies are acme and ghostco. Widened to the fixture's actual set so the pin holds regardless of `companies[0]` ordering.
- **`unlinked#N` missions kept** per critic verdict — `unlinked / repo — / #77` is the honest rendering; the assertions pin it, not suppress it.
- **No production change.** M5/M7/M8 were missing assertions, not defects; shipped behavior verified correct by the mutations themselves (each broke only its own new assertion).

## Do not repeat

- The critic's copy-paste snippets assume real-repo company names in the regex — check fixture data before reusing them verbatim.
- Mutations are reverted with `git checkout -- <file>` after each RED run; never commit the mutated production file (tree must show only `tests/run-experience-tests.sh` modified).

## Evidence

- Clean: `./tests/run-experience-tests.sh` → `== 265 passed, 0 failed ==`; `make test` → "All test suites passed."
- Mutation matrix (each mutation applied, suite run, then reverted):
  - M5 (`company_id … or companies[0]["id"]`): `263 passed, 2 failed` — FAIL = "unlinked mission keeps honest path", "no company invented for unlinked mission".
  - M7 (delete `prefers-reduced-motion` block): `264 passed, 1 failed` — FAIL = "stylesheet honors prefers-reduced-motion".
  - M8 (`<span class="st {cls}"></span>`): `264 passed, 1 failed` — FAIL = "state pill carries text, not color alone".
  - Post-revert `git status --porcelain` → only `tests/run-experience-tests.sh` modified.
- Each mutation fails **only** its own assertion(s) — no cross-talk, matching the critic's predicted matrix.

## Next hint (critic, loop 2)

Re-run the full 9-mutation matrix; M5/M7/M8 should now be RED, score 9/9. The four new pins live directly after the "mission title source is disclosed" check in the injected-contract block. Everything else in Phase A is unchanged since fca45f0.
