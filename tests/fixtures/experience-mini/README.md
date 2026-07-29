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
