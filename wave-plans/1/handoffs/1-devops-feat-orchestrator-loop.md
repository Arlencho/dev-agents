# Handoff: feat/orchestrator-loop, round 3 (PR 82)

## Built

- `scripts/queue_loop.py`: the settle decision in a fixed order (blocks from any critic; head green; every assigned seat SAFE by stem; CLEAN; a checkout on this machine; the head's own checks read once by GraphQL when the rollup names no commit; then ready and land). New: `head_checks_state`, `rollup_named`, `Gh.head_checks`, `escalation_reason` (five charter reasons), `seat_headings` / `heading_in_task` / `assign_threads`, `spent_plans` (runner marks), `stop_text` and `verdict_line` (stops file text law), guard keeps the last state on an unreadable or impossible reading.
- `scripts/desk_live.py`: `critic_stem` (shared heading parser), `latest_round` newest by time, round breaks ties.
- `scripts/land.sh`: refuses `LAND_REPO` without `LAND_ROOT`, and a `LAND_ROOT` without `.git`.
- `tests/run-queue-loop-tests.sh` section 7 (68 rows), fixtures under `tests/fixtures/loop/` (every CheckRun now names its commit; new pr-*, graphql-*, vm_stat-broken/garbage).
- Docs: README "The loop" bullets, `docs/experience-data.md` stops table, `docs/plan-file-format.md` FIX-ROUND row.

## Decisions

- Two-word verdict line ("BLOCK-FIX was SAFE-TO-MERGE") is silence and a stop (`unparsed`), per the fleet rule in CLAUDE.md. The critic's N1c rows expect a fix round instead; left failing on purpose, explained in the PR body.
- `checks_state` (per item) untouched; head binding and run conclusion live in `head_checks_state`. `ESCALATION_RE` untouched; reasons in `ESCALATION_REASON_RE`. The critic's script asserts the old values of both directly.
- Order: red checks are reported before a silent critic (CI gate before verdict gate). A block from any stem still acts; only the landing count is bound by stem.
- Production binding: `gh pr list --json statusCheckRollup` exposes no commit oid and no suite conclusion (probed on this repo), so the runner asks the head commit itself with `gh api graphql` before the first write.

## Do not repeat

- Do not make `first_line_verdict` read a verdict out of a two-word line to satisfy the N1c rows; it breaks the fleet rule and `tests/run-queue-loop-tests.sh` row 0.
- Do not add the reasons to `ESCALATION_RE` or the cancelled-run logic to `checks_state`: two passing critic rows pin their current behavior.
- Do not run the landing tests without `FLEET_HOME/<repo>/.git`: a landing now needs a checkout.

## Evidence

- `bash /tmp/critic-orch-loop-r2-9b8f173/run.sh <repo>`: 33 failing before, 2 after (both N1c). Logs: /tmp/r3-critic-before.log, /tmp/r3-critic-after.log.
- `./tests/run-queue-loop-tests.sh`: 126/0 before, 194/0 after, exit 0.
- desk-live 309/0, experience 314/0, detached dispatch 79/0, critic verdict 44/0, `make lint` OK, shellcheck -S warning clean on land.sh and the suite.

## Open questions

- Whether the critic accepts the N1c reasoning or the fleet rule text should say explicitly what the runner does with a two-word line (it says "a stop for a person" already).
