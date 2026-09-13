# Handoff — PR #48 revision after critic REVISE (B1–B4)

Branch `feat/fleet-desk-phase1-data` @ `abd6736`. Scope: **fixtures and
assertions only**. `scripts/experience_data.py` is byte-identical to the
reviewed commit — the critic found no production defect and mutation confirmed
none, so none was invented.

## Built

All four blocking items were the same defect in the *tests*: every existing P3
assertion was satisfied by a role that passed or failed the gate for some
**other** reason, so no single clause of the gate was load-bearing. The fix is
one fixture per clause, each shaped to clear the P2 outcome bar independently,
so only the clause under test holds its band.

| Item | Fixture added | Pins |
| --- | --- | --- |
| **B1** | `skills/evidence-first/SKILL.md` → `version: 2` + cites new `learnings/lesson-default.md`. It is a **shared default** pack held by `fixture-veteran` (5/5 done). | Default packs are excluded from P3 evidence. The pack qualifies on **both** proofs, so `specialized` → `packs` cannot survive. |
| **B2** | `fixture-runner` now holds the evidence-bearing `fixture-pack` (config only; it already had `n_done=4`, `success=0.8`). | P3 requires the P2 **outcome** bar, not just evidence. Only `n_done` keeps this role down. |
| **B3** | New pack `skills/fixture-solo-pack/SKILL.md` (v2, promotes nothing, never revised) + new role `fixture-solo` with 5 done trails (`wave-plans/8/`). | `revisions ≥ 2`, i.e. "actually revised, not merely born at v2". |
| **B4** | Throwaway git repo grows `fixture-deep-pack` with **23 real commits**; the shell asserts from `git log` that >20 exist, then the projection must publish exactly `history_depth`. | The `-n{depth}` cap is *enforced*, not merely declared. |

Also: `assert_json` gained `S` (skills by id) and `L` (learnings by slug)
bindings; trail-count assertions 27 → 32; two doc rows for `handoff_truncated`
and `role_stats.role` (the critic's non-blocking nit — both verified against
real output before documenting).

## Evidence

Baseline green, then each of the critic's four mutations applied to a clean copy
of the **committed** tree (`cp -R`, `sed`, verified non-no-op by `diff`):

```
=== BASELINE (committed, unmutated) ===   == 188 passed, 0 failed ==

=== B1  evidence = proven_loop_evidence(packs, skill_index) ===
  FAIL PMI: shared default pack never grants P3
  FAIL PMI: no role cites a default pack as evidence
  FAIL no git: default pack promotion still grants no P3
  FAIL git: over-qualified default pack still grants no P3
  (+5 more)                               == 179 passed, 9 failed ==

=== B2  `if p2_ok and evidence:` -> `if evidence:` ===
  FAIL PMI: evidence without the P2 outcome bar stays below P3
  FAIL PMI: P3 needs the P2 outcome bar too      <- was vacuous, now bites
  (+2 more)                               == 184 passed, 4 failed ==

=== B3  drop `and s["revisions"] >= p3_min_pack_revisions` ===
  FAIL PMI: pack born at v2 but never revised is not a proven loop
  FAIL git: v2 pack with exactly 1 commit is not a proven loop
                                          == 186 passed, 2 failed ==

=== B4  remove `f"-n{int(depth)}"` from git_file_history ===
  FAIL git: history is truncated AT the published depth
                                          == 187 passed, 1 failed ==
```

`make test` → `188 passed, 0 failed` / `All test suites passed.` (was 178; +11
assertions, −1 superseded). `git diff 7cb1bd6..HEAD -- scripts/` is empty.

## Decisions

- **Each clause is pinned in more than one environment.** B1 is asserted in the
  fixture build (promotion + version), in the **no-git** projection (promotion
  only, since it reads files not git), and in the throwaway git repo (default
  pack at v2 with 2 real commits). A single mutant therefore cannot slip through
  one weak environment.
- **B3 is asserted twice on purpose.** The fixture build's revision count comes
  from *this* repo's real history, so it is asserted as `revisions < 2` (a
  precondition that fails loudly if the fixture rots). The throwaway git repo
  pins the exact deterministic case, `revisions == 1`.
- **B4 asserts the cap from both sides**: `len(git_history) == history_depth ==
  20` with `history_truncated: true` for the deep pack, and
  `history_truncated: false` for a shallow pack, so the flag cannot be hardcoded.
  The ">20 commits actually exist" precondition is read from `git log` itself,
  not assumed.
- **Deleted** the old `git: a single-commit pack is not a proven loop`
  assertion. It keyed on `evidence-first`, which is now excluded as a *default*
  pack for a different reason, making it doubly vacuous; the new
  `v2 pack with exactly 1 commit` assertion is the honest version of it.
- Did not touch production logic, the renderer, CSS, or any UI.

## Do not repeat

- Don't "simplify" the fixtures by removing the version bump or the
  `[ev: learnings/lesson-default.md]` cite from `skills/evidence-first/SKILL.md`.
  A default pack that does **not** qualify as evidence makes B1 vacuous again —
  that is exactly the hole that shipped.
- Don't edit `skills/fixture-solo-pack/SKILL.md`. A second commit touching it
  makes it a genuine proven loop and `fixture-solo` legitimately goes P3. Both
  the file header and the fixture README say so.
- Don't attach the never-revised pack to `fixture-builder` (already P3) or the
  qualifying default pack to a sub-P2 role — either makes the mutant invisible
  again. The fixture must clear P2 for *other* reasons.
- Don't assert `skill_history.depth == 20` alone; it echoes a constant. That
  assertion is kept, but only alongside the measured length.

## Open questions

- The `make experience-snapshot` output path still isn't gitignored (critic's
  nit, deliberate per SYNTHESIS §10). Left as an owner call, untouched.
- `gh` missing/erroring paths and `role_name_fallback` remain unexercised by the
  suite (verified by hand in review). Out of scope for B1–B4; would be a cheap
  follow-up with a `PATH=/usr/bin:/bin` build.
