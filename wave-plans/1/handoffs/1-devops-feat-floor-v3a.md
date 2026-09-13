## Built

- `scripts/desk_live.py`: `VERDICT_TOKEN_RE`; `first_line_verdict` returns None when two different verdict words stand as tokens of their own where the verdict is read (after the first colon, else anywhere on a colon-less line). Finding 5 of the round 2 critic comment on PR 77.
- `tests/run-desk-live-tests.sh`: five `assert_fn` cases; Part K fixture stream `k-landed-two.jsonl`, fake gh PRs 301 to 303, two `assert_py` checks.
- `docs/experience-data.md`: the ambiguity rule in the first-line paragraph.
- PR 77 body: Round 3 section with exit codes.

## Decisions

- Scope is after the first colon, not the whole line: the round 2 case `CRITIC SAFE HARBOR ROUND 2: SAFE-TO-MERGE` would otherwise become ambiguous (SAFE plus SAFE-TO-MERGE).
- Distinct words, not a count: `BLOCK-FIX (round 1 BLOCK-FIX stands)` is one verdict.
- The three critic PRs enter Part K through a landed stream with a plan not on disk, so initiative wave counts are untouched.

## Do not repeat

- Counting whole verdict tokens over the entire first line: breaks the heading-word cases from round 2.
- Adding the three branches as queued plans: changes `waves.planned` and the queue assertions.

## Evidence

- `python3 -m py_compile scripts/desk_live.py` exit 0
- `./tests/run-desk-live-tests.sh` passed 375, failed 0, exit 0
- `bash tests/critic/phase-b-honesty-repro.sh` passed 6, failed 0, exit 0
- Replay on `/tmp/floor-v3a-r2` fixture: no item on PRs 301 to 303, `needs_you` 6, PR 204 still ready.
- Commit `778be6e44cbf1e57031e13841153485d4888be9b`, pushed to `origin/feat/floor-v3a`.
