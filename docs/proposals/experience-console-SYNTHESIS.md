# Experience Console — Owner SYNTHESIS (Fleet Desk Phase 0 freeze)

**Status:** FREEZE — implement Phase 0 against this document  
**Date:** 2026-07-29  
**Sources:** `experience-console-BRIEF.md` + independent proposals A / B / C  
**PR seats:** [#40](https://github.com/Arlencho/dev-agents/pull/40) (A), [#41](https://github.com/Arlencho/dev-agents/pull/41) (B), [#42](https://github.com/Arlencho/dev-agents/pull/42) (C)  
**Rule:** Build from this freeze, not any single proposal wholesale.

---

## 1. Decision

**Synthesize. Do not pick one proposal file.**

| Pillar | Source | What we take |
|--------|--------|----------------|
| Product framing + dual-scope grammar | **A + B** | Name **Fleet Desk**; dual-scope is one axis (Global / company), same cards both ways |
| Record / honesty stance + sitemap | **C** | Almanac spirit (evidence record, not live gauges); multi-page routes (home, company, trail, role, skill, learning, conductor, about) |
| Architecture | **All** | Read-only **static projection** of git artifacts; no daemon; no cloud; no skill auto-promote UI |
| Phase 0 toolchain | **B + C** (A compatible) | `make experience` (+ alias `make desk`); generator → `site/experience/` (**gitignored**); stdlib HTML/CSS |
| Work trails + joins | **A** heuristics + **B** entity map | Ordered join rules with `join_method` + confidence; ad-hoc projects as labels not fake companies |
| Role usage metrics | **All** | Transparent n / done / fail / vendor mix / critic rate / skill coverage |
| Maturity (“seniority”) | **C PMI** + **A/B formula honesty** | **Playbook Maturity Index (PMI)** on the *role’s playbooks + outcomes*, never agent IQ badges |
| UX craft | **C** visual system + **A/B** density | System fonts, paper/ink, status by text+color, empty states teach next command, ≤ 2–3 clicks |

**Explicitly rejected**

- Replacing GitHub Issues / Projects  
- In-app skill promotion or dispatch buttons (Phase 0–1)  
- Always-on daemon or SaaS dependency for core views  
- Embedding full agent transcripts / `logs/**` agent bodies into the static site  
- Vanity “Senior III agent” titles without expandable evidence formula  
- Heavy SPA toolchain for Phase 0 (Next/React optional only if Phase 0 is loved)  
- Requiring Paperclip heartbeat for core pages  

---

## 2. Product name

| Field | Freeze |
|-------|--------|
| **Product name** | **Fleet Desk** |
| **Brief alias** | Experience Console (keep in brief history; do not invent a third name) |
| **Spirit (from C)** | Almanac: accumulated record of where the fleet went and what it learned |
| **Tagline** | *What the fleet did, learned, and now knows how to do.* |
| **One-liner for docs** | GitHub shows tickets; Fleet Desk shows what multi-seat dispatch did, learned, and can playbook. |

---

## 3. Frozen architecture

### 3.1 Dual scope (law)

```
Global  = union of fleet artifacts under dev-agents + rollups
Company = one companies/<id>.md + trails joinable to that product
          + project skills/learnings when discoverable on disk
```

Same components both scopes. Scope switcher always visible.

### 3.2 Runtime model

```
git artifacts  →  scripts/experience-build.sh (or experience-project.py)
               →  site/experience/**  (gitignored static HTML)
operator       →  make experience  |  make desk  (alias)
               →  open file:// or one-line local static server
```

- **No** new always-on process.  
- **No** API keys required for core views.  
- Optional local enrichment only: `logs/evidence-latest.txt`, vendor-auth JSON if present — never required.  
- **Never** ship secrets: do not ingest agent transcript logs; redact token-like strings if any raw field is shown.

### 3.3 Data sources (Phase 0)

| Entity | Sources |
|--------|---------|
| Companies | `companies/*.md` frontmatter (`name`, `status`, `repo`, `github_repo`, …) |
| Work trails | `wave-plans/*/handoffs/*.{jsonl,md}`; plans `wave-plans/**/*.plan`; conductor `wave-plans/conductor/` |
| Skills | `skills/*/SKILL.md`, `skills/_candidates/`, `config/role-skills.yaml` |
| Project skills | `<product-repo>/skills/` when path from company `repo:` exists on operator disk |
| Learnings | fleet `learnings/*`; product discovery: `docs/qa/learning-*.md`, `learnings/*` under product root if present |
| Role map | `config/workers.yaml` provider_preferences (seat vendor, not marketing) |

### 3.4 Join rules (work trail → company)

Phase 0 **must** record `join_method` and may be imperfect:

1. Explicit map file if present: `config/experience-joins.yaml` (optional; create if hardcoded maps get messy)  
2. Match `github_repo` / repo slug in task text, branch, or plan path  
3. Match company `name` token in plan filename or task text  
4. Else: **unlinked** trail on Global only (show as project label, e.g. black-aces) — do **not** invent a company  

### 3.5 Promotion law (unchanged)

Visible pipeline only: learning / candidate / active skill.  
**Promotion remains PR-only** per skills-evolution SYNTHESIS. UI links to docs; never writes `skills/*/SKILL.md`.

---

## 4. Information architecture (Phase 0 pages)

| Route | Purpose |
|-------|---------|
| `/` (index) | Global home: companies, recent trails, role strip, skills summary, learning funnel, do-not-repeat watchlist (if data) |
| `/company/<id>/` | Same grammar, filtered |
| `/trail/<task_id>/` | Plan line, role, wave, branch, status, timestamps, provenance, handoff sections (Built / Decisions / Do not repeat / Evidence), optional issue/PR links when parseable |
| `/role/<role>/` | Usage table + PMI + trails + packs |
| `/skill/<id>/` | Frontmatter, roles that inject, active/candidate, body read-only |
| `/learning/<slug>/` | Body + status + linked skills if `[ev:]` cites |
| `/conductor/` | Index of `wave-plans/conductor/` trails first-class |
| `/about/` | Sources, generation time, join rules, PMI formula glossary |

Click budget: trail or skill ≤ **3 clicks** from global home.

---

## 5. Metrics freeze

### 5.1 Role usage (always show *n*)

Per role (and per company when scoped):

| Metric | Definition |
|--------|------------|
| `n` | Distinct task_id |
| `n_done` / `n_fail` / `n_unknown` | From handoff status / agent_exit when present |
| `vendor_mix` | Counts of `provenance.vendor` (mechanical) |
| `critic_rate` | Phase 0: fraction of trails whose role name contains `critic`; Phase 1: pair by branch |
| `skill_coverage` | Packs on role beyond shared defaults `{evidence-first, untrusted-prior, git-ship}` (and `session-modes` only if mapped) |

Display: `93% · n=14` — never a bare percentage without *n*.

### 5.2 Playbook Maturity Index (PMI) — “seniority”

**Name:** Playbook Maturity Index (PMI)  
**Object:** the *role’s playbook system + recorded outcomes*, not a personified agent.

**Forbidden:** “Agent is Senior III” without formula; trophy UI; scores without *n*.

**Phase 0 bands (P0–P3), formula always expandable:**

Inspired by seat C levels + A/B transparency:

| Band | Meaning (operator language) | Phase 0 gate (all that apply; state caps if data missing) |
|------|----------------------------|------------------------------------------------------------|
| **P0** | Ad hoc | Default when `n < 3` or no specialized packs |
| **P1** | Instrumented | `n ≥ 3` and role has default packs injected |
| **P2** | Playbooked | `n_done ≥ 5` with success rate ≥ 70% **or** ≥ 1 dedicated pack beyond defaults |
| **P3** | Proven loop | Requires Phase 1 inputs (git pack history and/or learning→skill promotion evidence). **Phase 0 hard-cap: max display P2** with caption *“P3 needs version/promotion history (Phase 1)”* |

UI: show band + one-line reason + `<details>` with raw inputs and file paths.

### 5.3 Skill / learning status

| Skills | `active` (skills/\<id\>) · `candidate` (_candidates/) · `learning-only` (cited learning, no pack) |
| Learnings | `documented` (file exists) · `promoted` (skill bullet `[ev: …]` cites path) · `raw`/`superseded` only if frontmatter or clear convention exists; else default `documented` |

---

## 6. UX freeze (Phase 0)

1. **Evidence over adornment** — numbers link or expand to sources.  
2. **Two scopes, one grammar.**  
3. **Scan first** — tables and tight lists; not marketing hero bloat.  
4. **Honesty as chrome** — “unlinked”, “n=3”, “capped at P2” are first-class strings.  
5. **Static is a feature** — works from `file://` or local server; minimal/no required JS.  
6. **Empty states teach** — next command: dispatch, `make experience`, operator-guide.  
7. **A11y** — semantic headings, skip link, keyboard, status not color-only.  
8. **Visual:** system sans + mono for SHAs/paths; light paper / dark ink via `prefers-color-scheme`; one restrained accent; status green/red only with text labels.

**Do not** put AI vendor branding on the delivery surface of generated pages beyond mechanical provenance fields already in handoffs.

---

## 7. Phase 0 ship list (implement next)

| Item | Path / command |
|------|----------------|
| Generator | `scripts/experience-build.sh` and/or `scripts/experience_build.py` (one entrypoint called by make) |
| Templates / CSS | `templates/experience/` (or embedded in generator if tiny) |
| Output | `site/experience/**` — **gitignore** |
| Make | `experience` (build), `experience-open` (build + open), alias `desk` → `experience` |
| Tests | `tests/run-experience-tests.sh` fixture tree → joins, empty states, PMI cap, no secret paths; wire into `make test` |
| Operator doc | `docs/experience.md` (how to refresh, sources, join gaps) |
| Index proposals | Archive A/B/C files already on seat PRs; this SYNTHESIS is law |

**Phase 0 pages must exist:** global home, company, trail, role (+ PMI capped), skill, learning, conductor index, about.

**Phase 0 non-goals:** React app, GitHub API, promote button, Paperclip panel, git history PMI P3, checked-in HTML dump of full desk.

**Phase 1 (only after daily use):** git log skill versions, better critic pairing, `gh` PR/issue enrichment when authed, optional checked-in snapshot under `docs/experience/snapshot/` if sharing is needed.

---

## 8. Success criteria (Phase 0 done)

1. Operator runs `make experience` and understands fleet work in **&lt; 2 minutes**.  
2. Dual-scope Global / company works for at least **olympus** + shows unlinked trails honestly.  
3. Skills and learnings visible with promotion **status**, not write actions.  
4. Role usage + PMI present with formula disclosure; no vanity ranks.  
5. `make test` includes experience fixture tests.  
6. No agent transcripts or secrets in `site/experience/`.

---

## 9. Hybrid taken from seats (summary)

| From | Keep |
|------|------|
| A | Join confidence, company heuristics, `MaturityExplain`, gitignore site, Conductor first-class |
| B | `make experience`, entity map, RMS honesty (folded into PMI), health/evidence as optional Phase 1 panel |
| C | Almanac stance, full sitemap, PMI naming/levels, do-not-repeat watchlist, visual system, strict a11y |

---

## 10. Owner open (optional later)

- Exact PMI weights / N thresholds if P2 feels too easy or hard after real n  
- Whether ad-hoc projects eventually get `companies/*.md` manifests  
- Checked-in static snapshot for sharing outside the laptop  

---

## 11. Implementation order (suggested)

1. Generator scaffold + global home from handoffs + companies  
2. Trail detail + company filter  
3. Skills + learnings  
4. Roles + PMI (cap P2)  
5. Conductor index + about + tests + `make experience`  
6. Polish empty states and CSS  

**Next human gate:** merge this SYNTHESIS (+ archive proposals on main if not already), then implement Phase 0 against §7 only.
