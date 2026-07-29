# Proposal (Seat C): Fleet Almanac — the operator's memory for fleet work, skills & learnings

**Author:** Proposal seat C (independent — no convergence with seats A/B)
**Date:** 2026-07-29
**Brief:** `docs/proposals/experience-console-BRIEF.md`
**Status:** Design proposal only. No product UI code in this wave.

---

## 1. Product name + pitch

**Fleet Almanac.**

An almanac is what a working captain keeps: not a dashboard of live gauges, but the accumulated record — where the ship went, what the crew learned, which playbooks earned their place. Fleet Almanac is a **read-only, statically generated operator console** that projects the git-tracked artifacts `dev-agents` already produces (wave plans, handoffs, skill packs, learnings, company manifests) into two scopes — **Global** (whole fleet) and **per Company** — so the owner can answer in under two minutes: *what did the fleet do, what does it know, and how much can I trust each role's playbook today?*

One-sentence pitch: **"GitHub tells you what tickets exist; Fleet Almanac tells you what your fleet did and learned."**

Why not "Experience Console": accurate but generic; "Almanac" carries the honest stance of this design — a *record of evidence*, not a live control panel and not a scoreboard of agent personalities.

---

## 2. User journeys

### J1 — Morning scan (Global home), < 2 min
Owner runs `make experience`, browser opens. Sees: companies strip (5 manifests, status chips), last 10 work trails with role/status chips, a "Do-not-repeat watchlist" (recurring failure themes), skill library summary (6 active packs, 0 candidates), learning pipeline funnel (raw → promoted). Clicks one trail → J4.

### J2 — "What has the fleet done on SafePlace?" (Company page)
Clicks `safeplace` in the company strip. Same cards, filtered: work trails for that repo, project skill overrides (if `<repo>/skills/` exists on disk), product learnings (if discoverable), role usage for this repo only. Company frontmatter (budget, github_repo, phase table) rendered as a manifest card, not raw YAML.

### J3 — "Is `web-frontend` getting better or just busier?" (Role page)
Clicks a role chip. Sees: task count + done/fail split, vendor mix from provenance, critic pairing rate, injected packs and their versions, and the **Playbook Maturity Index** (§5.2) with its formula expanded inline — every input is a link to the handoffs/git paths it was computed from. No badge without evidence.

### J4 — "What actually happened on this task?" (Work trail page)
One trail = one page: plan line text, wave, role seat, branch, base→head SHA (linked to GitHub compare when `github_repo` is known), status + timestamps, handoff `## Decisions` and `## Do not repeat` sections, orchestrator fields (files touched, diff stat, exit code), and the raw JSONL line collapsible at the bottom for audit.

### J5 — "Did that cost-runaway lesson become a skill?" (Learning → promotion)
From Global home's learning funnel, clicks `paperclip-cost-runaway-2026-05-13`. Learning page shows the note, its status (`raw` / `documented` / `promoted` / `superseded`), and — if promoted — the skill bullets citing it via `[ev: …]`, with a link to the pack. If unpromoted, an empty state teaches: *"Not yet a skill. Promotion is PR-only — see skills-evolution SYNTHESIS §2.4."*

### J6 — "Which roles inject `git-ship`, and at what version?" (Skill page)
Skill page shows pack id, version, summary, max_lines, role attachment list (from `config/role-skills.yaml`), project overrides in effect per company, version history (git log on the pack dir, Phase 1), and the full pack body rendered read-only.

Click budget: every destination above is ≤ 3 clicks from Global home.

---

## 3. Information architecture + wireframes

### 3.1 Sitemap (dual scope is one dimension, not two apps)

```
/                          Global home (all companies)
/company/<name>/           Company scope (same cards, filtered)
/trail/<task_id>/          Work trail detail
/role/<role>/              Role usage + maturity
/skill/<pack_id>/          Skill pack detail
/skill/<pack_id>/?co=<x>   Skill as seen by company x (override view)
/learning/<slug>/          Learning detail
/conductor/                Conductor session index (wave-plans/conductor/)
/about                     Data sources, generation time, formula glossary
```

The scope switcher is a persistent strip at the top: **`● Global | olympus | safeplace | rios-operator | aegis° | wearforrun°`** (`°` = placeholder status from frontmatter). Every page under `/company/<name>/` renders the same component set as Global — dual scope by construction, not by duplication.

### 3.2 Global home (wireframe)

