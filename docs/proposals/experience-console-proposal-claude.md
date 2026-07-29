# Proposal: Fleet Desk (Experience Console) - Seat A

**Author:** Seat A (this document)  
**Date:** 2026-07-29  
**Status:** Competing draft - not product law until owner SYNTHESIS  
**Brief:** [experience-console-BRIEF.md](experience-console-BRIEF.md)  
**Obeys freezes:** [skills-evolution-SYNTHESIS.md](skills-evolution-SYNTHESIS.md), [session-modes-SYNTHESIS.md](session-modes-SYNTHESIS.md)  
**Scope:** Design only. No product UI code in this wave.

---

## 1. Product name + pitch

| | |
|--|--|
| **Working name (brief)** | Experience Console |
| **Proposed product name** | **Fleet Desk** |
| **One-sentence pitch** | A local, read-only desk that projects git-tracked fleet artifacts so an engineer can see what the multi-seat fleet worked on, which playbooks it carries, and how those playbooks matured - globally and per company. |

**Why rename:** "Console" implies a control surface that mutates systems. Phase 0–1 is a **projection and navigation** surface. "Desk" matches the operator mental model (sit down, scan work, open a trail, open a skill) without promising buttons that promote skills or dispatch waves.

**Tagline for empty/home chrome:** *What the fleet did, learned, and now knows how to do.*

---

## 2. User journeys

Primary operator: single founder/engineer (Arlen). Secondary: any engineer joining a product who needs fleet context without reading raw JSONL.

### J1 - Global home (≤ 2 minutes)

1. Run `make desk` (or open last-generated static site).
2. Land on **Global home**: company strip, recent work trails, role usage strip, skill library summary, learning funnel.
3. Scan "what moved since last visit" via reverse-chronology trails + timestamps from handoff JSONL.
4. Click a trail → trail detail (handoff intent + mechanical provenance) in ≤ 2 clicks from home.
5. Click a skill pack → pack page (version, roles, promote status) in ≤ 2 clicks.

### J2 - Company / repo focus

1. From global home, pick a company chip (from `companies/*.md` frontmatter: `name`, `status`, `github_repo` / `repo`).
2. Company page reuses the same card grammar: work trails filtered by join rules (§4), project skills if product repo is on disk, project learnings if discoverable, role usage restricted to that company's waves.
3. Empty active company (e.g. `aegis`, `wearforrun` placeholders) shows honest empty state: "No wave handoffs joined yet - link a plan or run dispatch."

### J3 - "What did we do with the tool on X?"

1. Open company or global **Work** view.
2. Filter by role / status / wave (SHOULD).
3. Open a **work trail**: plan line → seat → handoff status → branch / SHAs → optional PR/issue links when parseable.
4. Expand **Do not repeat** and **Evidence** from the `.md` handoff without opening a terminal.

### J4 - Skills acquired (global + project)

1. Open **Skills** library.
2. Dual-scope toggle or sections: Global packs vs Project overrides.
3. Each pack shows: `id`, integer `version`, `summary`, roles from `config/role-skills.yaml`, status (`active` | `candidate` | `learning-only`).
4. Promotion is **visible as status + deep-link to open a PR workflow**, never an in-app promote button that writes `skills/`.

### J5 - Learnings pipeline

1. Open **Learnings**.
2. See index of fleet `learnings/*` with status: raw / documented / promoted / superseded.
3. Click learning → body preview + "linked skill?" if a pack cites it via `[ev: learnings/…]`.
4. Candidate packs under `skills/_candidates/` appear as promotion queue, not as injected skills.

### J6 - Role usage & maturity (honest)

1. Open **Roles**.
2. Table: tasks (n), success/fail/unknown, primary vendor mix, critic involvement rate, skill coverage, maturity band (§5).
3. Click role → trails for that role + packs injected for that role + maturity formula with numbers filled in.

### J7 - Conductor path (session modes)

1. From Work, filter source = `conductor` (plans under `wave-plans/conductor/`).
2. See one-shot trails first-class, same trail component as multi-task waves.
3. No mode control UI in Phase 0 (session modes remain chat contracts per freeze).

---

## 3. Information architecture + wireframes

### 3.1 Dual-scope model (core product decision)

