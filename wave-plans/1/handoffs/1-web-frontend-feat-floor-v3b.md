# Handoff: Floor v3-B round 3 (R2-1, R2-2)

## Built

- `templates/experience/floor.js`: new `replayUnavailable(dispatchId)`: when a
  replay fetch answers not-ok or throws (file:// desk, static site, no /api),
  the page now paints a visible state instead of keeping the live snapshot:
  watermark "Replay of <id> is not available on this desk (it needs make
  desk-live serving the event stream)", LED `led off`, all six strip figures
  hidden, `elapsedLive = false`, and an `Exit to live Floor` link back to the
  plain page URL. Wired into both failure branches of `loadReplay`.
- `templates/experience/floor.js`: new `measureHeader()`: sets
  `--floor-header-h` on `<html>` from the measured `header.site` height (+8 px)
  on load and resize.
- `templates/experience/site.css`: the per-card `scroll-margin-top` constants
  (140/250 px) are replaced by one rule:
  `html { scroll-padding-top: var(--floor-header-h, 140px) }`. Covers every
  anchor target including queue rows. Also `a.btn-replay` styling for the exit
  link.
- `tests/floor-browser-probe.py` (new): headless-Chrome probe over the file://
  desk. Mode `anchors` clicks every visible `#floor-strip a.sfig` and
  `#floor-needs-list a.act[href^="#"]` and asserts target top >= header bottom.
  Mode `replay-unavailable` runs the critic's six-step repro. Exit 77 = no
  browser (suite skips with a pass note, like the optional gh path).
- `tests/run-experience-tests.sh`: the B3 magic-number grep replaced by R2-2
  greps (rule present, no scroll-margin remains, measureHeader wired) plus
  browser measurements at 400/768/1280; R2-1 grep pins the loadReplay failure
  branch, browser probe runs the repro.
- Branch rebased onto origin/main (v3-A squash 47767ce). Head: ae35e8f.
- PR 80 body gained a Round 3 heading with commands + exit codes; PR marked
  ready for review; issue 72 labelled status:in-review.

## Decisions (+why)

- Exit is a plain `<a href="pathname">`, not a JS state flip: on a static desk
  a reload without `?replay=1` re-renders the build snapshot, which is the
  honest live-floor state there; on a real desk it reboots live polling.
- Measured custom property over CSS breakpoints: the header wraps at several
  widths (237 px at 400, 164 at 700, 129 at 1280) and the critic's fix shape
  allowed either; measurement can never drift from the header again. JS runs
  on every desk (file:// included), so the 140 px fallback is pre-paint only.
- Rebase used `git rebase --onto origin/main b0af37a`: the two v3-A commits
  conflict with their own squash in main, and the three wave-plan commits are
  already upstream (patch-id match). One add/add conflict in
  `wave-plans/*20260913.plan` resolved with main's newer generated files.
- Probe kills Chrome after `</html>` arrives: headless Chrome on macOS writes
  the dump and then lingers (updater/crashpad), so `subprocess.run` with a
  timeout always lost 120 s per probe.

## Do not repeat

- `--virtual-time-budget` + `--dump-dom` alone hangs on macOS Chrome; stream
  stdout and kill after the closing tag (see `dump_dom` in the probe).
- Testing anchors against `tests/fixtures/live/wave.json` finds zero visible
  strip figures: that fixture has no v3 `summary`, so floor.js hides them.
  Use the suite's round-2 fixture state (the probes run where the B2 tests
  run, before the B6-empty rebuild overwrites live.json).
- Chrome headless enforces a minimum window width; the 400 px viewport is an
  exact-size iframe with `--allow-file-access-from-files`.

## Evidence

- `bash tests/run-experience-tests.sh` -> exit 0, 361 passed 0 failed
  (post-rebase, ae35e8f). Probe lines: at 400, `#floor-queue-row-1` top=245
  vs header bottom 237; at 768, needs/queue cards top=172 vs 164; at 1280,
  all targets top=137 vs 129. Replay repro: LED `led off`, watermark painted,
  six figures hidden, exit link present, elapsed frozen.
- `bash tests/run-desk-live-tests.sh` -> exit 0, 375 passed 0 failed.
- `make experience` -> exit 0. `node --check templates/experience/floor.js`
  -> exit 0.
- Push: `71dfc43...ae35e8f feat/floor-v3b (forced update)` (rebase).

## Open questions / next hint

- Round 2 closed with "the next revision goes to the CTO for a ship, redesign
  or kill decision rather than a third critic round": this push is that
  revision; routing is the orchestrator's call.
- A critic re-run should check: the `--floor-header-h` style attribute JS sets
  on `<html>` does not break the static-vs-painted mirror diff (it is outside
  every section), and the round-2 advisories still stand (note/row duplication
  when the needs list is empty, PR title + purpose back to back, aborted
  figure not red): left untouched as advised-not-blocking.