```
┌──────────────────────────────────────────────────────────────────────┐
│ FLEET ALMANAC        ● Global │ olympus safeplace rios-op aegis° wfr°│
│ generated 2026-07-29 10:04Z · 47 trails · 6 packs · 3 learnings      │
├──────────────────────────────────────────────────────────────────────┤
│ COMPANIES                                                            │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌─────────┐ ┌────────┐ │
│ │ olympus    │ │ safeplace  │ │ rios-op    │ │ aegis°  │ │ wfr°   │ │
│ │ ● active   │ │ ● active   │ │ ◌ placehold│ │ ◌       │ │ ◌      │ │
│ │ 12 trails  │ │ 8 trails   │ │ 0 trails   │ │ —       │ │ —      │ │
│ └────────────┘ └────────────┘ └────────────┘ └─────────┘ └────────┘ │
├──────────────────────────────────┬───────────────────────────────────┤
│ RECENT WORK TRAILS               │ DO-NOT-REPEAT WATCHLIST           │
│ ● done  web-frontend   T05 jsonld│ ⚠ "mailto already correct" ×3     │
│   black-aces · wave 9 · 2d ago   │   waves 7,8,9 — same verification │
│ ● done  frontend-critic T09 theme│   re-done by 3 seats              │
│ ✖ fail  go-backend     OLY pay   │ ⚠ "npm build missing" ×2          │
│   olympus · wave 4 · 5d ago      │   empty-state: run make evidence  │
│ … view all (filter: role ▾ co ▾) │                                   │
├──────────────────────────────────┼───────────────────────────────────┤
│ SKILL LIBRARY                    │ LEARNING PIPELINE                 │
│ evidence-first   v1 · 17 roles   │ raw ▓▓ 2                          │
│ git-ship         v2 · 17 roles   │ documented ▓ 1                    │
│ handoff-intent   v1 · 10 roles   │ promoted ░ 0                      │
│ session-modes    v1 · 1 role     │ superseded ░ 0                    │
│ _candidates: empty               │ → promotion is PR-only (SYN §2.4) │
├──────────────────────────────────┴───────────────────────────────────┤
│ ROLE USAGE (top 5)                    tasks  done  vendors  PMI      │
│ web-frontend                            14    93%   k,c      P2 ▏formula│
│ frontend-critic                         12   100%   k,c      P1 ▏formula│
│ … full table on /role/                                                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.3 Work trail detail (wireframe)

```
┌──────────────────────────────────────────────────────────────────────┐
│ ← Global · black-aces · wave 9                                       │
│ 9-web-frontend-feat-ab-T05-jsonld-org                       ● done   │
├──────────────────────────────────────────────────────────────────────┤
│ role web-frontend │ seat kimi/sonnet · localhost │ wave 9            │
│ branch feat/ab-T05-jsonld-org                                       │
│ e44ec21 → b55471a  (compare on GitHub ↗)          2026-07-20 13:32Z  │
│ files: index.html (+9) · exit 0 · PR: not linked                    │
├──────────────────────────────────────────────────────────────────────┤
│ PLAN LINE    "Add exactly one Organization JSON-LD block…"           │
│ DECISIONS    - Placed at end of <head> after inline <style>…         │
│ DO NOT REPEAT - Do not add additional Organization JSON-LD blocks…   │
│ ▾ Raw handoff JSONL (audit)                                          │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.4 Component inventory (12 components, all server-rendered static HTML)

| # | Component | Feeds | Notes |
|---|-----------|-------|-------|
| C1 | `ScopeStrip` | `companies/*.md` frontmatter | Persistent; `°` for placeholders |
| C2 | `CompanyCard` | manifest + trail count join | Status chip from `status:` |
| C3 | `TrailRow` | handoff JSONL + plan line | Status chip: done / fail / unknown |
| C4 | `TrailDetail` | JSONL + handoff md sections | Raw JSONL in `<details>` |
| C5 | `WatchlistCard` | `## Do not repeat` sections | Recurrence clustering (§4.4) |
| C6 | `SkillCard` | SKILL.md frontmatter + role-skills.yaml | Version, role count, scope |
| C7 | `SkillDetail` | pack body + override scan | Read-only; links to repo path |
| C8 | `LearningFunnel` | learnings/ + `[ev:]` back-grep | 4-status model (§4.5) |
| C9 | `LearningDetail` | learning md + citing bullets | Promotion empty state teaches PR flow |
| C10 | `RoleTable` / `RoleDetail` | JSONL aggregate + role-skills.yaml | PMI with inline formula (C11) |
| C11 | `FormulaDisclosure` | static text + computed inputs | Every metric shows its inputs |
| C12 | `EmptyState` | per-card | Teaches the CLI command that fills the card |

