# Fleet Desk — Experience Console design proposal (seat B)

**Status:** Competing draft (not law). Prefer owner SYNTHESIS after three seats.  
**Seat:** B (independent; did not read seats A/C proposals)  
**Date:** 2026-07-29  
**Brief:** [`experience-console-BRIEF.md`](experience-console-BRIEF.md)  
**Obeys freezes:** [`skills-evolution-SYNTHESIS.md`](skills-evolution-SYNTHESIS.md), [`session-modes-SYNTHESIS.md`](session-modes-SYNTHESIS.md), Ground Truth / Evidence in [`../operator-guide.md`](../operator-guide.md)

---

## 1. Product name + pitch

| Field | Decision |
|-------|----------|
| **Product name** | **Fleet Desk** |
| **Working name (brief)** | Experience Console (alias only in docs until SYNTHESIS) |
| **One-sentence pitch** | A dual-scope operator desk that projects what the fleet *did*, *learned*, and *knows how to do* from git-backed artifacts - without replacing GitHub tickets or inventing agent IQ. |

**Why not keep "Experience Console"?** "Console" invites ops-dashboard clutter (raw JSON, log tails). "Desk" signals a daily working surface for one founder/engineer: glance, drill, act (open PR / promote skill via existing PR path). "Fleet" anchors multi-seat reality.

**What it is not:** GitHub Projects, Paperclip UI, live agent chat, or a second source of truth for skills.

---

## 2. User journeys

Primary persona: **solo operator** (Arlen) between waves. Secondary: future collaborator (read-only same data). Phase 0 assumes single operator.

### J1 - Global home (< 2 minutes)

1. Open Fleet Desk (`make experience` → browser).  
2. See: company tiles (status + last activity), **Work trails** (last N tasks), **Role usage** strip, **Skill library** chips, **Learnings** count by status.  
3. Click a trail → handoff detail (≤ 2 clicks from home).  
4. Click a skill chip → pack page (version, roles, promote path).  

Empty state: "No handoffs under `wave-plans/*/handoffs/` yet. Run `./scripts/dispatch.sh …` or open the operator guide."

### J2 - Company / project page

1. Scope switcher: **Global** | Olympus | Safeplace | Rios Operator | placeholders greyed.  
2. Same card types as home, filtered: trails whose plan/repo joins this company; project skills if `<product>/skills/` exists beside `companies/*.md` `repo:`; project learnings under discovery rules (§4.3).  
3. Company header from frontmatter: name, status, `github_repo` link when present, phase blurb (first non-empty Active phase row if present - truncated).

### J3 - Work trail detail

1. From home or company feed.  
2. One screen: plan line (if resolvable), role, wave, branch, status, timestamps, provenance vendor (mechanical), files_touched / exit code, link to `.md` handoff body sections (Built / Decisions / Do not repeat / Evidence) **sanitized** (no log paths that might embed secrets beyond already-gitignored local notes).  
3. Optional: parse `#123` / `owner/repo#n` / `https://github.com/...` from task text or md → external links only.  
4. Conductor badge if plan path is under `wave-plans/conductor/`.

### J4 - Skill pack page

1. List → pack: frontmatter `id`, `version`, `scope`, `summary`, body checklist length.  
2. **Injected by roles** from `config/role-skills.yaml`.  
3. **Promotion status:** active | candidate (`skills/_candidates/`) | learning-only (linked learning ids if cited).  
4. CTA: "Open promote PR path" → docs link to skills README + SYNTHESIS (no write UI).  
5. Project scope: show override banner when product repo has same `id`.

### J5 - Learning page

1. Learning list (global `learnings/*.md` + discovered product paths).  
2. Status: raw / documented / promoted / superseded (heuristic + optional frontmatter).  
3. Link to related skill if filename or body cites a pack id.  
4. Never "Promote" button that writes skills - only "Draft skill PR" checklist (human).

### J6 - Role usage & maturity

1. Role table: n tasks, success/fail/unknown, vendor mix, critic involvement, skill coverage, **Maturity band** with expandable formula.  
2. Click role → filtered work trails + attached packs.  

---

## 3. Information architecture + component inventory

### 3.1 Scope model (dual by design)