```
┌─────────────────────────────────────────────────────────┐
│  Fleet Desk                          [Global ▾ Company] │
│  scope chip always visible (never buried in settings)   │
└─────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   GLOBAL SCOPE                   PROJECT SCOPE
   • all companies                • one companies/*.md
   • all wave-plans handoffs      • trails joined to that company
   • global skills/               • project skills/ if on disk
   • fleet learnings/             • project learning paths if found
   • role usage rollup            • role usage for joined trails only
```

**Rule:** Scope is a **filter + data root**, not a second product. Same components, different inputs. Switching company never navigates to a different visual language.

**Company catalog source of truth:** `companies/*.md` YAML frontmatter only (do not invent companies from plan filenames alone). Unjoined waves still appear under Global → **Unattributed work** so nothing is hidden.

### 3.2 Route map (logical; static or local SPA)

| Route | Purpose |
|-------|---------|
| `/` | Global home |
| `/companies` | Company directory (active + placeholder) |
| `/companies/:id` | Company desk (filtered home) |
| `/work` | Work trail index (global or scoped) |
| `/work/:task_id` | Trail detail |
| `/skills` | Skill library |
| `/skills/:pack_id` | Pack detail |
| `/learnings` | Learning index |
| `/learnings/:slug` | Learning detail |
| `/roles` | Role usage + maturity |
| `/roles/:role` | Role detail |
| `/about` | How data is built, formulas, non-goals |

≤ **3 clicks** to any handoff or skill from home: Home → Work list → Trail, or Home → Skills → Pack.

### 3.3 Global home - ASCII wireframe

```
┌─ Fleet Desk ──────────────────────────────── Global · dark ─┐
│  Companies                                                  │
│  [olympus active] [safeplace active] [rios-operator …]      │
│  [aegis placeholder] [wearforrun placeholder]               │
│                                                             │
│  ┌ Recent work (12) ────────────────────────── View all → ┐ │
│  │ ✓  web-frontend · black-aces · wave 9 · done  14:32    │ │
│  │ ✓  frontend-critic · black-aces · wave 9 · done        │ │
│  │ ·  docs-writer · dev-agents · conductor · done         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌ Roles (top) ──────┐  ┌ Skills ──────────┐  ┌ Learnings ┐│
│  │ web-frontend  42  │  │ active packs  6  │  │ raw    2  ││
│  │ frontend-critic 38│  │ candidates    0  │  │ docs   3  ││
│  │ docs-writer    9  │  │ project ov.   ?  │  │ promo  0  ││
│  │ [maturity ···]    │  │ [library →]      │  │ [index →] ││
│  └───────────────────┘  └──────────────────┘  └───────────┘│
│                                                             │
│  Footer: generated 2026-07-29 12:01 · make desk · read-only │
└─────────────────────────────────────────────────────────────┘
```

### 3.4 Company page - same cards, scoped

```
┌─ Fleet Desk ────────────────────────── Company: olympus ─┐
│  ← Global    olympus · active · Arlencho/olympus-platform │
│  phase note from manifest (one line)                      │
│                                                           │
│  Work trails (joined) | Skills (global + project) | …     │
│  empty-state if n=0: "No handoffs joined to olympus yet"  │
└───────────────────────────────────────────────────────────┘
```

### 3.5 Work trail detail

```
┌─ Trail: 9-web-frontend-feat-ab-T05-jsonld-org ────────────┐
│  Status ✓ done    Role web-frontend    Wave 9             │
│  Branch feat/ab-T05-jsonld-org                            │
│  base e44ec21 → head b55471a                              │
│  Vendor mix: kimi (primary line) · exit 0                 │
│  Files: index.html                                        │
│  [GitHub PR if URL]  [Issue if #n parseable]              │
│                                                           │
│  ## Built (from handoff.md) …                             │
│  ## Do not repeat …                                       │
│  ## Evidence (fenced, redacted) …                         │
│                                                           │
│  Provenance lines (JSONL append-only, last N shown)       │
└───────────────────────────────────────────────────────────┘
```

### 3.6 Component inventory

