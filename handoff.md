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