```
┌─────────────────────────────────────────────────────────────┐
│  Fleet Desk                         [Global ▾]  [Search]   │
├──────────┬──────────────────────────────────────────────────┤
│ Nav      │  Main                                            │
│ · Home   │                                                  │
│ · Work   │  (content depends on scope)                      │
│ · Skills │                                                  │
│ · Learn  │                                                  │
│ · Roles  │                                                  │
│ · Plans  │  secondary: Conductor / Wave plans index         │
│ · Health │  optional panel: evidence + vendor-auth summary  │
└──────────┴──────────────────────────────────────────────────┘
```

**Scope switcher** is a first-class axis (not a filter chip buried under Work). Changing scope refilters **all** primary views. Global = union + rollup. Project = one `companies/<id>.md` + discoverable product artifacts.

| Nav item | Global | Project |
|----------|--------|---------|
| Home | All companies + fleet rollups | Company header + project rollups |
| Work | All trails | Trails joined to company |
| Skills | `skills/*` + candidates | Global packs + project overrides if scanned |
| Learn | `learnings/` | Fleet learnings tagged/related + product discovery |
| Roles | All roles from handoffs ∪ role-skills.yaml | Same metrics filtered to company trails |
| Plans | `wave-plans/**/*.plan` + conductor/ | Plans mentioning company repo/name when joinable |
| Health | CLI projections (optional) | Same (fleet-level; company filter N/A) |

### 3.2 Wireframes (ASCII)

#### Home (Global)

```
┌─ Fleet Desk · Global ─────────────────────────────────────┐
│  Last scan: 2026-07-29 12:04 · make experience            │
│                                                           │
│  Companies                                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌ · · · · · · · ┐│
│  │ Olympus  │ │ Safeplace│ │ Rios Op  │ │ Aegis (stub) ││
│  │ active   │ │ active   │ │ code ok  │ │ placeholder  ││
│  │ 12 trails│ │ 0 trails │ │ 0 trails │ │              ││
│  └──────────┘ └──────────┘ └──────────┘ └──────────────┘│
│                                                           │
│  Recent work trails                          [View all →] │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ done  web-frontend  feat/ab-T05-jsonld-org  kimi    │  │
│  │       wave 9 · black-aces · 2m ago                  │  │
│  │ done  frontend-critic feat/ab-T09-theme-color       │  │
│  │       wave 9 · black-aces · …                       │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
│  Roles (7d / all)          Skills              Learnings  │
│  web-frontend ████ 42      evidence-first v1   documented 3│
│  frontend-crit ███ 38      git-ship v2         raw 0      │
│  plan-critic   █ 4         untrusted-prior v1  promoted 0 │
│  [Maturity →]              +4 packs            candidates 0│
└───────────────────────────────────────────────────────────┘
```

#### Work trail detail

```
┌─ Trail · 9-web-frontend-feat-ab-T05-jsonld-org ───────────┐
│  Status: done · agent_exit: 0 · vendor: kimi (mechanical) │
│  Branch: feat/ab-T05-jsonld-org · base..head SHAs         │
│  Plan: black-aces / wave 9 · [conductor?] no              │
│  Files: index.html · +9 −0                                │
│  ───────────────────────────────────────────────────────  │
│  Built (agent intent · untrusted)                         │
│   · Added Organization JSON-LD …                          │
│  Do not repeat                                            │
│   · Do not add additional Organization JSON-LD blocks     │
│  Evidence (quoted)                                        │
│   · npm run qa → console errors: none                     │
│  External: (none parsed)                                  │
│  Open: handoff.md path (local) · raw jsonl path           │
└───────────────────────────────────────────────────────────┘
```

#### Skills library

```
┌─ Skills · Global ─────────────────────────────────────────┐
│  Filter: [all|active|candidate|role:web-frontend]         │
│  ┌ id ──────────────┬ ver ┬ roles ──────────┬ status ───┐ │
│  │ evidence-first   │ 1   │ most producers  │ active    │ │
│  │ git-ship         │ 2   │ producers+crit  │ active    │ │
│  │ session-modes    │ 1   │ orchestrator    │ active    │ │
│  │ (empty candidates row)                     candidate │ │
│  └──────────────────┴─────┴─────────────────┴───────────┘ │
│  Banner: Promotion is PR-only. Global = human merge.      │
└───────────────────────────────────────────────────────────┘
```

#### Role maturity

