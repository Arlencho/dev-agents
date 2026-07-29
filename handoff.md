# Handoff — Fleet Desk v2 Phase A (web-frontend)

Task: implement `docs/proposals/fleet-desk-v2-SYNTHESIS.md` Phase A per sketch `docs/proposals/sketches/fleet-desk-v2-hybrid.html`. Branch `feat/fleet-desk-v2-phase-a`.

## Built

- **Visual system** (`templates/experience/site.css`, full rewrite): dark-first Almanac craft on the sketch's tokens (bg #0a0c11, accent #4cc2ff, pipeline hues); light scheme kept behind `prefers-color-scheme: light`; reduced-motion still kills animation. New styles: `.hier`, `.mode`, `.pipeline/.pipe`, `.mission-grid/.mission`, `.issue-hero`, `details.wave-card`, `.repo-chip`, Floor `.ambient/.led/.waiting/.lanes/.lane.ghost/.spine`, `.st-warn`. All HTML class names were cross-checked against the CSS (script in Evidence).
- **Hierarchy chrome** on every page: `Renderer.hier()` renders Global › Company › Repo › Mission › Wave/Task with dimmed placeholders (`…`/`any`/`—`) and the current level highlighted; header gains the **Almanac | Floor** mode toggle and the v2 tagline.
- **Missions, derived renderer-side only** (`scripts/experience_build.py: derive_missions`): trails group by primary issue anchor — gh-resolved issue > full URL > bare `#N` scoped per company. New routes: `missions/index.html` (portfolio cards, path `company / repo / #issue`, settled meter) and `mission/<slug>/index.html` (hero, pipeline strip, one collapsible wave-card per wave, "Around this mission" context; single-trail missions collapse to simple 1:1 with no wave chrome).
- **Global home**: pipeline strip (Queued/In flight = honest `—` pointing at the Floor; Blocked/Settled counted from trail statuses), stats, companies, top-4 missions, live teaser empty state.
- **Company page**: repo chips (github_repo + local path), company-scoped pipeline, missions grid.
- **Work**: keeps group-by-wave + flat toggle; new **Mission** column links each trail up to its mission; trail detail gains a Mission row and full hier strip.
- **`live/index.html` Ops Floor shell**: offline LED, empty waiting-on strip, ghost Wave lanes, dashed Conductor spine, `make desk-live` teach — zero fake live data.
- **Docs**: `docs/experience.md` v2 walkthrough; `docs/experience-data.md` new "Derived views" section (mission anchor rules, pipeline mapping, Floor shell).
- **Tests** (`tests/run-experience-tests.sh`): fixture v2 smokes (hier strip per page, live shell, honest dashes) + injected-contract mission block (multi-wave grouping, 1:1 collapse, company-scoped bare refs, hex-color rejection, link crawl) + Part B smokes.

## Decisions (+why)

- **No schema change.** Missions derive in the renderer from schema v2 fields (`issue_links`, `issue_links_resolved`, `company_id`, `wave`, `status`); `experience_data.py` untouched, join/PMI gates intact. The SYNTHESIS preferred this and there was no field a `missions[]` projection could add that the renderer can't compute.
- **Bare `#N` anchors limited to ≤5 digits.** Real data had `#050505` (a hex color in a theme handoff) parsing as an issue ref; 6+ digit tokens never anchor a mission. Heuristic documented in experience-data.md § Derived views.
- **Queued/In flight render as `—`, never counts.** The Almanac only sees settled handoffs; inventing live counts breaks the honesty law. Phase B owns live numbers.
- **Mission state vocabulary** = settled / blocked / mixed / open (defined in experience-data.md) — "in flight" is deliberately not a mission state.
- **Wave cards use `<details>`**, no JS anywhere; mission progress uses `<meter>` because inline `style=` is test-banned.
- **`experience_data.py` not touched at all** — the "thin projection if needed" escape hatch was not needed.

## Open questions

- Bare-ref missions keyed `unlinked#N` (no company join) render with company "unlinked" — acceptable, or should they be suppressed from the portfolio? Critic call.
- Real repo currently has **zero** issue-linked handoffs, so Missions shows the empty state in production data; first real mission appears when a handoff cites an issue.

## Do not repeat

- Python here is 3.9: **no backslashes inside f-string expressions** (broke the build once — hoist such strings into variables).
- `assert_absent_html` bans `[[:space:]]style=` — no inline styles, ever; use `<meter>`/classes.
- The link crawler resolves footer `data/index.json` too — injected-contract test sites must build data into the site dir (`experience_data.py --out <site>` then patch), not pass `--data` from outside.
- New pages at depth 1 (`missions/`, `live/`) need `../`-prefixed links in hand-written body HTML; the crawler catches what the eye misses.

## Evidence

- `./tests/run-experience-tests.sh` → `== 261 passed, 0 failed ==` (was 244 before; +17 v2 checks)
- `make test` → "All test suites passed."
- `make experience` → builds; `site/experience/{missions,live}/index.html` written; false mission `unlinked-050505` gone after the ≤5-digit guard.
- Class coverage: every `class=` in rendered HTML exists in `templates/experience/site.css` (regex cross-check, output "none").
- Injected-contract check: `mission/acme-12` (3 wave-cards), `mission/example-acme-app-9` ("Single task"), work/company/trail pages link up.

## Next hint (critic)