| Component | Props / content | Phase |
|-----------|-----------------|-------|
| `ScopeSwitcher` | Global \| company id; sticky | 0 |
| `CompanyChip` | name, status (`active`/`placeholder`), github | 0 |
| `CompanyStrip` | list of chips from `companies/*.md` | 0 |
| `WorkTrailRow` | task_id, role, company?, wave, status, ts, vendor | 0 |
| `WorkTrailDetail` | jsonl mechanical + md intent sections | 0 |
| `StatusPill` | done / failed / unknown (from exit + status) | 0 |
| `SkillCard` | id, version, summary, roles[], status | 0 |
| `SkillDetail` | full frontmatter + body preview + role inject map | 0 |
| `LearningCard` | slug, status, mtime, linked packs | 0 |
| `RoleUsageTable` | n, ok, fail, vendors, critic_rate, coverage, band | 0 |
| `MaturityExplain` | formula + filled inputs (never vanity badge alone) | 0 |
| `EmptyState` | teaching CTA (`make desk` regen, run dispatch) | 0 |
| `SearchFilterBar` | role, company, status, skill id | 1 (stub in 0) |
| `DoNotRepeatThemes` | clustered phrases from handoff md | 1 |
| `EvidencePanel` | optional embed of `logs/evidence-latest.txt` if present | 1 |
| `VendorAuthBadge` | optional from `make vendor-auth --json` local only | 2 |

**No components** for: skill promote/write, dispatch trigger, Paperclip heartbeat, agent "chat", vendor marketing badges on delivery surfaces.

### 3.7 Hierarchy (scan order)

1. **Where am I?** Scope switcher + page title  
2. **What moved?** Recent trails  
3. **Who worked?** Role strip  
4. **What do we know?** Skills + learnings  
5. **Drill:** trail / pack / learning / role detail  

Density: information-dense laptop layout (not card-bloat dashboard). Prefer tables and tight lists over large hero metrics.

---

## 4. Data model / joins

### 4.1 Principle

**Read-only projection.** Git-tracked artifacts are truth. Local/gitignored files (`logs/evidence*`, auth JSON) are optional enrichment, never required for core views.

### 4.2 Entities

```
Company
  id, name, status, repo_path?, github_repo?, phase_blurb?

WavePlan
  path, wave_key, title_comment?, source: wave|conductor

WorkTrail
  task_id, wave, role, branch, status, ts?, base_sha?, head_sha?
  company_id?          # joined, may be null
  plan_path?
  vendor_lines[]       # from JSONL append-only
  agent_exit?
  files_touched[]
  intent_md_path?
  issue_refs[]         # best-effort parse
  pr_refs[]            # best-effort parse

SkillPack
  id, version, scope: global|project, summary
  path, status: active|candidate
  roles[]              # from role-skills.yaml invert

Learning
  slug, path, scope: global|project
  status: raw|documented|promoted|superseded
  linked_skill_ids[]   # from [ev: learnings/…] scan

RoleStats
  role, n_tasks, n_ok, n_fail, n_unknown
  vendor_counts{}, critic_involvement_rate
  pack_ids[], maturity → see §5
```

### 4.3 Source map (evidence-backed paths)

| Entity | Path(s) | Notes |
|--------|---------|-------|
| Company | `companies/*.md` frontmatter | `name`, `status`, `repo`, `github_repo` |
| Wave plans | `wave-plans/**/*.plan`, `wave-plans/conductor/*` | Conductor first-class |
| Handoff mechanical | `wave-plans/*/handoffs/*.jsonl` | Append-only; last line = latest attempt; count lines for failover |
| Handoff intent | `wave-plans/*/handoffs/*.md` | Built / Decisions / Do not repeat / Evidence |
| Global skills | `skills/<id>/SKILL.md` | Frontmatter: `id`, `version`, `scope`, `summary` |
| Candidates | `skills/_candidates/**` | Never injected (skills freeze) |
| Role → packs | `config/role-skills.yaml` | Invert for pack → roles |
| Fleet learnings | `learnings/*` | Markdown lessons |
| Project skills | `<product-repo>/skills/<id>/SKILL.md` | Only if `companies.*.repo` resolves on disk |
| Project learnings | `<product-repo>/docs/qa/learning-*.md` | Discovery rule (brief); skip if absent |
| Evidence aggregate | `logs/evidence-latest.txt`, `logs/evidence.csv` | Optional; from `make evidence` |
| Freezes (law links) | `docs/proposals/*-SYNTHESIS.md` | Footer / About only |

