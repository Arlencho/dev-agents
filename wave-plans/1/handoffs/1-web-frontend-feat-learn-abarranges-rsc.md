# Handoff — ABarranges class: learning stub + RSC whitespace regression

## Revise loop 1 (PR #2059, commit `7f4b976d`, pushed)

Addressed the critic's three findings:

1. **MED — positive-control fixtures.** `jsx-whitespace.test.ts` now splits
   the detector into `findViolationsInSource(source, rel)` (in-memory) and a
   thin file-reading wrapper, plus a `describe("detector fixtures")` block:
   RED tag→text, RED text→tag, GREEN `{" "}`. The live-tree empty-violations
   test is unchanged.
2. **MED — learning doc status.** `docs/qa/learning-rsc-jsx-whitespace.md`
   status corrected to "Mitigated — multi-line hazard guarded" (legal fix
   2026-07-23, guard 2026-07-29 `e6817060`). Added an "Out of scope" section:
   same-line glue not detected (deferred), intentional PRD block-`em`
   headings on explore/stays/stories/homepage heroes (don't re-flow those),
   and the block-comment false-positive caveat.
3. **LOW — stale comment.** `atlas-home-page.test.tsx` hero comment now
   acknowledges the explicit `{" "}` in source (previously claimed "no inline
   whitespace" without mentioning the guard).

## Built (original)

Branch `feat/learn-abarranges-rsc`, commit `e6817060` (pushed to origin).

- `apps/web/app/legal/jsx-whitespace.test.ts` — cheap regression: a vitest
  source scan over all 248 `.tsx` files under `apps/web/app` and
  `apps/web/components`. Fails with file:line when a `<strong>`/`<b>`/`<em>`
  tag is separated from prose by a bare newline (both directions:
  `</strong>` at end-of-line before text, and prose at end-of-line before
  `<strong>`). Runs in the normal `npm test` suite; no new tooling.
- `docs/qa/learning-rsc-jsx-whitespace.md` — learning stub: root cause
  (JSX strips newlines adjacent to tags), the `{" "}` rule, pointer to the
  guard.
- Fixed 3 remaining instances of the same class the earlier fix wave
  (30f4e875 / a9eb5ecf, legal pages) missed — the new scan caught them:
  - `apps/web/app/atlas-home-page.tsx:470` — hero rendered
    "Tell me aboutthe trip you'd love."
  - `apps/web/app/atlas-home-page.tsx:549` — hero rendered
    "Where are weheading next, {firstName}?"
  - `apps/web/app/dev/atlas-v04-foundation/page.tsx:29` — "fonts.Verbatim"
  All fixed with explicit `{" "}`. No legal copy touched (task constraint).

## Decisions (+why)

- **Source scan, not render assertions.** Rendering every page to check for
  glued text is slow and brittle; the hazard is a purely syntactic pattern
  (inline tag vs prose across a bare newline), so a line-based scan is cheap
  (~35 ms), deterministic, and gives an actionable file:line + remedy.
- **Scan scope = `app/` + `components/`, inline tags = strong/b/em.** That
  is where copy lives and the tags the original bug used. `<a>`/`<span>`
  were left out to avoid false positives on non-prose markup.
- **Fixed the 3 non-legal instances myself** rather than scoping the test
  to `app/legal` only: a repo-wide guard that fails on main is useless, and
  the task only forbade rewriting *legal* copy. These were real user-visible
  glues in the landing hero.
- No issue number was given in the task, so no `gh issue` label transitions
  were done.

## Open questions

- Whether the landing-hero glues ("Tell me aboutthe trip") were already
  known/QA'd — they were live in production rendering until this branch.

## Do not repeat

- Don't try to fix this bug class by re-flowing copy onto one line —
  Prettier wraps it back and reintroduces the glue. `{" "}` is the only
  durable fix.
- Don't rely on `grep '</strong>$'` alone to find instances: it misses the
  reverse direction (prose line followed by `<strong>` on the next line),
  which is exactly what the 3 remaining instances were.
- `npx vitest` before `npm ci` silently pulls an npx-cache vitest and fails
  with MODULE_NOT_FOUND — run `npm ci` at repo root first (no node_modules
  existed on this machine).

## Evidence (loop 1)

```
$ cd apps/web && npx vitest run app/legal/jsx-whitespace.test.ts app/atlas-home-page.test.tsx
 ✓ app/legal/jsx-whitespace.test.ts (5 tests)
 ✓ app/atlas-home-page.test.tsx (26 tests)
 Test Files  2 passed (2)   Tests  31 passed (31)

$ git push
 e6817060..7f4b976d  feat/learn-abarranges-rsc -> feat/learn-abarranges-rsc
```

## Evidence (original)

```
$ npx vitest run app/legal app/atlas-home-page.test.tsx
 Test Files  3 passed (3)   Tests  34 passed (34)

$ npm run lint        # eslint . --ext .ts,.tsx --max-warnings 0 → clean
$ npx tsc --noEmit    # TSC_OK
$ npm run build       # next build → compiled, all routes listed

$ git push -u origin feat/learn-abarranges-rsc
 * [new branch]  feat/learn-abarranges-rsc -> feat/learn-abarranges-rsc
```

PR creation: `gh` is unauthenticated on this machine (HTTP 401).
Create the draft PR manually:
https://github.com/Arlencho/olympus-platform/pull/new/feat/learn-abarranges-rsc
Suggested title: `test(web): guard against RSC whitespace loss next to inline tags`

## Next hint

For the critic: verify the scan patterns in
`apps/web/app/legal/jsx-whitespace.test.ts` actually catch both hazard
directions (try reverting one `{" "}` fix and watch it fail), and confirm
no false positives fire on the current tree. Also sanity-check that the
three hero fixes render with a real space in a browser.
