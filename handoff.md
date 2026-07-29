# Fleet Desk Phase 1 UI bind — `feat/fleet-desk-phase1-ui`

Thin-bound the schema v2 fields (PR #48) into the existing pages. Renderer-only:
`scripts/experience_build.py` still reads **only** `data/index.json`;
`experience_data.py` join/PMI logic untouched. No restyle — reused `.meta`,
`.tight`, `.muted`, `.pill`, `.card`; zero new CSS.

## Built

- **Trail detail** (`trail_pages`): `PR` row (link + state pill) only when
  `pr_url`; `Links` row upgrades to `issue_links_resolved` (ref link + state +
  title) when present, raw `issue_links` otherwise; `Reviewed by` / `Reviews`
  rows link to the paired trail page when non-empty.
- **Role detail** (`role_pages`): explicit "Proven loop evidence (P3 gate)"
  list under the cap line when `proven_loop_evidence` non-empty; honest
  "none recorded — the P3 gate is not met" line otherwise. Badge already
  rendered any band; `band-p3` CSS shipped with #48. No "capped at P2" copy
  existed in the renderer — the Phase-0-caption guard test still passes.
- **Skill pages** (`skill_pages`): index shows `· N rev` in the version cell
  when history is available; detail gets `Revisions` (+`(newest 20 shown)`
  when truncated), `First → last commit`, and a Git history card (sha · date ·
  subject, ≤ depth). `history_available: false` → "git history unavailable in
  this projection"; available-but-empty → "no commits recorded yet" (the two
  are never conflated, per the contract).
- **Home / About**: home stat strip gains `critic pairs`; About "This build"
  gains `gh enrichment: <status> — reason/counts` + skill-history availability,
  and a "Critic pairing" section with `critic_rate_method`, label and the raw
  `critic_rate_basis` counts.
- **Tests**: +27 assertions in `tests/run-experience-tests.sh` — fixture
  pairing links / P3 evidence / honest-empty negatives; A2.1 renders the no-git
  site (honest unavailable line, no invented history card); A2.2 renders the
  real-git site (real subject, revision count, truncation note); new A2.3c
  injects `pr_*`/`issue_links_resolved` into the fixture contract offline and
  checks PR row + resolved issue rendering; Part B real-site smokes.
- **Docs**: `docs/experience.md` Phase 1 section gains a short "where it lands
  on the pages" note.

## Decisions (+why)

- PR/issue fields render **only when present** (no empty rows): the contract
  guarantees the keys exist but empty means "enrichment didn't run or no
  match", and About already carries the global `gh_enrichment.status` — per-row
  emptiness would be noise, page-level status explains the silence.
- Pairing rows live in the trail meta grid, not a new card: one fact per row,
  matches existing grammar; links resolve checked by the existing
  `assert_links_resolve` crawl.
- `critic_pairs` went on Home, method/basis on About: Home is the scan surface
  (a count), About is the audit surface (formula + raw counts).

## Do not repeat

- Don't grep-test rendered HTML from the A2.1/A2.2 throwaway builds without
  adding the `experience_build.py` call first — those blocks built **data
  only** until this change; assertions against `$TMP/*-site/*.html` would have
  been vacuous.
- The fixture build inside this repo picks up **real** git history from the
  enclosing work tree, so fixture skill pages have `history_available: true` —
  don't assert "unavailable" against `$FIXOUT`; that's what the A2.1 no-git
  copy is for.

## Evidence

```
tests/run-experience-tests.sh   == 215 passed, 0 failed ==   (was 188)
make test                       All test suites passed.
grep '<dt>Reviewed by</dt>'  /tmp/fd/trail/1-fixture-builder-widget-x/index.html  → match
grep 'Proven loop evidence'  /tmp/fd/role/fixture-builder/index.html              → match
grep 'Revisions</dt><dd class="mono">1' /tmp/fd/skill/fixture-pack/index.html     → match
```

## Next hint

Critic: mutation-check the three honesty branches — (a) flip a trail's
`reviewed_by` to `[]` in A2.3c-style injection and confirm no pairing row,
(b) render the no-git site and confirm no `Git history` card, (c) confirm the
P2-never-claims-P3 copy on `role/fixture-veteran`. Also verify A2.3c's injected
JSON proves nothing about the real `gh` path (it's renderer-only by design).