**Do not read as core data:** full agent transcripts under `logs/` or `~/dev/agent-logs/` (size + secrets risk). Link path strings from JSONL only; never inline transcript bodies in static export by default.

### 4.4 Join rules (Phase 0 - imperfect OK)

Work trails do not yet carry a first-class `company_id`. Phase 0 uses **ordered heuristics** and always records `join_method` + confidence:

| Priority | Rule | `join_method` |
|----------|------|----------------|
| 1 | Plan file comment / path contains company `name` or known github slug (e.g. `olympus-platform`, `black-aces`, `safeplace`) | `plan_path` |
| 2 | Plan task text or branch prefix matches company name / repo slug | `plan_text` |
| 3 | Handoff `log` path or task_id slug contains repo slug | `task_id` |
| 4 | Wave directory name matches a known experiment label mapped in a small static table in the generator (e.g. black-aces waves) | `wave_map` |
| 5 | Unmatched → `company_id = null`, appear under Global **Unattributed** | `none` |

**Static wave map (generator config, not secret):** optional `config/desk-joins.yaml` (Phase 0 may hardcode 3–5 known mappings in the generator script if a yaml file is overkill). Example intent:

```yaml
# Proposed - Phase 0 generator config (not shipped in this proposal PR)
waves:
  "1": { company: null, label: "early" }
  # black-aces SEO + A/B waves live under numeric dirs 4–11 etc.
repo_aliases:
  olympus-platform: olympus
  safeplace: safeplace
  black-aces: null   # not in companies/* yet - show as ad-hoc project label
```

**Ad-hoc projects:** Plans like black-aces are real fleet work without a `companies/*.md` entry. Phase 0 shows them as **Project labels** on Global (not fake companies). Phase 1 may add a lightweight company manifest or `desk-joins` alias.

### 4.5 Issue / PR parsing (best-effort)

From plan lines + handoff md + branch names:

- `owner/repo#123` or `#123` with known `github_repo` → issue link  
- URLs matching `github.com/.../pull/N` or `/issues/N`  
- No GitHub API required in Phase 0  

### 4.6 Learning status model

| Status | Rule |
|--------|------|
| `raw` | File exists, short or titled stub / "capture later" |
| `documented` | Substantial markdown lesson (default for current `learnings/*`) |
| `promoted` | Some active skill pack cites `[ev: learnings/<file>…]` or explicit frontmatter `promoted_to:` if added later |
| `superseded` | Frontmatter `superseded_by:` or filename marked archived (Phase 1) |

Phase 0 can implement `documented` vs `promoted` via citation scan; fine-grained `raw`/`superseded` can default conservatively (`documented` unless empty).

### 4.7 Generator output (projection)

Single offline generator produces a static site or JSON index:

```
site/desk/                 # or docs/experience/ - pick one in Phase 0 PR
  index.html
  data/index.json          # all entities, redacted
  assets/...
```

CLI:

```bash
make desk
# → ./scripts/desk-build.sh
# reads companies, wave-plans, skills, role-skills, learnings
# writes site/desk/
# optional: python -m http.server in site/desk
```

No always-on daemon. Rebuild after waves (or watch is Phase 2).

### 4.8 Redaction

Before any string lands in `data/index.json` or HTML:

- Strip tokens matching common secret patterns (Bearer, `sk-`, `ghp_`, long base64).  
- Never copy full log files.  
- Truncate Evidence sections to a safe length with "open local handoff path" pointer.

---

## 5. Metrics: role usage + skill maturity / seniority

### 5.1 Role usage (transparent inputs)

Per role, from handoff JSONL (last non-failover status line per task_id, plus optional failover count):

| Metric | Definition |
|--------|------------|
| `n` | Distinct `task_id` |
| `n_ok` | `status==done` and `agent_exit==0` (if exit missing, status only) |
| `n_fail` | `status==failed` or `agent_exit!=0` |
| `n_unknown` | Missing status/exit |
| `vendor_mix` | Counts of `provenance.vendor` on **first** line (primary) and note failover lines separately |
| `critic_rate` | Among trails whose role is `*-critic` or paired producer trails that have a same-branch critic task_id pattern - Phase 0: simply % of tasks where `agent` contains `critic` vs producers; Phase 1: pair by branch |
| `skill_coverage` | Count of packs in `role-skills.yaml` for role beyond shared defaults; flag `has_specialized` if any pack is not in the global default set `{evidence-first, untrusted-prior, git-ship}` |