---

## 4. Data model / joins from existing files

Everything is a **read-only projection**. One build pass (`scripts/experience-build.sh`) scans, joins in memory (awk/associative arrays), emits static HTML + one `index.json` for future phases. No daemon, no DB, no writes outside `site/experience/` (gitignored).

### 4.1 Sources → fields

| Source (verified to exist) | Fields extracted |
|---|---|
| `companies/*.md` frontmatter | `name`, `status`, `repo`, `github_repo`, `budget_monthly_cents` |
| `wave-plans/**/*.plan` | wave id, plan lines: `wave | role | task text | branch` |
| `wave-plans/*/handoffs/*.jsonl` | `task_id`, `wave`, `agent`, `provenance.{vendor,model,host}`, `branch`, `base_sha`, `head_sha`, `ts`, `status`, `orchestrator_fields.{files_touched,diff_stat,agent_exit}` |
| `wave-plans/*/handoffs/*.md` | `## Built`, `## Decisions`, `## Do not repeat`, `## Evidence`, `## Next hint` |
| `skills/<id>/SKILL.md` frontmatter | `id`, `version`, `scope`, `summary`, `max_lines` |
| `config/role-skills.yaml` | role → pack list (grep-friendly; no YAML lib needed) |
| `skills/_candidates/` | candidate pack ids (dir listing) |
| `learnings/*.md` | slug, title, date from filename |
| `config/workers.yaml` | role → vendor seat map (primary vendor column) |
| `wave-plans/conductor/` | Conductor session READMEs/plans (first-class index) |
| `wave-plans/ab-metrics.csv` | supplementary per-task metrics when present |
| `logs/evidence.csv` (optional, if operator ran `make evidence`) | quality aggregates — displayed with "generated by make evidence" provenance, never recomputed |

### 4.2 The work-trail join (core)

```
plan line (wave-plans/<n>/*.plan)
   │  key: wave + role + branch  (branch is the strongest join key;
   │  task_id embeds wave-role-branch: "<wave>-<role>-<branch-slug>")
   ▼
handoff JSONL (task_id match; multiple lines = multiple seats/runs of same task)
   │  key: task_id → handoff md (same basename)
   ▼
company  (branch prefix, repo in plan dispatch context, or company name in
   │       task_id/plan filename — e.g. "feat/ab-T05" → black-aces plan file;
   │       plan filename "olympus-platform-*.plan" → olympus)
   ▼
GitHub URL (companies/<x>.md github_repo + branch →
            https://github.com/<org>/<repo>/compare/<base>...<head>)
   │
   ▼
issue/PR ref (regex `#\d+` and `owner/repo#\d+` over plan line + handoff md)
```

Join honesty rule: when a join key is absent (common: no `github_repo` for black-aces-style local work, no issue ref), the UI shows **"not linked"** — never a guess. Provenance fields vary across waves (`model` vs `requested_model`/`effective_model` per Ground Truth): the scanner takes the first present and labels which field it used on `/about`.

### 4.3 Project-scope discovery (proposed rules, no invented paths)

For company `x` with `repo:` pointing to a path that exists on disk:
- project skills: `<repo>/skills/<id>/SKILL.md` (per SYNTHESIS §2.2 — frozen path)
- project learnings: `<repo>/docs/qa/learning-*.md` (per brief §3.1 — only this one pattern; anything else is a Phase 1 config line in the company manifest, e.g. `learning_paths:`)
- if `repo` is `TBD` / missing on disk → company renders with fleet-side data only and an empty state: *"repo not on disk at `<path>` — project overrides not scannable."*

### 4.4 Do-not-repeat watchlist

Parse `## Do not repeat` bullets from every handoff md. Normalize (lowercase, strip punctuation, first 8 words) and cluster exact + near matches. Surface clusters with count ≥ 2, listing contributing trails. Rationale: a repeated do-not-repeat is the fleet's loudest un-learned lesson — and per the SYNTHESIS kill criterion, repeated `do_not_repeat` on skill-covered classes is the signal that packs aren't working. This card *is* the kill-criterion meter.