```
┌─ Role · web-frontend ─────────────────────────────────────┐
│  Band: Practiced · score 62/100 · n=42 · explain ▾        │
│  Formula inputs (all linked to evidence):                 │
│   coverage 18 · volume 16 · success 14 · critic 8 ·       │
│   evolution 6 · rework −0                                 │
│  Packs: evidence-first, untrusted-prior, handoff-intent,  │
│         git-ship (max_packs=4)                            │
│  Vendor mix: kimi 70% · claude 25% · unknown 5%           │
│  Critic pair: frontend-critic on shared branches (rate …) │
│  Recent trails: …                                         │
└───────────────────────────────────────────────────────────┘
```

### 3.3 Component inventory (build units)

| Component | Props / data | Phase |
|-----------|--------------|-------|
| `AppShell` | scope, nav, theme | 0 |
| `ScopeSwitcher` | companies[] from frontmatter | 0 |
| `CompanyTile` | name, status, trail_count, last_ts | 0 |
| `WorkTrailList` | trails[], filters | 0 |
| `WorkTrailCard` | status, role, branch, vendor, wave, company? | 0 |
| `WorkTrailDetail` | jsonl + md sections | 0 |
| `SkillTable` / `SkillDetail` | packs, role map, candidates | 0 |
| `LearningList` / `LearningDetail` | files + status | 0 |
| `RoleUsageTable` | aggregates | 0 |
| `MaturityPanel` | score breakdown + sources | 0 |
| `PlanIndex` | plan files, conductor flag | 0 |
| `HealthStrip` | last evidence snapshot summary (optional file) | 0 optional |
| `EmptyState` | teaching CTA | 0 |
| `SearchBox` | client filter over projection JSON | 0 SHOULD |
| `ExternalLinkChip` | issue/PR URL | 1 |
| `SkillTimeline` | git log of SKILL.md versions | 1 |
| `DoNotRepeatThemes` | clustered strings | 1 |
| Write actions / auto-promote | - | **never** |

---

## 4. Data model / joins (existing artifacts only)

### 4.1 Projection principle