**Display:** numbers first. Charts optional Phase 1.

### 5.2 Seniority model - **Playbook Maturity Band** (not agent IQ)

**Forbidden:** "web-frontend is Senior III" without formula.  
**Allowed:** an evidence-cited **maturity band** for the *role's playbook surface + outcomes*.

#### Formula (v1 - explainable)

For each role `R`:

```
coverage   = clamp( packs(R) / 4 , 0..1 )     # 4 ≈ defaults.max_packs
reliability = n_ok / max(n, 1)                  # unknown excluded from denom if n_ok+n_fail>0
volume     = clamp( log10(n+1) / log10(51) , 0..1 )  # ~50 tasks → full volume credit
critic     = critic_involvement proxy 0..1      # Phase 0: 1 if role is critic else 0.5 if producer has any critic sibling in same wave else 0
versioning = clamp( avg_version(packs(R)) / 5 , 0..1 )  # integer versions; v5+ caps

score = 0.30*coverage + 0.35*reliability + 0.15*volume + 0.10*critic + 0.10*versioning
```

Bands (labels are about **playbooks**, not personas):

| Score | Band | Meaning |
|-------|------|---------|
| 0.00–0.24 | **Thin** | Few packs or little successful work |
| 0.25–0.49 | **Forming** | Defaults inject; some trail history |
| 0.50–0.74 | **Hardened** | Reliable outcomes + real coverage |
| 0.75–1.00 | **Seasoned** | Strong reliability, volume, versioned packs |

UI always shows **score breakdown** on expand (five components). If `n < 5`, band is labeled **Seasoned\*** only with asterisk: "low-n - treat as provisional" and prefer showing raw n.

#### Skill evolution metrics (library level)

| Metric | Definition |
|--------|------------|
| Active packs | count `skills/*/SKILL.md` excluding `_candidates` |
| Candidate packs | count under `_candidates/` |
| Mean / max version | from frontmatter integers |
| Learning→skill rate | `# learnings with status promoted / # learnings` |
| Roles with specialized packs | roles whose pack list differs from `default:` |
| Inject map density | edges in role↔pack bipartite graph |

**Phase 0:** versions and counts from current tree only.  
**Phase 1:** optional `git log -L` / blame timeline for version bumps (nice, not blocking).

### 5.3 Explicit rejection

- No gamified XP, streaks, or "agent leveled up."  
- No vendor leaderboard that implies model IQ (vendor mix is operational provenance only).  
- Critic "bite" as REVISE rate requires structured critic verdicts; only add when parseable from handoff md (`VERDICT:`) - Phase 1.

---

## 6. UX principles + visual system

### 6.1 Principles

1. **Projection, not control** - read-only; actions are "open path", "copy command", "open GitHub."  
2. **Dual scope always visible** - never make the user wonder if they are global or olympus.  
3. **Honest empty states** - teach the next command (`dispatch`, `make evidence`, `make desk`).  
4. **Evidence over ornament** - every metric has a definition link to `/about#maturity`.  
5. **≤ 3 clicks** to handoff or skill.  
6. **Coexist with CLI** - Desk does not replace `make evidence` / `make scorecard` / `make vendor-auth`; it links and optionally embeds their outputs.  
7. **Freeze-aligned** - no promote-from-UI; skills law and session-mode law linked in About.  
8. **Single-operator Phase 0** - no multi-user accounts.

### 6.2 Visual system

| Token | Proposal |
|-------|----------|
| Theme | **System preference** default (`prefers-color-scheme`); optional toggle persisted in `localStorage` only |
| Base | Dark-friendly neutral zinc/slate; not pure black |
| Accent | One calm accent (e.g. teal) for links and focus - not traffic-light dashboard soup |
| Status | done = green, failed = red, unknown = muted, placeholder company = dashed border |
| Type | System UI stack: `ui-sans-serif, system-ui, …` for speed; mono for SHAs, task_ids, paths |
| Density | Comfortable-compact: 14px body, tight tables, 8px rhythm |
| Radius | 6–8px cards; avoid glassmorphism |
| Motion | None required; respect `prefers-reduced-motion` |
| Layout | Max width ~1200px home; full width tables on Work |

