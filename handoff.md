# Handoff — Fleet Desk polish N5 (chipmark a11y word boundary)

Branch `feat/fleet-desk-polish-n5` → PR #51 (draft). Task was a11y-only; no restyle.

## Built

- `scripts/experience_build.py:121` — dim-chip chipmark now renders
  `<span class="chipmark"> {status}</span>` (leading space inside the span).
  Before, `…{esc(id)}{mark}` produced `<a …>ghostco<span class="chipmark">placeholder</span></a>`,
  so the accessible name was the glued "ghostcoplaceholder"; now it is
  "ghostco placeholder" with a word boundary.
- `tests/run-experience-tests.sh` — dim-chip assertion now requires
  `chipmark"> placeholder` (with space), plus a new regression check
  "chipmark accessible name keeps a word boundary (no glued names)" that
  goes RED if `<span class="chipmark">placeholder` (glued form) returns.

## Decisions (+why)

- Whitespace went **inside the span text**, not between `</a>` text nodes and
  not via CSS. Text inside the element survives HTML whitespace collapsing and
  is picked up by accessible-name computation; a space between the id text and
  the span would also work, but keeping it inside the span makes the invariant
  greppable as one literal string (`chipmark"> placeholder`), which is what the
  test pins.
- Did not use `&nbsp;` — a regular space is what screen readers treat as a word
  break and it keeps the markup plain.
- Visuals untouched on purpose: `.chip .chipmark` already has
  `margin-left: 5px` (`templates/experience/site.css:110-113`), so the extra
  collapsible space adds no meaningful layout shift. No CSS changes, no redesign.

## Do not repeat

- Don't try to fix this with `title=` or `aria-label` on the chip — the visible
  text already carries the status (that was the earlier a11y fix); the only
  defect was the missing word boundary in the computed name.
- Don't assert on rendered `site/experience/` output in tests; the suite
  renders the fixture (`$FIXOUT`) fresh each run. Real-site output is a build
  artifact.

## Evidence

- `make test` → `== 222 passed, 0 failed ==` then "All test suites passed."
- New check runs and passes: `ok chipmark accessible name keeps a word boundary (no glued names)`
- Rendered fixture HTML contains `chipmark"> placeholder` (verified in
  `site/experience/index.html`, ×3, after the suite's `make experience` run).
- Commit `53ab84f` on `feat/fleet-desk-polish-n5`, pushed with upstream.

## Open questions

- None blocking. If a critic wants byte-identical pre-fix visuals, note the
  added space is collapsible and sits next to a 5px CSS margin — effectively
  invisible; deliberate trade for a greppable a11y invariant.

## Next hint (critic)

- Mutation-check the new test: revert the space in
  `scripts/experience_build.py` (`chipmark"> {status}` → `chipmark">{status}`)
  and confirm both dim-chip assertions go RED and nothing else does.
- Confirm no other renderer path emits `.chip` + `.chipmark` (only
  `experience_build.py` builds chips; grep `chipmark` returns the renderer,
  the test, and the CSS).
