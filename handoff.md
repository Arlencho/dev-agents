# Handoff — Fleet Desk polish (OPS)

Branch: `feat/fleet-desk-polish-ops`

## Built

- **Mute test ratecap notify** — `scripts/notify.sh` skips the macOS `osascript`
  toast (stays stdout/GitHub-only) when `FLEET_NOTIFY_SILENT=1` or
  `NOTIFY_SILENT=1`. `tests/run-failover-tests.sh` exports the silent switch
  around the ratecap notify path, asserts the stdout fallback line, and proves
  via an `osascript` shim that the binary is not invoked when silenced (and is
  invoked unsilenced on macOS). `make test` no longer pops "Provider
  Rate-Capped" toasts.
- **gh non-JSON honesty** — `scripts/experience_data.py` `gh_index()`: an
  exit-0 `gh repo view` whose payload is not an `owner/repo` slug, or an exit-0
  `gh pr list` / `gh issue list` that does not return a JSON array, now yields
  `status: bad_payload` with a clear `reason` (never `ok` with garbage).
  Never-fatal contract unchanged. New offline test A2.3d in
  `tests/run-experience-tests.sh` drives a fake `gh` on PATH that exits 0 and
  prints `not json` (plus non-array JSON and a happy-path case so the rig is
  not vacuous). `docs/experience-data.md` status list updated.
- **dev-agents registered as fleet product** — `companies/dev-agents.md`
  (`status: active`, `github_repo: Arlencho/dev-agents`, `repo: .`, short
  charter: multi-vendor fleet orchestration tooling). `load_learnings()` now
  skips the product-learnings scan when the company repo resolves to the
  projected repo itself, so `repo: .` does not duplicate this repo's learnings.

## Decisions

- New status value `bad_payload` (not folded into `error`) so a working-but-
  lying `gh` is distinguishable from a failing one; added to the Part B
  allowed-status assertion.
- Issue-list non-zero exit remains silently tolerated (pre-existing behavior,
  out of scope); only exit-0 garbage flips to `bad_payload`.
- No join-map entries added — the `dev-agents` company joins via the existing
  `github_repo`/`name_token` rules only. Verified against the real projection:
  no existing trail's join changed (all 19 `feat-ab` trails stay `unlinked`),
  and no company was invented.

## Do not repeat

- Don't "simplify" the notify test back to `>/dev/null 2>&1` — the stdout
  assertion and the osascript shim are the only proof the silent switch works.
- Don't put `repo: .` on a company without the self-repo learnings guard;
  without it every learning in this repo is duplicated as `<company>-<slug>`.

## Evidence

- `make test` → `== 222 passed, 0 failed ==` / `All test suites passed.`
- `./tests/run-failover-tests.sh` → `9 passed, 0 failed` incl.
  `silent: osascript not invoked (0)` and
  `unsilenced on macOS: osascript invoked (1)`.
- `./tests/run-experience-tests.sh` → includes
  `ok gh: exit-0 garbage is bad_payload, never ok (fake gh on PATH)`.
- Real projection: `dev-agents: active Arlencho/dev-agents trails: 0`,
  `learnings: 4 dupes: 0`, `gh: ok Arlencho/dev-agents`.
