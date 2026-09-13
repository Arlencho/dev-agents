# Handoff — REVISE round 2, Fleet Desk Wave 2 UI craft (PR #47, `feat/fleet-desk-ui`)

Seat: web-frontend (revise only). Answered frontend-critic batch 1 (`0e77687`).
No UI redesign, no contract change — `scripts/experience_data.py` untouched this round.

## Built

- **B1 (blocking)** — `scripts/experience_build.py`: role / skill / learning detail crumbs now
  point at the plural indexes: `../../roles/index.html`, `../../skills/index.html`,
  `../../learnings/index.html` (was `../index.html` → 404 on 12 of 54 real pages).
- **B1b (blocking)** — `tests/run-experience-tests.sh`: new `assert_links_resolve` helper crawls
  every relative `href=` in built HTML (skips `http`/`mailto:`/`#`, maps dirs to `index.html`)
  and fails unless `BROKEN: 0`. Wired into Part A (fixture) and Part B (real site).
- **N1** — dim scope chips no longer convey placeholder status by opacity alone: `page()` appends
  `<span class="chipmark">placeholder</span>` (the status as visible uppercase text) when
  `status != active`; `title=` tooltip kept. CSS: `.chip .chipmark` in `templates/experience/site.css`.
- **N2** — inline-style invariants tightened from `' style="'` to `'[[:space:]]style='`
  (catches single quotes / loose spacing; `rel="stylesheet"` does not match — checked).
- **N3** — `home()` split into `_home_stats` / `_home_companies_card` / `_home_watchlist` /
  `_home_roles_table` / `_home_skills_card_inner`; `home()` only assembles. Byte-identical
  output verified (diff vs pre-refactor build: only the chip marker + timestamps changed).
- **N4 (copy only)** — About page now states unlinked trails are join-boundary behavior
  (n=0 by design) and teaches `config/experience-joins.yaml` / `github_repo` + `make experience`.
  Join law itself untouched.
- New test assertion: fixture `ghostco` chip renders `chipmark">placeholder` (visible marker).

## Decisions (+why)

- Crawler lives in the shell suite as a python heredoc (critic's repro crawler, verbatim logic)
  rather than a new test file — keeps one suite, no new harness.
- Crawl applied to the real site too, not just the fixture: the critic measured the real 404s
  there, so the regression gate belongs there as well.
- N1 marker shows the actual status string (not a hardcoded "placeholder") so any future
  non-active status is labeled truthfully.

## Do not repeat

- Detail paths are singular (`role/<id>/`), indexes plural (`roles/`): any crumb of the form
  `../index.html` from a depth-2 detail page is a 404 unless the parent really is one level up
  (only `company/<id>/` → Home qualifies). Trust the crawler, not a `class="crumb"` grep.

## Evidence

```
$ make test
== 124 passed, 0 failed ==   (was 121; +3: chip marker, fixture crawl, site crawl)
  ok   fixture: every relative href resolves (BROKEN: 0)
  ok   site: every relative href resolves (BROKEN: 0)
  ok   dim chip marks placeholder status as visible text

# fixture crawl before fix (critic repro): BROKEN: 10 → after fix: BROKEN: 0
# real build crawl: 12 broken / 1104 links → BROKEN: 0
# fixture build diff vs pre-revise baseline: only crumbs, chipmark spans,
# about muted paragraph, site.css chipmark block, generated_at stamps
$ git diff main...HEAD --stat -- scripts/experience_data.py   # unchanged this round
```

## Open questions

- None blocking. Critic batch 2 of 2 may still land.

## Next hint

For the critic: re-run the repro crawler on fixture + real build (both now BROKEN: 0),
spot-check a `role/<id>/` crumb href, and confirm the chipmark renders on any page header
(fixture `ghostco`). The `home()` refactor is behavior-preserving by byte-diff.