Focus on (1) the mission-anchor heuristics in `_mission_anchor` (bare-ref scoping + digit cap) against the honesty law, (2) whether the live shell reads as structure-not-data, (3) craft fidelity to the sketch (hier strip, pipeline tiles, mission cards) in both color schemes, (4) the new Derived views doc matching the code exactly.

---

# CRITIC VERDICT — loop 1 of 2

**VERDICT: REVISE** (test-only; no production change requested)

Method: adversarial mutation testing. Nine mutations applied to
`scripts/experience_build.py` / `templates/experience/site.css`, one per
Phase-A gate; each run through `tests/run-experience-tests.sh` (20 s/run).
A gate is *pinned* only if its mutation turns the suite RED.

## Gate results (functional behaviour: all pass)

| # | Gate | Result | Evidence |
|---|------|--------|----------|
| 1 | Hierarchy chrome + Almanac\|Floor toggle | **PASS** | M3 → 7 FAIL; M9 → 2 FAIL |
| 2 | Dark-first craft + a11y text+color, reduced-motion | **PASS impl / UNPINNED** | CSS:80-81 correct, but M7 + M8 survive |
| 3 | Missions derived honestly, no invented companies | **PASS impl / UNPINNED** | M1 → 1 FAIL, M6 → 2 FAIL, but **M5 survives** |
| 4 | Queued/In flight not fabricated | **PASS** | `experience_build.py:389-390` hardcodes `—`; M2 → 1 FAIL |
| 5 | `/live/` teaches `make desk-live`, no fake agents | **PASS** | M4 → 3 FAIL incl. `assert_absent_html`; `desk-live` absent from Makefile and page frames it as Phase B |
| 6 | `experience_data.py` join/PMI untouched | **PASS** | `git diff --name-only 3e8d8ea..fca45f0 -- scripts/experience_data.py` → 0 lines; `schema_version` still `2`; no `missions[]` in contract; documented in `docs/experience-data.md` |
| 7 | `make test` green + smokes non-vacuous | **PARTIAL** | 261 passed / 0 failed, but **mutation score 6/9 (67 %)** |

## Executable failures — 3 surviving mutations

Each is a *missing assertion*, not a code defect. Shipped behaviour is correct;
nothing defends it against regression.

### C1 — company/repo invention on unlinked missions is unpinned (gate 3, HIGH)

`experience_build.py:178` correctly resolves `company_id` to `None` when no
trail is joined. Nothing tests it. Mutation:

```python
company_id = next((t["company_id"] for t in ts if t["company_id"]), None) \
             or (companies[0]["id"] if companies else None)
```

→ **261 passed, 0 failed.** Repro (fixture, unlinked trail `2-fixture-builder-gadget` seeded `issue_links: ["#77"]`):

```
clean    : <span class="path">unlinked / repo — / #77</span>
mutated  : <span class="path">acme / Example/acme-app / #77</span>   # company AND repo invented
```

Severity is high because this is the path **real data takes**: all 19 trails in
the live corpus are `join_method: unlinked`, so the first genuine `#N` handoff
renders through exactly this branch. The existing mission block only injects
issue links onto *acme-joined* trails, so the unlinked path is never exercised.

Answering the producer's open question: **`unlinked#N` is correct — keep it, do
not suppress.** `unlinked / repo — / #77` is the honest rendering. Pin it.

### C2 — reduced-motion is unpinned (gate 2, MEDIUM)

`templates/experience/site.css:80-81` is correct. Deleting the whole block:

→ **261 passed, 0 failed.** Two live `transition:` rules (`site.css:341`, `:503`)
would then animate for users who asked not to.

### C3 — text+color is unpinned (gate 2, MEDIUM)

`experience_build.py:399` emits state text inside the pill. Mutation to
`<span class="st {cls}"></span>` (colour only, WCAG 1.4.1):

→ **261 passed, 0 failed.**

## Requested change — add these 4 assertions to `tests/run-experience-tests.sh`

Verified: all 4 GREEN on current code; each goes RED **only** under its own
mutation (no cross-talk). Extend the existing injected-contract block with
`2-fixture-builder-gadget → ["#77"]`, then:

```bash
grep -q 'unlinked / repo — / #77' "$MS/missions/index.html" \
  && ok "unlinked mission keeps honest path" || bad "unlinked mission keeps honest path"
grep -qE 'class="path">[^<]*(acme|aegis|olympus)[^<]*#77' "$MS/missions/index.html" \
  && bad "no company invented for unlinked mission" || ok "no company invented for unlinked mission"
grep -q 'prefers-reduced-motion' "$FIXOUT/assets/site.css" \
  && ok "stylesheet honors prefers-reduced-motion" || bad "stylesheet honors prefers-reduced-motion"
grep -qE '<span class="st st-[a-z]+"></span>' "$MS/missions/index.html" \
  && bad "state pill carries text, not color alone" || ok "state pill carries text, not color alone"
```

Mutation matrix after the fix (verified):

| Assertion | clean | M5 | M7 | M8 |
|---|---|---|---|---|
| C1a unlinked path | ok | **FAIL** | ok | ok |
| C1b no invented company | ok | **FAIL** | ok | ok |
| C2 reduced-motion | ok | ok | **FAIL** | ok |
| C3 text+color | ok | ok | ok | **FAIL** |

## Not requested

No redesign, no re-implementation. Derivation logic, hex-guard heuristic,
`unlinked#N` keying, pipeline `—` and the Floor shell are all correct as
shipped. Working tree restored clean after every mutation
(`git status --porcelain` → 0).
