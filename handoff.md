# Handoff — Fleet Desk v2 Phase A, critic loop 2 (VERIFY ONLY)

Task: re-verify on PR #57 `feat/fleet-desk-v2-phase-a` @ `f99e42b` that the loop-1 pins M5/M7/M8 are **load-bearing** under executable mutation, that production logic is unchanged, and that Phase A SYNTHESIS gates still hold. No redesign, no re-implementation.

## VERDICT: APPROVE

All three loop-1 surviving mutations are now killed by tests. Each pin goes RED **only** under its own mutation — no cross-talk. Baseline and full `make test` are green. The revision introduced zero production-code change. One non-blocking residual is logged for Phase B.

## Mutation matrix (each applied, suite run, then `git checkout --` reverted)

| # | Mutation | Site | Result | RED assertions |
|---|---|---|---|---|
| — | baseline (unmutated) | — | `265 passed, 0 failed`, exit 0 | — |
| — | full `make test` | — | `All test suites passed.`, exit 0 | — |
| M5a | `m['company_id'] or companies[0]` | `scripts/experience_build.py:405` (render) | `263 passed, 2 failed` | "unlinked mission keeps honest path"; "no company invented for unlinked mission" |
| M5b | `next(..., companies[0]["id"])` | `scripts/experience_build.py:178` (derivation — the literal loop-1 mutation) | `263 passed, 2 failed` | same two |
| M7 | delete `@media (prefers-reduced-motion: reduce)` block | `templates/experience/site.css:80-82` | `264 passed, 1 failed` | "stylesheet honors prefers-reduced-motion" |
| M8 | `<span class="st {cls}"></span>` (color-only) | `scripts/experience_build.py:399` `_state_pill` | `264 passed, 1 failed` | "state pill carries text, not color alone" |

M5 is **stronger than the producer claimed**: the pin fires at both the derivation site (`:178`, cited in the loop-1 handoff) and the render fallback (`:405`). Company invention cannot slip in at either layer.

Producer's reported numbers reproduce **exactly** (263/2, 264/1, 264/1, 265/0). No inflated claims found.

## Coverage probes (beyond the assigned three)

There are three pill renderers. I mutated each to color-only to find unpinned WCAG 1.4.1 surface:

| Renderer | Site | Result |
|---|---|---|
| `_state_pill` (mission cards) | `:399` | RED — pinned by new M8 assertion |
| `status_pill` (trail rows) | `:335` | RED — pinned by pre-existing "status is text AND color" |
| `_static_status_pill` (mission-detail task tables) | `:458` | **GREEN — mutation survives** |

### Residual R1 (non-blocking, Phase B follow-up)

`scripts/experience_build.py:458` `_static_status_pill` can be reduced to `<span class="st st-{kind}"></span>` and the entire suite stays `265 passed, 0 failed`. The M8 pin only greps `missions/index.html`; this renderer emits into `mission/<slug>/index.html` task tables (called at `:436`).

**Not a defect and not a gate.** Shipped code is correct today (it renders `{esc(status)}`); this is a test-coverage gap, not a production bug. Suggested one-line fix in Phase B, mirroring the existing M8 pin against a mission detail page:

```sh
grep -qE '<span class="st st-[a-z]+"></span>' "$MS/mission/acme-12/index.html" \
  && bad "task-table pill carries text, not color alone" \
  || ok  "task-table pill carries text, not color alone"
```

Gating loop 3 on an already-correct line would burn a CTO escalation on a non-defect — precisely the diminishing-returns case the 2-loop ceiling exists to prevent.

## Production logic unchanged — verified

- `git show --name-only f99e42b` → **`handoff.md`, `tests/run-experience-tests.sh` only.** The revision touched no production file, so `experience_build.py` / `site.css` behavior is bit-identical to the reviewed `fca45f0`.
- `git diff 3e8d8ea..f99e42b -- scripts/experience_data.py` → **empty.** Data layer byte-identical to main.
- `SCHEMA_VERSION = 2` on both branch and main — no schema bump, no migration debt.
- No true bugs found; therefore no production edits were warranted or made.

## Phase A SYNTHESIS gates re-checked (`docs/proposals/fleet-desk-v2-SYNTHESIS.md:66-121`)

| Gate | Status | Evidence |
|---|---|---|
| 1 Visual system, a11y text+color + reduced motion | HOLD | M7/M8 pins now enforce both |
| 2 Hierarchy chrome all pages | HOLD | `hier` nav asserted across page loop (`:388`) |
| 3 Global home pipeline strip + live teaser | HOLD | honest `—` for Queued/In flight (`:389-390`) |
| 4 Company page repos + missions | HOLD | "company page lists its missions" green |
| 5 Missions index `company / repo / #issue` | HOLD | asserted `:438`, plus new unlinked-path pin |
| 6 Mission / issue run page | HOLD | 3 wave-cards asserted `:442` |
| 7 Work links up to mission | HOLD | asserted `:451` |
| 8 `/live/` shell, no fake agents | HOLD | `assert_absent_html "live shell invents no live-state chrome"` |
| 9 Simple 1:1 collapse | HOLD | "simple 1:1 hides the wave chrome" green |
| 10 Tests + `make test` green | HOLD | exit 0, all suites |
| 11 `docs/experience.md` walkthrough | HOLD | updated in diff |
| §5.5 join/PMI law intact | HOLD | `experience_data.py` untouched; schema still 2 |

## Integrity

- Post-run `git status --porcelain` → **empty**; `git diff HEAD -- scripts/ templates/` → **empty**. Every mutation reverted; no mutated file committed.
- HEAD `f99e42bb87018df73707bfd777b7e0fdbf364a80` == `origin/feat/fleet-desk-v2-phase-a`.

## Next step

Ship PR #57. Carry residual R1 into the Phase B test pass.