### 6.3 Accessibility

- Semantic landmarks: `header`, `nav`, `main`, `h1`–`h3` in order  
- Focus visible on all interactive elements  
- Contrast AA for text/status pills  
- Keyboard: skip link to main, tables tabbable, no hover-only data  
- Do not rely on color alone for status (icon or text label)

### 6.4 Craft bar (why this is a product)

- Home tells a story in one screenful: **companies → movement → capability**.  
- Trail detail feels like a **readable case file**, not a JSON dump (section headings from handoff intent).  
- Maturity is **humble**: provisional low-n labeling, formula always one click away.  
- Footer always: generation timestamp + "read-only projection" so trust stays calibrated.

---

## 7. Phase 0 ship list (days, not months)

### 7.1 Goal

Usable daily overview from **existing** artifacts, imperfect joins OK, beautiful enough that the operator prefers Desk over hunting directories.

### 7.2 Concrete deliverables

| Item | Path / command | Notes |
|------|----------------|-------|
| Generator script | `scripts/desk-build.sh` (+ small Python helper if needed) | Read-only scan; write `site/desk/` |
| Join config (optional) | `config/desk-joins.yaml` | Aliases + ad-hoc project labels |
| Make target | `make desk` | Runs generator; documents open URL |
| Static site | `site/desk/**` or `docs/experience/**` | Prefer `site/desk/` gitignored **or** commit a thin checked-in snapshot under `docs/experience/` - **decision:** Phase 0 **gitignore `site/desk/`**, commit only generator + a short `docs/experience/README.md` explaining build; avoids secret leak via accidental commit of evidence embeds |
| Docs | `docs/experience/README.md` | How to build, what data is used, maturity formula summary |
| About page in site | baked HTML | Formulas, non-goals, freeze links |
| Redaction helper | part of generator | Patterns listed in script header |
| Smoke test | `tests/desk-build-smoke.sh` or extend existing test harness | Generator exits 0 on this repo; index.json has companies ≥ 1 and skills ≥ 1 |

**Out of Phase 0 code:** React/Next app, daemon, GitHub API, promote API, Paperclip panels, live tail of agent logs.

### 7.3 Phase 0 pages (must)

1. Global home  
2. Company directory + company desk  
3. Work list + trail detail  
4. Skills library + pack detail  
5. Learnings index + detail (fleet path)  
6. Roles table + role detail with maturity breakdown  
7. About / methodology  

### 7.4 Phase 1 (after love)

- Richer PR/issue joins (`gh` optional offline cache)  
- Skill version timeline from git history  
- Do-not-repeat theme clustering  
- Project skill/learning scan when `repo` path exists  
- Search/filter bar fully wired  
- Optional embed of `make evidence` output when file present  
- Critic verdict parse (`VERDICT:`)  

### 7.5 Phase 2+ (only if Phase 0 loved)

- Watch mode / auto-rebuild  
- Multi-operator auth (still local)  
- Optional Paperclip panel (explicitly optional per brief)  
- Notifications (PR promote reminders) - still no auto-merge  

### 7.6 Suggested implementation order (Phase 0 week)

1. Schema `data/index.json` + company + skills + role invert (half day)  
2. Handoff JSONL/md ingest + work list (one day)  
3. Joins + unattributed bucket (half day)  
4. HTML templates / small static CSS (one day)  
5. Maturity formula + About (half day)  
6. `make desk`, README, smoke test, polish empty states (half day)  

Stack recommendation (secondary to product): **Python 3 stdlib + static HTML/CSS** (matches `wave-report.sh` style) **or** a single-file generator. Avoid a heavy frontend toolchain for Phase 0.

---

## 8. Risks, non-goals, open questions

### 8.1 Risks