### 4.5 Learning status model

| Status | Rule (all greppable) |
|---|---|
| `raw` | file in `learnings/`, no frontmatter |
| `documented` | has frontmatter or `## `-structured body |
| `promoted` | its filename/path appears in an `[ev: …]` citation inside any `skills/**/SKILL.md` |
| `superseded` | manually marked `status: superseded` in frontmatter (human decision, never inferred) |

### 4.6 Secrets & safety

Scanner never reads `logs/*.log` (transcripts stay out per Ground Truth), never reads `.env*` (gitignored anyway), and runs the emitted HTML through a final grep for token-shaped strings (`sk-`, `ghp_`, `oauth`) — fail the build on match. Static output defaults to gitignored `site/experience/`; nothing is published.

---

## 5. Metrics: role usage + the seniority model

### 5.1 Role usage (transparent stats, per role, both scopes)

- `n_tasks`, `n_done`, `n_fail` → success rate with n shown (`93% · n=14` — never a bare %)
- vendor mix from `provenance.vendor` (e.g. `kimi 8 · claude 6`), primary seat from `workers.yaml`
- critic involvement: ratio of critic-role trails to producer-role trails per discipline pair (detectable from role names ending in `-critic`)
- skill coverage: packs injected beyond the `default:` line in `role-skills.yaml` (e.g. `docs-writer` has `docs-no-hallucinate` → coverage 1; `web-frontend` → 0)
- median wall time between `base_sha`'s commit time and handoff `ts` when both available (time-to-ship, Phase 1)

### 5.2 Playbook Maturity Index (PMI) — the honest "seniority" model

**Explicit rejection:** no "Agent is Senior III" personality badges. Seniority here is a property of the **role's playbook + recorded outcomes**, computed from four greppable inputs, with the formula rendered on the page next to the score.

```
PMI(role) = P0..P3, where P3 requires:
  (a) n_done ≥ 10 with success_rate ≥ 80%            [ev: handoff JSONL aggregate]
  (b) role_coverage ≥ 1 dedicated pack beyond defaults [ev: role-skills.yaml diff vs default:]
  (c) Σ version bumps across injected packs ≥ 2       [ev: git log -p skills/<id>/]
  (d) no do-not-repeat cluster with count ≥ 2 whose
      trails are ≥ 50% this role, in the last 30 days  [ev: watchlist join]
P2 = (a) with n_done ≥ 5 + (d)
P1 = (a) with n_done ≥ 1
P0 = no completed trails
```

Every PMI renders as `P2 ▏formula` — clicking expands C11 (`FormulaDisclosure`) showing the four inputs, their current values, and the exact file paths they came from. If any input is unmeasurable (e.g. no git history scanned in Phase 0), the level is capped and the cap is stated: *"P2 max — version history not scanned in Phase 0."*

What this buys the owner: PMI answers "can I trust this seat on a hard task?" with *evidence of playbook evolution*, and it points at the exact lever to raise a level (write a dedicated pack, promote a learning, kill a recurring failure). That is the promotion loop made visible — which is what the owner's "seniority, not fake agent IQ" ask actually means.

### 5.3 Skill evolution

- version per pack (integer frontmatter — SYNTHESIS freeze), role attachment count, scope (global/project-override)
- Phase 1: version timeline from `git log --follow skills/<id>/SKILL.md`; learning→skill rate = `promoted / total learnings`; candidate dwell time (days in `_candidates/`)

---

## 6. UX principles + visual system

**Principles**

1. **Evidence over adornment.** Every number is hoverable/clickable to its source path. If the data isn't there, the card says so and teaches the command that produces it (C12).
2. **Two scopes, one grammar.** Global and company pages are the same components with a filter applied — the owner never relearns the UI.
3. **Scan first, drill on demand.** Home is a density-tuned scan surface; prose lives one click down.
4. **Honesty as a visual style.** "not linked", "n=3", "capped at P2" are first-class UI strings, styled neutrally, never hidden.
5. **Static is a feature.** No JS required for core views; `prefers-color-scheme` for dark/light; loads instantly from `file://` or a one-line local server.

**Visual system**

