# Handoff: critic verdict vocabulary (feat/orchestrator-loop, wave 2)

## Built

- `tests/fixtures/critic-verdict-rule.md`: the one canonical rule block (BLOCK-FIX, BLOCK-ESCALATE with its five reasons, BLOCK-CLOSE, SAFE-TO-MERGE, "both kinds means BLOCK-ESCALATE").
- The block appended verbatim to `roles/backend-critic.md`, `frontend-critic.md`, `api-critic.md`, `database-critic.md`, `plan-critic.md`, `devops-critic.md`, `security-reviewer.md`; `providers/claude/agents/` copies re-synced (`scripts/sync-providers.sh --force`; the other two critics are not owned by that provider and have no copy there).
- New root `CLAUDE.md` (did not exist) with the same block; `docs/org-chart.md` § Verdict with the same block; README "One fix round" bullet points to it.
- `tests/run-critic-verdict-tests.sh` wired into `make test` (Makefile `test` target, last suite).

## Decisions

- One fixture file is the source; every copy is checked as an exact substring. Editing the block means editing the fixture, then re-copying; the test says so when it fails.
- `plan-critic` keeps `VERDICT: APPROVE | REVISE | REJECT` for the autoplan pass because `scripts/autoplan.sh:143` and `:195` parse only those and fail closed. The block governs its PR comments. Changing autoplan was out of scope.
- The block does not spell any vendor or model name, and the test's check for that derives the forbidden words from `providers/*/` and `model:` front matter so the test file itself spells none either.
- No shared critic skill exists under `skills/`, so nothing was added there.

## Do not repeat

- `make sync` without `--force` exits 1 on any drift, even when `roles/` is the intended source. Use `./scripts/sync-providers.sh --force` after editing a role.
- In zsh a heredoc whose body contains another heredoc terminated by the same word closes early. Use a unique outer terminator.
- `PIPESTATUS` is `pipestatus` in zsh; better, run the command without a pipe when the exit code matters.

## Evidence

- `./tests/run-critic-verdict-tests.sh`: 44 passed, 0 failed, exit 0.
- RED proof: one letter changed in `roles/api-critic.md` gives exit 1 (2 FAIL rows); a provider directory name appended to the fixture gives exit 1 (10 FAIL rows); both restored to exit 0.
- `./tests/run-roster-tests.sh`: 59 passed, 0 failed, exit 0. `make lint`: exit 0. `shellcheck -S warning tests/run-critic-verdict-tests.sh`: exit 0.
- Full `make test`: see the PR body for the final line and exit code.

## Open questions

- The verdict word for the CTO gate stays `APPROVE-MERGE` in README and org-chart; the runner accepts both it and `SAFE-TO-MERGE` for landing. Unifying the CTO's word was not asked.
