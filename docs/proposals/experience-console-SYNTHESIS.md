# Experience Console — Owner SYNTHESIS (Fleet Desk Phase 0 freeze)

**Status:** **OWNER-APPROVED freeze** (re-eval 2026-07-29; implement Phase 0 against this document)  
**Date:** 2026-07-29  
**Sources:** `experience-console-BRIEF.md` + independent proposals A / B / C  
**PR seats:** [#40](https://github.com/Arlencho/dev-agents/pull/40) (A), [#41](https://github.com/Arlencho/dev-agents/pull/41) (B), [#42](https://github.com/Arlencho/dev-agents/pull/42) (C)  
**Rule:** Build from this freeze, not any single proposal wholesale.  
**Detail drawings:** Seat proposals remain the expanded gallery; **§4–§6 here are normative** (including wireframes).

---

## 0. Re-evaluation note (why this freeze still stands)

After re-reading the brief, all three seats, and the real handoff shape (`task_id`, `agent`, `wave`, `status`, `branch`, `provenance`):

| Verdict | Why |
|---------|-----|
| **Keep** hybrid | A+B name/dual-scope + C almanac/sitemap/PMI is the right product |
| **Keep** static Phase 0 | Matches R7, shippable in days, no daemon/SaaS |
| **Keep** honest PMI | Answers “seniority” without fake agent IQ |
| **Fix (this rev)** | Work/waves were under-specified as UI; no normative wireframes; PMI P2 was too easy (pack alone) |
| **Still reject** | SPA-first, promote buttons, GitHub replacement, transcript dumps |

**Owner approval of this document = go build Phase 0 against §7–§8 only.**

---

## 1. Decision

**Synthesize. Do not pick one proposal file.**

| Pillar | Source | What we take |
|--------|--------|----------------|
| Product framing + dual-scope grammar | **A + B** | Name **Fleet Desk**; dual-scope is one axis (Global / company), same cards both ways |
| Record / honesty stance + sitemap | **C** | Almanac spirit (evidence record, not live gauges); multi-page routes |
| Architecture | **All** | Read-only **static projection** of git artifacts; no daemon; no cloud; no skill auto-promote UI |
| Phase 0 toolchain | **B + C** (A compatible) | `make experience` (+ alias `make desk`); generator → `site/experience/` (**gitignored**); stdlib HTML/CSS |
| Work trails + joins | **A** heuristics + **B** entity map | Ordered join rules with `join_method` + confidence; ad-hoc projects as labels not fake companies |
| **Work + waves UI** | **A `/work` + C home trails + data `wave` field** | Trail is the atom; **wave is a first-class group** on Work index (global + company) |
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
- **Fake company rows** for unlinked ad-hoc repos  

---

## 2. Product name

| Field | Freeze |
|-------|--------|
| **Product name** | **Fleet Desk** |
| **Brief alias** | Experience Console (history only; do not invent a third name) |
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

### 3.2 Work model (law) — tasks and waves

```
Work trail  = one task (one handoff task_id): role + plan line + status + branch + …
Wave        = integer grouping field on trails (from JSONL `wave` / plan wave prefix)
Conductor   = special plan source under wave-plans/conductor/ (often wave 1 one-shots)
```

| Operator question | UI answer |
|-------------------|-----------|
| What did the fleet do overall? | Global **Work** + home recent trails |
| What did we do on Olympus? | Company scope → Work (joined trails only) |
| What was in wave 9? | Work index **group by wave** (or filter wave=9) |
| What happened on this task? | Trail detail page |
| Conductor pins? | `/conductor/` + trails flagged conductor |

**Trail is the atom. Wave is how we cluster atoms.** Do not invent a separate “wave object” store — group existing trails.

### 3.3 Runtime model

```
git artifacts  →  scripts/experience-build.sh  (or .py entry called by make)
               →  site/experience/**  (gitignored static HTML)
operator       →  make experience  |  make desk  (alias)
               →  open file:// or one-line local static server
```

- **No** new always-on process.  
- **No** API keys required for core views.  
- Optional local enrichment only: `logs/evidence-latest.txt`, vendor-auth JSON if present — never required.  
- **Never** ship secrets: do not ingest agent transcript logs; redact token-like strings if any raw field is shown.

### 3.4 Data sources (Phase 0)

| Entity | Sources |
|--------|---------|
| Companies | `companies/*.md` frontmatter (`name`, `status`, `repo`, `github_repo`, …) |
| Work trails | `wave-plans/*/handoffs/*.{jsonl,md}`; plans `wave-plans/**/*.plan`; conductor `wave-plans/conductor/` |
| Wave id | JSONL field `wave` (and/or plan line prefix); directory name `wave-plans/<n>/` as fallback |
| Skills | `skills/*/SKILL.md`, `skills/_candidates/`, `config/role-skills.yaml` |
| Project skills | `<product-repo>/skills/` when path from company `repo:` exists on operator disk |
| Learnings | fleet `learnings/*`; product discovery: `docs/qa/learning-*.md`, `learnings/*` under product root if present |
| Role map | `config/workers.yaml` provider_preferences (seat vendor, mechanical) |

### 3.5 Join rules (work trail → company)

Phase 0 **must** record `join_method` and may be imperfect:

1. Explicit map if present: `config/experience-joins.yaml`  
2. Match `github_repo` / repo slug in task text, branch, plan path, or handoff fields  
3. Match company `name` token in plan filename or task text  
4. Else: **unlinked** trail on Global only (project **label**, e.g. black-aces) — do **not** invent a company  

### 3.6 Promotion law (unchanged)

Visible pipeline only: learning / candidate / active skill.  
**Promotion remains PR-only** per skills-evolution SYNTHESIS. UI links to docs; never writes `skills/*/SKILL.md`.

---

## 4. Information architecture (Phase 0 pages)

### 4.1 Routes (normative)

| Route | Purpose |
|-------|---------|
| `/` | **Global home** — companies strip, recent trails, role strip, skills summary, learning funnel, do-not-repeat watchlist (if data) |
| `/company/<id>/` | **Company home** — same grammar, filtered |
| `/work/` | **Work index** (global or `?company=` / under company path) — **all trails**, default sort newest; **group-by-wave** toggle/sections |
| `/trail/<task_id>/` | **Trail detail** — plan line, role, **wave**, branch, status, timestamps, provenance, handoff sections, optional issue/PR links |
| `/role/<role>/` | Usage + PMI + trails + packs |
| `/skill/<id>/` | Frontmatter, inject roles, active/candidate, body read-only |
| `/learning/<slug>/` | Body + status + linked skills if `[ev:]` cites |
| `/conductor/` | Conductor plan/trail index |
| `/about/` | Sources, generation time, join rules, PMI glossary |

**Nav (always):** `Home · Work · Skills · Learn · Roles · Conductor · About` + **scope chip** `Global | <company>…`

Click budget: trail or skill ≤ **3 clicks** from global home.

### 4.2 Normative wireframes (Phase 0 look)

These are **build targets**, not optional inspiration.

#### Global home

```
┌─ Fleet Desk ──────────── ● Global | olympus | safeplace | rios… ─┐
│  generated <ts> · make experience · read-only                     │
│  Companies: [olympus n=…] [safeplace n=…] [aegis °placeholder]    │
│  ┌ Recent work ────────────────────────────── View all Work → ──┐ │
│  │ ✓ web-frontend  black-aces  wave 9  done   <time>            │ │
│  │ ✓ frontend-critic black-aces wave 9 done                     │ │
│  │ · docs-writer   dev-agents  conductor done                   │ │
│  └──────────────────────────────────────────────────────────────┘ │
│  Roles (top)     Skills              Learnings     Watchlist      │
│  web-frontend n  evidence-first v1   documented n  (if themes)    │
│  [Roles →]       [Library →]         [Learn →]                    │
└───────────────────────────────────────────────────────────────────┘
```

#### Company home (e.g. olympus)

```
┌─ Fleet Desk ──────────── Global | ● olympus | safeplace | … ─────┐
│  olympus · active · github_repo link · one-line phase note         │
│  Work trails (joined only) · Skills (global + project overrides)   │
│  empty: "No handoffs joined to olympus yet — join_method gaps OK"  │
│  [Open Work for olympus →]                                         │
└────────────────────────────────────────────────────────────────────┘
```

#### Work index (global or company) — tasks + waves

```
┌─ Work ────────────────── scope: Global (or olympus) ──────────────┐
│  Filter: role ▾  status ▾  wave ▾     Group: (•) by wave  ( ) flat │
│  ── Wave 11 ─────────────────────────────────────────────────────  │
│  ✓ web-frontend  …  done                                           │
│  ── Wave 9 ──────────────────────────────────────────────────────  │
│  ✓ web-frontend  black-aces  done                                  │
│  ✓ frontend-critic black-aces done                                 │
│  ── Unlinked / no wave ──────────────────────────────────────────  │
│  · docs-writer  dev-agents  conductor                              │
│  click row → /trail/<task_id>/                                     │
└────────────────────────────────────────────────────────────────────┘
```

#### Trail detail

```
┌─ Trail <task_id> ────────────── ● done ───────────────────────────┐
│  ← Work · scope · wave N                                           │
│  role · vendor (provenance) · branch · base→head SHA               │
│  files / exit / ts · issue/PR links if parseable                   │
│  PLAN LINE …                                                       │
│  Built / Decisions / Do not repeat / Evidence (from .md)           │
│  ▾ raw JSONL (audit, redacted)                                     │
└────────────────────────────────────────────────────────────────────┘
```

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
| `skill_coverage` | Packs on role beyond shared defaults `{evidence-first, untrusted-prior, git-ship}` |

Display: `93% · n=14` — never a bare percentage without *n*.

### 5.2 Playbook Maturity Index (PMI) — “seniority”

**Name:** Playbook Maturity Index (PMI)  
**Object:** the *role’s playbook system + recorded outcomes*, not a personified agent.

**Forbidden:** “Agent is Senior III” without formula; trophy UI; scores without *n*.

| Band | Operator language | Phase 0 gate |
|------|-------------------|--------------|
| **P0** | Ad hoc | Default: `n < 3` |
| **P1** | Instrumented | `n ≥ 3` (defaults injected for everyone do **not** alone raise band) |
| **P2** | Playbooked | **`n_done ≥ 5` AND success_rate ≥ 70%** (among done+fail with known exit/status). Dedicated pack beyond defaults is a **boost label** (“specialized pack”) but **does not** grant P2 without outcome bar. |
| **P3** | Proven loop | Phase 1 only (git pack history and/or learning→skill promotion). **Phase 0 hard-cap: display max P2** with caption *“P3 needs version/promotion history (Phase 1)”* |

UI: band + one-line reason + `<details>` with raw inputs and file paths.

### 5.3 Skill / learning status

| Skills | `active` · `candidate` · `learning-only` |
| Learnings | `documented` · `promoted` (skill `[ev:]` cites path) · `raw`/`superseded` only with clear convention; else `documented` |

---

## 6. UX freeze (Phase 0)

1. **Evidence over adornment** — numbers expand to sources.  
2. **Two scopes, one grammar.**  
3. **Scan first** — tables and tight lists; Work is table-first.  
4. **Honesty as chrome** — “unlinked”, “n=3”, “capped at P2” first-class.  
5. **Static is a feature** — `file://` or local server; minimal/no required JS (`<details>` OK).  
6. **Empty states teach** — next command: dispatch, `make experience`.  
7. **A11y** — semantic headings, skip link, keyboard, status not color-only.  
8. **Visual:** system sans + mono for SHAs/paths; `prefers-color-scheme`; one restrained accent; green/red only with text labels.  
9. **Wave always visible** on trail rows and trail detail (not buried only in JSONL).

**Do not** put AI vendor branding on the delivery surface beyond mechanical provenance already in handoffs.

---

## 7. Phase 0 ship list (implement next)

| Item | Path / command |
|------|----------------|
| Generator | `scripts/experience-build.sh` and/or Python entry called by make |
| Templates / CSS | `templates/experience/` (or embedded if tiny) |
| Output | `site/experience/**` — **gitignore** |
| Make | `experience`, `experience-open`, alias `desk` → `experience` |
| Tests | `tests/run-experience-tests.sh` → joins, empty states, **wave grouping**, PMI cap, no secret paths; `make test` |
| Operator doc | `docs/experience.md` |

**Phase 0 pages must exist:** home, company, **work (group-by-wave)**, trail, role (+ PMI), skill, learning, conductor, about — matching §4.2 wireframes.

**Phase 0 non-goals:** React app, GitHub API, promote button, Paperclip panel, PMI P3, checked-in full site dump.

**Phase 1:** git log skill versions, critic pairing by branch, `gh` PR/issue enrichment when authed, optional snapshot under `docs/experience/snapshot/`.

---

## 8. Success criteria (Phase 0 done)

1. `make experience` → understand fleet work in **&lt; 2 minutes**.  
2. Global **and** company Work show tasks; **group-by-wave** works when `wave` is present.  
3. Unlinked trails appear on Global honestly (not forced into a fake company).  
4. Skills/learnings show promotion **status**, not write actions.  
5. Role usage + PMI with formula disclosure; P2 requires outcomes; no vanity ranks.  
6. `make test` includes experience fixtures.  
7. No agent transcripts or secrets in `site/experience/`.  
8. UI matches §4.2 structure (not necessarily pixel-identical ASCII).

---

## 9. Hybrid taken from seats (summary)

| From | Keep |
|------|------|
| A | Join confidence, `/work`, MaturityExplain, gitignore site, Conductor first-class |
| B | `make experience`, entity map, optional Health later, RMS honesty → PMI |
| C | Almanac stance, sitemap, PMI name, watchlist, visual/a11y, richest home wireframe |

---

## 10. Owner open (optional later)

- PMI thresholds after real *n* (P2 may feel hard with sparse handoffs — adjust with evidence, not vanity)  
- Ad-hoc projects → real `companies/*.md` when they become products  
- Checked-in static snapshot for sharing  

---

## 11. Implementation order (suggested)

1. Generator + parse handoffs (task_id, agent, wave, status, branch, provenance)  
2. Global home + company filter  
3. **Work index with group-by-wave** + trail detail  
4. Skills + learnings  
5. Roles + PMI (cap P2, outcome-gated)  
6. Conductor + about + tests + CSS polish  

---

## 12. Approval

| Field | Value |
|-------|--------|
| **Re-eval** | 2026-07-29 — hybrid confirmed; Work/waves + wireframes + PMI P2 tightened |
| **Owner** | Approved to implement Phase 0 (per chat approval after re-eval) |
| **Build law** | This file only |

**Next step:** merge SYNTHESIS PR if not already on main, then implement Phase 0 against §7–§8.
