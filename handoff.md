# Handoff — Fleet Desk Wave 2 UI craft (`feat/fleet-desk-ui`)

Seat: web-frontend (UI CRAFT only). Data contract, joins, and PMI logic untouched
(except one tiny cosmetic fix, below). Built on top of Wave 1 (`#46`).

## Built

- `templates/experience/site.css` (new) — the Wave 2 visual system: design tokens
  (paper/ink, one bronze accent), `prefers-color-scheme` dark palette, status pills
  (text AND color, never color alone), PMI band badges, wave section headers,
  segmented control, stat strip, breadcrumbs, meta grid, empty-state boxes,
  focus-visible rings, skip link, `prefers-reduced-motion`. Zero JavaScript.
- `scripts/experience_build.py` (rewritten renderer) — still reads **only**
  `site/experience/data/index.json`; CSS moved out of the Python string into the
  template and copied to `site/experience/assets/site.css` each build (pages link
  it via `<link rel="stylesheet">`; stale-HTML cleanup now also preserves `assets/`).
  - Work: **group-by-wave + flat toggle** as plain links (`work/index.html` ⇄
    `work/flat/index.html`, same pair per company). No JS.
  - Home: fleet stat strip (trails, done %·n, critic share, waves, companies,
    vendor mix), companies strip with `n=`, recent work, watchlist, roles+PMI,
    skills/learnings funnel.
  - Trail detail: breadcrumb (`← Work · scope · wave N`), meta grid
    (vendor·model, branch, base→head mono SHAs, exit, ts, join, links, source),
    all six handoff sections (open_questions/next_hint now shown too), raw
    redacted record in `<details>`.
  - Company: status pill, repo/GitHub link, joined trails, per-company learnings,
    "skills are fleet-global" note.
  - Roles/Skills/Learn: status pills, PMI badge + reason + cap + expandable raw
    inputs, specialized-pack "boost label, never a P2 shortcut" wording.
  - a11y: `aria-current` on nav / scope chips / segment; skip link; semantic h1→h2.
- `scripts/experience_data.py` (tiny fix) — `phase_note` no longer captures the
  `## Active phase` heading itself; heading lines are skipped so olympus now lands
  on the `| Wave plan in flight | …` row like safeplace. No join/PMI/PMI-gate changes.
- `tests/run-experience-tests.sh` — 24 new Wave 2 smoke checks (stylesheet exists
  + linked, `prefers-color-scheme`, no inline `<style>`/`style=` in HTML, segment
  toggle + flat pages, status pill text, skip link, aria-current, breadcrumb,
  base→head, raw-record disclosure, empty-state teaches, PMI badge). Added
  `assert_absent_html` helper that scans only `*.html` (data/index.json may
  legitimately contain `style="` inside handoff prose).
- `docs/experience.md` — operator walkthrough updated for the new UI (toggle,
  visual-system reading guide, stylesheet location).

## Decisions (+why)

- **External stylesheet over inline `<style>`** — the charter prefers
  `templates/experience/` CSS; one cached file, and "no inline styles" becomes a
  testable craft invariant.
- **Flat/wave toggle as two static pages, not JS** — SYNTHESIS §6 "static is a
  feature, minimal/no required JS"; links work over `file://` everywhere.
- **Did not add filters (role/status/wave dropdowns)** — §4.2 shows them, but
  Phase 0 law is scan-first static; wave sections + flat view cover the operator
  questions without JS. Flagged as a Phase 1 candidate.
- **Raw JSONL is not rendered** — the contract carries no raw JSONL text field;
  the audit disclosure shows the redacted handoff markdown instead. Contract unchanged.
- **phase_note kept as raw table row** (`| Wave plan … | …`) — matches safeplace's
  Wave 1 rendering; stripping pipes would be display sugar over the contract.

## Do not repeat

- Python <3.12 f-strings: `{" a=\"b\"" if x else ""}` inside an f-string
  expression is a SyntaxError — compute the attribute string outside the braces.
- `assert_absent` over the whole site dir will false-positive on
  `data/index.json` (handoff prose contains `style="`) — use `assert_absent_html`.
- Chrome headless `--force-prefers-color-scheme=light` does not work; to verify
  the light palette, strip the dark `@media` block from a copy of the CSS.

## Evidence

```
$ make test
… == 121 passed, 0 failed ==   (fleet desk experience; all other suites green too)
$ ls site/experience/assets site/experience/work
assets: site.css     work: flat/ index.html
$ grep -c 'style=' site/experience/index.html  → 0
```

Headless-Chrome screenshots checked visually (dark + stripped-light): home,
work (grouped), trail, role, company (empty state), conductor (empty state).

## Open questions / next hint (critic)

- Verify the toggle links from `company/<id>/work/flat/` resolve (depth-4 prefix).
- Confirm the phase_note heading-skip did not alter fixture expectations (it is
  untested there — worth one fixture assertion if you want it pinned).
- PMI P2 wording on roles index vs role detail: check "boost label" honesty reads
  right to an operator.
- PR: `gh pr create` on `feat/fleet-desk-ui` (see PR body for the checklist).
