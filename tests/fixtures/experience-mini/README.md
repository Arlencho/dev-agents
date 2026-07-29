# experience-mini fixture

Deterministic mini-repo used by `tests/run-experience-tests.sh` to exercise the
Fleet Desk data contract (joins, wave sources, PMI bands, redaction).
Not a real project: every value here is synthetic.

Phase 1 shapes this fixture deliberately covers:

| Shape | Where |
| --- | --- |
| Producer ↔ critic pair on one branch | `6-fixture-critic-1` shares `feat/widget-x-alpha` with `1-fixture-builder-widget-x` |
| Critic with no producer (unpaired) | `6-fixture-critic-2` on `feat/critic-2` |
| PMI P3 via learning→skill promotion | `skills/fixture-pack/SKILL.md` cites `learnings/lesson-one.md`, role `fixture-builder` clears the P2 outcome bar |
| PMI P3 via version history | not here — the test builds a throwaway git repo so revision counts are real, never faked |

Each clause of the P3 gate has a fixture that would change band if the clause
were dropped, so the gate is pinned rather than merely described:

| P3 clause | Fixture that pins it | Must stay |
| --- | --- | --- |
| Shared default packs are excluded | `fixture-veteran` (5/5 done, defaults only) holds `evidence-first`, a **default** pack shaped to qualify twice over: `version: 2` **and** it cites `learnings/lesson-default.md` | P2 |
| P3 also requires the P2 outcome bar | `fixture-runner` holds the evidence-bearing `fixture-pack` but has `n_done=4` | P1 |
| Version path needs `revisions ≥ 2`, not just `version ≥ 2` | `fixture-solo` (5/5 done) holds `fixture-solo-pack`: born at v2, promotes nothing, never revised | P2 |

Load-bearing, so treat as frozen: **do not** edit `skills/fixture-solo-pack/SKILL.md`
(its revision count *is* the assertion), and **do not** remove the learning cite
or version bump from `skills/evidence-first/SKILL.md` (without them, a regression
that counted default packs as P3 evidence would pass every test).

The `git log` depth cap is proven in the throwaway git repo instead: a
`fixture-deep-pack` gets 23 real commits and the projection must publish exactly
`history_depth` (20) of them.