Fleet Desk is a **read-only projection**. A generator script walks known paths, emits a single JSON (and static HTML) under a gitignored or optional committed site dir. No always-on daemon. No cloud. Secrets: never ingest full agent transcripts into the public static tree; redact lines matching token-like patterns if any log snippet is included (Phase 0 default: **do not embed logs/**).

### 4.2 Entity map

```
Company ──< WorkTrail >── RoleSeat
    │           │
    │           ├── Plan (wave-plans/**)
    │           ├── HandoffJSONL + HandoffMD
    │           └── optional IssueRef / PRRef (parsed)
    │
    ├── ProjectSkill?  (product repo skills/<id>)
    └── ProjectLearning?

SkillPack ── injected_by ── RoleSeat
Learning ──? promotes_to ── SkillPack | Candidate
```

### 4.3 Source → field joins

| Entity | Source | Join keys / rules |
|--------|--------|-------------------|
| **Company** | `companies/*.md` YAML frontmatter | `name`, `status`, `repo`, `github_repo` when present |
| **WorkTrail** | last object per `wave-plans/*/handoffs/*.jsonl` (same as `wave-report.sh`: last line wins per `task_id`) | `task_id`, `wave`, `agent`, `branch`, `status`, `ts`, `provenance`, `orchestrator_fields` |
| **Handoff intent** | sibling `*.md` | basename match; sections Built / Decisions / Do not repeat / Evidence / Next hint |
| **Plan** | `wave-plans/**/*.{plan,md}` excluding pure docs | path; parse plan lines per `docs/plan-file-format.md` when `.plan` |
| **Conductor** | `wave-plans/conductor/*.plan` | flag `session_mode=conductor` on trails whose plan_path is under conductor/ |
| **Company ↔ trail** | heuristic | (1) plan path or task text contains company `name` or `github_repo` basename; (2) optional `companies/*.md` `repo:` basename appears in plan header comments; (3) if unjoined → company=`unknown` / `_fleet` (show on Global only) |
| **SkillPack** | `skills/<id>/SKILL.md` frontmatter | `id`, `version`, `scope`, `summary`, `max_lines` |
| **Candidates** | `skills/_candidates/**` | status=`candidate`; never "active inject" |
| **Role → packs** | `config/role-skills.yaml` | space-separated lists; `defaults.max_packs` |
| **Project skill override** | if `companies.repo` is relative path `../foo` and `../foo/skills/<id>/SKILL.md` exists | mark `override:true` for that company scope |
| **Learning** | `learnings/*.md` (skip `.gitkeep`); product: only **known public patterns** - `<product>/docs/qa/learning-*.md`, `<product>/learnings/*.md` when product path is a local relative `repo:` that exists | no inventing private paths |
| **Learning status** | frontmatter `status:` if present; else heuristics: body contains "promoted" + skill id → promoted; filename under learnings + substantial body → documented; empty stub → raw; title "superseded" → superseded | document heuristic in UI footer |
| **Evidence rollup** | optional read of `logs/evidence-latest.txt` / `logs/evidence.csv` if present after `make evidence` | **local only**; never require for core views |
| **Provider health** | do not scrape auth files; optional show "run `make vendor-auth`" CTA | obey evidence-first / path hygiene |

### 4.4 Trust split (UI must surface)

| Layer | Trust | UI treatment |
|-------|-------|--------------|
| `orchestrator_fields`, exit code, SHAs, files_touched | Mechanical | Default bold facts |
| `provenance.vendor` | Mechanical (orchestrator-written) | Show as "seat vendor" |
| Agent md Built / Decisions / Do not repeat | **Untrusted claims** | Badge: "Agent intent - verify before reuse" |
| Skill packs in git | Human-merged law (after PR) | Authoritative playbooks |
| Prior handoffs in session context | Advisory | Not re-ingested as truth in Desk |

Aligns with multi-vendor transparency freeze and `untrusted-prior`.

### 4.5 What we deliberately do not join in Phase 0

- Live GitHub API issue state  
- Paperclip heartbeat / agent costs  
- Full `~/dev/agent-logs` transcripts  
- Vector / embedding search  

---

## 5. Metrics: role usage + honest skill maturity

### 5.1 Role usage (required)

Per role `agent` over selected window (default: all time; toggle 7d/30d when `ts` present):

| Metric | Input | Definition |
|--------|-------|------------|
| **n** | handoff jsonl | count of task_ids |
| **success** | `status` ∈ {done, success} **and** (`agent_exit` missing or 0) | else fail if exit≠0 or status fail; else unknown |
| **vendor mix** | `provenance.vendor` | % histogram; unknown bucket |
| **critic involvement** | same-branch trails where a `*-critic` role appears in a later/same plan wave on that branch | rate = critic_tasks / producer_tasks for paired producers; N/A for pure critics |
| **skill coverage** | role-skills.yaml | dedicated packs beyond `default` list; count + list |
| **rework signal** | ab-metrics `rework_loops` if task_id maps; else count of do_not_repeat bullets co-occurring with same role | soft signal only |

### 5.2 Maturity / "seniority" model (explainable, no vanity ranks)

**Reject:** "Agent is Senior III", XP bars, anthropomorphic level-ups without formula.

**Adopt: Role Maturity Score (RMS)** - a transparent 0-100 band for the *playbook + outcome system around a role*, not a personality.

```
RMS = clamp(0, 100,
    0.20 * Coverage
  + 0.20 * Volume
  + 0.25 * Success
  + 0.15 * CriticTightness
  + 0.10 * Evolution
  + 0.10 * LearningLoop
)
```

| Component | Range | Formula (Phase 0) |
|-----------|-------|-------------------|
| **Coverage** | 0-100 | `100 * min(1, packs_for_role / max(1, defaults.max_packs))` using role-skills.yaml |
| **Volume** | 0-100 | `100 * min(1, n / 20)` - 20 tasks = full credit (configurable constant `N_vol=20`) |
| **Success** | 0-100 | `100 * (success / max(1, success+fail))`; if all unknown → **null component**, redistribute weight proportionally among known components |
| **CriticTightness** | 0-100 | For producers: `100 * critic_pair_rate` when pair detectable; critics: use `100` if they emit verdicts (presence of VERDICT in md) else 50; if n<3 → half weight |
| **Evolution** | 0-100 | Phase 0: `20 * (max pack version among role packs - 1)` capped 100 (version bumps). Phase 1+: git history of SKILL.md for those packs |
| **LearningLoop** | 0-100 | Phase 0: `min(100, 25 * count(learnings citing role or pack))`. Phase 1+: promoted learnings rate |

**Bands (labels only - always show score + expand formula):**

| Score | Band | Meaning |
|-------|------|---------|
| null / n=0 | **Unobserved** | No trails |
| 0-24 | **Nascent** | Sparse use or weak coverage |
| 25-49 | **Forming** | Some volume; packs may be default-only |
| 50-74 | **Practiced** | Regular use + packs + measurable success |
| 75-100 | **Hardened** | High volume, strong success, critic presence, versioned packs |

**UI law:** every band is one click from raw counts. Tooltip: "Not agent IQ. System maturity for this role's playbooks and outcomes."

### 5.3 Fleet-level skill evolution panel

- Pack count by status (active / candidate)  
- Integer versions (git-ship v2 already proves multi-version exists)  
- Roles with **only** `default` packs vs specialized  
- Learning → skill rate: `promoted / max(1, documented+promoted)` (honest even if 0)  
- Kill-criterion awareness (skills SYNTHESIS): Desk **displays** rework themes; it does not auto-kill packs  

### 5.4 Forbidden metrics

- Fake percentiles vs "industry"  
- Vendor league tables as moral score (vendor mix is operational, not ranking intelligence)  
- Auto-inferred "seniority title" strings without RMS  

---

## 6. UX principles + visual system

### 6.1 Principles

1. **Hierarchy over dump** - home answers five brief questions; detail is progressive.  
2. **≤ 3 clicks** to a handoff body or skill pack.  
3. **Mechanical facts first**, intent second, logs never by default.  
4. **Teach empty** - every empty list names the command that fills it.  
5. **Scope is a place**, not a filter tag.  
6. **Honest uncertainty** - show `unknown` status rather than paint green.  
7. **Coexist with CLI** - Desk projects; `make evidence` / `make scorecard` remain generators of optional Health inputs.  
8. **Session modes awareness** - Conductor trails and Wave plans are first-class labels, not a separate product.  

### 6.2 Visual system

| Token | Proposal |
|-------|----------|
| **Theme** | System preference default; explicit dark/light toggle stored in `localStorage` only |
| **Density** | Compact (operator laptop). 12-col grid; cards with 12-16px padding |
| **Type** | UI: Inter or system-ui. Mono: ui-monospace for task_id, branch, SHAs |
| **Color** | Neutrals + one accent (teal/cyan). Status: green done, amber unknown, red fail, blue critic, purple conductor |
| **Radius** | 8px cards; 4px chips |
| **Icons** | Inline SVG, sparse - status dots over illustration |
| **Motion** | None required Phase 0 (prefers-reduced-motion respected if any) |
| **A11y** | Semantic `h1-h3`, skip link, focus rings, contrast ≥ WCAG AA, tables for data not div-soup, keyboard nav for scope switcher |

### 6.3 Craft bar (what "beautiful enough daily" means)

- One clear **primary column** of work trails; side columns for skills/learnings never compete for the same width.  
- Sticky scope + search.  
- Monospace metadata row under each card (wave · branch · vendor).  
- Maturity panel uses a **horizontal stacked bar of formula components**, not a trophy.  
- Print/export: optional single static HTML that still works offline.  

---

## 7. Phase 0 ship list (days, not months)

### 7.1 Goal

Usable daily overview from **existing** git-tracked data with imperfect joins labeled honestly.

### 7.2 Concrete deliverables

| # | Artifact | Notes |
|---|----------|-------|
| 1 | `scripts/experience-project.sh` | Walk companies, skills, role-skills, learnings, handoffs; emit `logs/experience/projection.json` (gitignored under logs/) |
| 2 | `scripts/experience-render.sh` | JSON → static site in `logs/experience/site/` (or `docs/experience/site/` if owner later chooses to commit snapshots) |
| 3 | `make experience` | `experience-project` + `experience-render` + print `file://` or `python -m http.server` hint |
| 4 | Static pages | `index.html` (home), `company/<name>.html`, `work/<task_id>.html`, `skills/index.html`, `skills/<id>.html`, `learnings/…`, `roles/index.html`, `roles/<role>.html`, `plans/index.html` |
| 5 | Shared CSS/JS | One `assets/desk.css`, tiny `assets/desk.js` (filter/search, theme) - no SPA framework required |
| 6 | Redaction helper | Strip obvious secrets if any field copies env-like strings; never copy `logs/**/*.log` bodies into site |
| 7 | Docs | Short section in `docs/operator-guide.md` + link from README; proposal remains this file until SYNTHESIS |
| 8 | Tests | Fixture mini tree under `tests/fixtures/experience/` + assert projection counts (roles, packs, companies) |

### 7.3 Phase 0 non-goals

- React/Next app in this repo  
- GitHub OAuth  
- Write paths / skill edit UI  
- Paperclip panel  
- Perfect company↔trail join for every historical black-aces path (label `_unscoped` and fix mapping table later)

### 7.4 Optional Phase 0 polish (if time)

- Include `make evidence --no-write` summary block when handoffs exist  
- Client-side full-text filter over projection  

### 7.5 Phase 1 (only after daily use)

- Richer PR/issue link resolution via `gh` when available (still optional)  
- Skill version timeline from `git log -p -- skills/*/SKILL.md`  
- Do-not-repeat theme clustering  
- Company mapping file `config/experience-company-map.yaml` for plan→company overrides  
- Project skill scan for all active companies with local repos  

### 7.6 Phase 2+ (only if loved)

- Multi-user read host  
- Notifications when candidate skills appear  
- Optional Paperclip cost panel  
- Still: **no auto-promote**, **no daemon required for core**  

### 7.7 Fit with freezes

| Freeze | Desk behavior |
|--------|----------------|
| Skills promotion PR-only | Read-only skills; link to promote process |
| Session modes contracts | Conductor plans labeled; no fake "Session Auto = dispatch --auto" |
| Ground Truth | Prefer orchestrator_fields; mark agent md untrusted |
| Delivery face | Generator commits (if any) follow git-ship; no vendor branding on PRs |
| No experience auto-write skills | Hard law in generator (write only under logs/experience) |

---

## 8. Risks, non-goals, open questions

### 8.1 Risks

| Risk | Mitigation |
|------|------------|
| Company↔trail join weak for historical waves | Explicit `_unscoped` bucket; Phase 1 map file |
| Operators treat agent md as law | Untrusted badge + untrusted-prior alignment |
| Static site accidentally commits secrets | Default output under `logs/`; redact; no transcript ingest |
| Maturity score gamed or misread | Expand formula always; band labels careful; n displayed |
| Scope creep into GitHub replacement | Non-goal list in UI footer |
| Duplicate of `make evidence` tables | Desk is navigable product UX; evidence remains CLI aggregate |

### 8.2 Non-goals (restate)

- Replace GitHub Issues/Projects  
- Auto-promote skills  
- Invent metrics without inputs  
- Multi-tenant SaaS  
- Olympus product features  
- Always-on daemon / vector store  
- Paperclip as core dependency  

### 8.3 Open questions for owner SYNTHESIS

1. **Commit static snapshots?** Default no (`logs/`). Some operators may want `docs/experience/` checked in for shareable offline - opt-in flag?  
2. **Black-aces / non-company repos:** introduce a free-form "workspace" entity, or only companies/*.md + `_unscoped`?  
3. **RMS constants** (`N_vol=20`, weights): freeze in `config/experience-metrics.yaml` or hardcode Phase 0?  
4. **Multi-seat proposal naming:** keep Fleet Desk or merge name from other seats?  
5. **Health strip:** link-out to CLI only vs embed last evidence file?  

---

## 9. Why this is better than `make evidence` + README

| Need | CLI evidence / README | Fleet Desk |
|------|----------------------|------------|
| What companies exist? | Read `companies/*` manually | Company tiles + status |
| What did the fleet do for me? | Grep handoffs | Work trail feed, 2-click detail |
| Skills + who gets them? | Open yaml + skills tree | Library + role inject map |
| Learnings vs skills? | Separate folders, no status UI | Status model + promote path (read-only) |
| Role seniority story | None / ad hoc | Transparent RMS bands |
| Dual global/project | Mental model only | Scope switcher axis |
| Daily beauty / hierarchy | Terminal tables | Product IA, empty states, a11y |
| Session conductor trails | Easy to miss folder | First-class badge + plans index |

`make evidence` stays the **aggregate quality scorecard**. Fleet Desk is the **spatial memory** of work, knowledge, and maturity - the layer the brief asks for.

---

## 10. Decision summary (for SYNTHESIS)

1. **Name:** Fleet Desk (Experience Console alias).  
2. **Architecture:** Offline projection + static site; `make experience`; no daemon.  
3. **Dual scope:** Global / company switcher refilters all primary nav.  
4. **Trust:** Mechanical handoff fields primary; agent md labeled untrusted.  
5. **Maturity:** Role Maturity Score with published formula; no vanity levels.  
6. **Skills/learnings:** Read-only; promotion remains PR-only per skills freeze.  
7. **Phase 0:** Projector + static multi-page site + tests + operator-guide link.  
8. **Beauty:** Compact system-theme desk, clear hierarchy, ≤3 clicks to artifact.  

---

*Seat B proposal only. Owner freezes via SYNTHESIS; implementers must not treat this file as law over the brief + freezes.*