- Type: system sans for prose (`-apple-system, Inter, Segoe UI`), monospace (`ui-monospace, SF Mono`) for SHAs, task ids, branches, paths — the artifacts *are* code, the type should say so.
- Color: near-black `#16161a` / paper `#fafaf7` (light), inverted for dark; one accent (ace-of-spades black-gold `#b8892b`) for interactive affordances only. Status: done `#2e7d4f`, fail `#b3402e`, placeholder/unknown neutral gray — all pass WCAG AA on both themes at 13px+.
- Density: 13–14px base, 8pt grid, table-first layouts (this is an operator tool, not marketing).
- Layout: max-width 1120px, single column of cards; company strip sticky.
- Accessibility: semantic landmarks (`nav/main/section` with `h1→h2` order), skip-link, full keyboard operability (native `<a>`/`<details>` — zero custom widgets in Phase 0), focus-visible rings, status conveyed by text + color (never color alone).
- Empty states teach: *"No handoffs yet — run `./scripts/dispatch.sh <repo> <plan>` then `make experience`."*

---

## 7. Phase 0 ship list (days, not months)

Concrete, dependency-free (bash + awk + git — same toolchain as the rest of the repo):

| File | What |
|---|---|
| `scripts/experience-build.sh` | Scanner + joiner + HTML emitter (one pass; sources per §4.1; redaction gate per §4.6) |
| `templates/experience/` | 3 HTML partials: `page-head.html`, `card.css`, `page-foot.html` (single shared stylesheet, inline) |
| `Makefile` | `experience` target: build → `site/experience/index.html`; `experience-open` appends `open` |
| `.gitignore` | `site/experience/` |
| `tests/run-experience-tests.sh` | Fixture-based: tiny fake `wave-plans/` + `skills/` tree → assert joins, redaction gate, empty states, PMI caps; wired into `make test` |
| `docs/experience-console.md` | Operator doc: what it reads, refresh model (re-run `make experience`), known join gaps |

Phase 0 explicitly includes: Global home, company pages, trail detail, role table + PMI (capped at P2 — no git-history scan), skill library + detail, learning funnel + detail, watchlist, conductor index, `/about` with provenance labels.

Phase 1 (only after Phase 0 is used daily): PMI full inputs via `git log` on pack dirs, issue/PR deep links via `gh api` when authed, version timelines, `index.json` consumer (e.g. Paperclip panel), time-to-ship.

Phase 2+ (only if loved): checked-in snapshot under `docs/experience/` for sharing, multi-operator annotations, notification on watchlist recurrence.

Explicitly **not** in any phase here: auto-promotion of skills (PR-only is law), replacing GitHub Projects, live dispatch control, transcript storage.

---

## 8. Risks, non-goals, open questions

**Risks**
- *Bash HTML generation is fiddly (escaping).* Mitigate: emitter writes content through one `html_escape` function; tests assert on fixtures containing backticks, quotes, `<` in handoff bodies.
- *Join keys are imperfect* (black-aces work has no company manifest; issue refs are free-text). Mitigate: "not linked" honesty rule + plan-filename heuristics labeled as heuristics on `/about`.
- *Handoff md section headers vary across seats/vendors.* Mitigate: parser matches the four frozen headers from `handoff-intent` SKILL; unmatched sections fall back to raw body in `<details>`.
- *Provenance schema drift* (`model` vs `effective_model`). Mitigate: first-present rule, field used is labeled.

**Non-goals:** GitHub ticket replacement; UI-driven promotion; real-time anything; multi-tenant SaaS; agent personality scores.

**Open questions for the owner**
1. Should `site/experience/` stay local-only, or is a checked-in snapshot under `docs/experience/` wanted for PR review of fleet state (Phase 2)?
2. Is the plan-filename → company heuristic acceptable, or should plan lines gain an explicit `company:` field (small `dispatch.sh`/template change, Phase 1)?
3. PMI thresholds (n≥10, 80%) are seeded from current fleet volume (~50 trails) — revisit after 100+ trails?

---

## 9. Why this beats "`make evidence` + README"

`make evidence` answers "how did the last waves score?" as a terminal table. It cannot answer the brief's six questions because it has no **joins**: it doesn't connect a trail to its plan line, its company, its do-not-repeat theme, its role's packs, or a learning to the skill bullet that cites it. The Almanac is exactly those five joins, rendered with a hierarchy a founder can scan in two minutes — and it keeps `make evidence` as a *source* (§4.1), not a competitor. The README documents the system; the Almanac shows the system's memory. The difference is the difference between documentation and **experience** — which is the product being asked for.

---

*Independence note: written from the brief + frozen syntheses + repo artifacts only. Seats A/B proposal files were not read.*
