# Handoff: worktree teardown hooks (dev-agents)

Branch `feat/worktree-sweep-hooks`, PR https://github.com/Arlencho/dev-agents/pull/65 (open, not merged).

## Built
- `scripts/land.sh`: new `sweep_worktrees()` called after the PR loop, `main_green` and `verify_prod`. Runs `make worktree-sweep-apply` in `$ROOT`, prints summary and `DIRTY` lines, warns on non-zero, always returns 0.
- `docs/worktree-sweep-launchd.plist`: label `com.arlen.worktree-sweep`, StartInterval 86400, RunAtLoad false, logs to `~/Library/Logs/worktree-sweep.log`, checkout from `OLYMPUS_ROOT` defaulting to `/Users/arlenrios/Desktop/dev-projects/AI-Orchestration/olympus-platform`.
- `scripts/worktree-sweep-install.sh`, `scripts/worktree-sweep-uninstall.sh`: sentinel scripts with names swapped.
- `Makefile`: `worktree-sweep-install`, `worktree-sweep-uninstall` with help text.
- `docs/local-pr-sentinel.md`: ten-line section covering both hooks and the manual command.

## Decisions
- `scripts/land.sh` was untracked on disk (`git log --all -- scripts/land.sh` empty, not gitignored). Committed verbatim plus the hook so the hook is reviewable. Flagged in the PR body.
- Three pre-existing long dashes in the land.sh header rewritten for house style. No logic touched.
- `RunAtLoad false` (sentinel uses true): installing a teardown backstop should not delete branches at install time. Also keeps install/uninstall verification non-destructive.
- XML declaration placed before the comment block; the sentinel plist has the comment first, which plutil tolerates but is not valid XML.
- Sweep output filtered to `^(worktrees:|branches :|DIRTY )` rather than dumped whole; on a machine with 70+ worktrees the full log would bury the landing output.

## Do not repeat
- `grep` for em dash characters in this shell returns nothing even when they are present. Use python to scan.
- Do not run `make worktree-sweep-apply` to test: it really deletes merged branches. Use `make worktree-sweep` (dry run) and a harness with a bogus ROOT for the failure path.
- There are two olympus-platform checkouts (`~/dev/olympus-platform` on a feature branch, `~/Desktop/dev-projects/AI-Orchestration/olympus-platform` on main). land.sh `$ROOT` points at the Desktop one.

## Evidence
- bash -n on all three scripts: exit 0. shellcheck on both new scripts: exit 0.
- `plutil -lint docs/worktree-sweep-launchd.plist`: OK, exit 0.
- `make help | grep worktree-sweep`: exit 0, both targets listed.
- install -> `launchctl list | grep com.arlen.worktree-sweep` -> `-  0  com.arlen.worktree-sweep` (exit 0) -> uninstall -> grep exit 1, plist removed. INSTALL_EXIT=0, UNINSTALL_EXIT=0. Left uninstalled.
- Failure path harness (function body verbatim, ROOT without a Makefile): `sweep exited 2` warning, FUNC_RETURN=0, HARNESS_EXIT=0.
- Summary filter tested against real `make worktree-sweep` output in olympus-platform.
- Commit e0daf30.

## Open questions
- Should the tracked `scripts/land.sh` become the canonical copy, or does the human keep editing the untracked Desktop copy? If the latter, the hook will drift out of the copy that actually runs.
