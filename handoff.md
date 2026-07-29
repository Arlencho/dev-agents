# Handoff — CRITIC batch 2 of 2 (verify only), Fleet Desk Wave 2 UI craft (PR #47, `feat/fleet-desk-ui`)

Seat: frontend-critic (Opus). Verifying producer REVISE `53ccdc6` against critic batch 1 (`0e77687`).
Verify only — no redesign, no re-implementation, no production code written.

## VERDICT: APPROVE

Both blocking items are resolved **and the guard that protects them is load-bearing** (proven by
mutation, not by reading the diff). One new non-blocking a11y nit (N5) is filed below; it must
**not** trigger a third round — fold it into any later commit or ship as-is.

| Item | Status | Proof |
|------|--------|-------|
| B1 crumb 404s | **RESOLVED** | crumbs resolve on real site + fixture |
| B1b link-integrity gate | **RESOLVED, load-bearing** | mutation → exit 1, 7 broken links named |
| N1 chip status not opacity-only | **RESOLVED** (see N5) | mutation-guarded |
| N2 inline-style invariant | **RESOLVED** | mutation → 2 FAILs |
| N3 `home()` helpers | **RESOLVED, zero output drift** | full-site diff classified |
| N4 About copy | **RESOLVED, contract intact** | join/PMI/schema identical to `main` |

## Verification (executable)

**Baseline + final, clean tree, `53ccdc6`:**
```
$ bash tests/run-experience-tests.sh
== 124 passed, 0 failed ==   EXIT=0
  ok   fixture: every relative href resolves (BROKEN: 0)
  ok   site: every relative href resolves (BROKEN: 0)
  ok   dim chip marks placeholder status as visible text
```

**B1 — crumbs resolve (real site, not fixture-only):**
```
role/frontend-critic     -> ../../roles/index.html     => EXISTS
skill/docs-no-hallucinate-> ../../skills/index.html    => EXISTS
learning/olympus-...     -> ../../learnings/index.html => EXISTS
```

**B1b — the gate genuinely goes RED.** Reintroduced the exact original bug
(`scripts/experience_build.py:539` → `("← Roles", "../index.html")`):
```
$ bash tests/run-experience-tests.sh   # EXIT=1
BROKEN: 5
   role/fixture-builder/index.html -> ../index.html      (+4 more)
  FAIL fixture: every relative href resolves (BROKEN: 0)
BROKEN: 2
   role/frontend-critic/index.html -> ../index.html
   role/web-frontend/index.html -> ../index.html
  FAIL site: every relative href resolves (BROKEN: 0)
== 122 passed, 2 failed ==
```
A `class="crumb"` grep is satisfied by a 404; this crawl is not. It names the offending
`file -> href`, so the next regression is diagnosable, not just red. Crawler coverage checked
against the current renderer's output shape: no query-string hrefs, no single-quoted hrefs, no
`src=`/`srcset=` attributes, and no link resolving outside the site root — no live blind spot.

**N2 — invariant is real.** Injected `style="color:red"` on the home pagehead:
```
FAIL no inline style= attributes in fixture HTML
FAIL no inline styles in site HTML          == 122 passed, 1 failed ==
```
No false positive on `rel="stylesheet"` (baseline green).

**N1 — guard is real.** Removed the `chipmark` span:
```
FAIL dim chip marks placeholder status as visible text   == 123 passed, 1 failed ==
```

**N3 — "byte-identical" claim verified, not taken on trust.** Built the same fixture at
`b6e3df0` (pre-refactor) and `53ccdc6`, then classified **every** differing line across all 46
pages:
```
 46 > [CHIPMARK line]      (N1, intended)
 10 < [CRUMB-OLD ../index.html] -> 5 roles + 3 skills + 2 learnings [CRUMB-FIX]  (B1, intended)
  4 > [ABOUT-COPY]         (N4, intended)
  0   unaccounted
```
The `home()` split contributed no output change. Every page differs only because the chip lives
in the shared header.

**N4 — Wave 1 contract boundary intact.** Fixture data at `main` vs `HEAD`:
```
join/company/wave/status identical: True
PMI identical: True
schema_version: 1 -> 1
```
The PR does touch `scripts/experience_data.py` (7 lines), but it is the Wave 2 `phase_note`
extraction only (`'## Active phase'` heading → `'| Wave plan | fixture |'`, the actual note),
landed in `b6e3df0` and outside batch 1's blocking scope. No join rule, no PMI, no schema change.
About copy present on the real site.

**SYNTHESIS §4–§6:** §4.1 routes all present and now all reachable (the crumb fix restores the
back-edge). §6.5 static-is-a-feature — no JS added. §6.7 "status not color-only" — satisfied by
N1. §6.8 green/red only with text labels — unchanged.

## N5 — NON-BLOCKING, do not open a third round

The N1 a11y fix slightly degrades the very thing it improves: the accessible *name*. Inline
elements contribute no implicit whitespace (accname §4.3.1 step 2F), so the chip is announced as
one glued word. `scripts/experience_build.py:117`:
```
$ bash /tmp/n5-accname.sh site/experience     # EXIT=1
GLUED ACCESSIBLE NAMES: 3
   'aegisplaceholder'   'rios-operatorplaceholder'   'wearforrunplaceholder'
```
Sighted users are fine (CSS `margin-left: 5px`); screen-reader users hear `aegisplaceholder`.
Before N1 the name was `aegis`, so this is a small net regression on that one axis.

One-character fix — a leading space inside the span (visually identical, margin already owns the gap):
```
'<span class="chipmark"> {status}</span>'   ->   accname 'aegis placeholder'
```

## Do not repeat

- A `grep` for a class name proves markup exists, never that it *resolves*. Link-shaped
  assertions need a crawl.
- A new guard is worth nothing until you break the code and watch it fail. All four guards in
  this PR were mutation-tested before approval.
- Visible text is not the same as accessible name: adding a `<span>` next to text changes what a
  screen reader announces (no implicit space).

## State

Tree clean at `53ccdc6`; `site/experience/` is gitignored, so the mutation builds left no dirt.
Temporary worktrees removed. No files modified by this seat except `handoff.md`.