| Risk | Mitigation |
|------|------------|
| Wrong company joins | Show join_method; Unattributed bucket; never invent companies |
| Secret leakage in static export | Redaction; gitignore generated site; no transcripts |
| Vanity metrics | Formula always visible; low-n asterisk |
| Stale site | Footer timestamp; `make desk` after waves documented in operator-guide |
| Scope creep to "fleet control plane" | Charter: read-only projection; no dispatch UI |
| Black-aces not in companies/* | Ad-hoc project labels, not fake manifests |
| Duplicate handoff intent noise (wrong md copied across tasks) | Show mechanical JSONL as authority for status; treat md as advisory (skills freeze untrusted-prior) |

### 8.2 Non-goals

- Replace GitHub Issues / Projects  
- Auto-promote skills or edit `skills/*/SKILL.md` from UI  
- New always-on daemon  
- Cloud SaaS / multi-tenant product  
- Paperclip heartbeat dependency  
- Anthropomorphic agent seniority  
- Storing full agent transcripts in public static sites  
- Session mode switcher product (modes stay chat contracts)  

### 8.3 Open questions for owner SYNTHESIS

1. **Generated site location:** gitignored `site/desk/` only, vs occasional committed snapshot under `docs/experience/` for browsing on GitHub?  
2. **Black-aces & similar:** promote to `companies/black-aces.md`, or keep ad-hoc labels forever?  
3. **Project repo scan:** Phase 0 skip if path missing, or require explicit `desk-joins` allowlist of absolute/relative paths?  
4. **Maturity weights:** accept v1 weights or prefer reliability-heavy (e.g. 0.50 reliability)?  
5. **Name freeze:** **Fleet Desk** vs keep **Experience Console** for continuity with the brief?

---

## 9. Why this beats `make evidence` + README

| Need | CLI today | Fleet Desk |
|------|-----------|------------|
| Cross-company picture | Manual `ls companies` + memory | Company strip + status |
| "What did the tool do?" | Hunt `wave-plans/*/handoffs` | Chronological work trails |
| Read intent | `cat` random md | Structured trail case file |
| Skills map | Read yaml + tree | Library + role invert + versions |
| Learnings vs skills | Separate dirs, no join | Funnel + citation link |
| Seniority story | None (or vibes) | Explainable maturity bands |
| Conductor work | Easy to miss subdirectory | First-class source filter |
| Onboarding engineer | Operator-guide walls of text | 2-minute home scan |

`make evidence` remains the **quality aggregate** for waves and A/B metrics. Fleet Desk is the **spatial and historical map** of experience: where work happened, what playbooks exist, and whether those playbooks have earned hardened status. They complement; Desk should deep-link to "run `make evidence`" rather than reimplement every scorecard column on day one.

---

## 10. Fit with freezes (checklist)

| Freeze rule | Desk response |
|-------------|----------------|
| Promotion PR-only; human merge global | Skills UI read-only; status + docs link only |
| No producer auto-merge skills | No write actions |
| No vector daemon as SoT | Static generator from git files |
| Session modes = contracts; no daemon | Conductor plans as data only; no mode runtime |
| Session Auto ≠ `dispatch.sh --auto` | About page glossary |
| Delivery face: no vendor branding on commits/PRs | Desk may show vendor **provenance** in trail detail (operational), never as marketing chrome on export meant for public product sites |
| Experience inputs do not auto-write skills | Generator never writes under `skills/` |

---

## 11. Success criteria mapping (brief §8)

1. **Understand fleet work in < 2 minutes** - Global home: companies + recent trails + role strip.  
2. **Global vs project without confusion** - Sticky scope switcher; same components.  
3. **Role usage transparent** - table with n/ok/fail/vendor + definitions.  
4. **Credible maturity** - Playbook Maturity Band with five-term formula; reject vanity.  
5. **Phase 0 daily-usable** - `make desk` static site, real handoffs/skills/companies, craft bar in §6.

---

## 12. Summary decisions (Seat A)

| Decision | Choice |
|----------|--------|
| Name | **Fleet Desk** |
| Architecture | Offline generator → static site; no daemon |
| Scope | Dual filter (Global / Company), one component system |
| Joins | Heuristic + unattributed; optional `desk-joins.yaml` |
| Skills | Read-only library; candidates visible; no promote button |
| Seniority | Playbook Maturity Band (formula v1), not agent levels |
| Stack | Stdlib generator + semantic HTML/CSS |
| CLI coexistence | Complements `make evidence` / scorecard / vendor-auth |
| Phase 0 | Home, company, work, skills, learnings, roles, about |

---

*End of Seat A proposal. Independent of other seats. Owner SYNTHESIS chooses pillars; this file is not law.*
