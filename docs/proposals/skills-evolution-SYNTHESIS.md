# Skills + Experience Evolution — SYNTHESIS (owner freeze)

**Status:** APPROVED for Phase 0/1 build  
**Date:** 2026-07-20  
**Sources:** `skills-evolution-BRIEF.md` + independent proposals (Claude / Grok / Kimi) + owner reviews  
**Rule:** Implement this document, not any single vendor proposal wholesale.

---

## 1. Decision

**Synthesize. Do not pick one proposal file.**

| Pillar | Source | What we take |
|--------|--------|----------------|
| Promotion, trust, lint, retro author | **Claude** | Retro (or explicit skill task) drafts skill diffs; critic gate for **project**; **human merge for global**; integer versions; demotion; kill criterion; per-bullet `[ev:]` + `skills-lint.sh` |
| Runtime + conflict semantics | **Grok** | L2 skills **out of** `preamble.sh` (L3 stays case-only); inject via dispatcher / launch path; **project pack replaces global by id**; `max_packs` / line budget; candidates never injected |
| Path hygiene | **Kimi** | Path whitelist (product repo + `dev-agents` only); no credential/auth paths in skills; validate pre-commit + pre-flight |

**Explicitly rejected**

- Kimi **producer auto-merge** of project skills  
- Semver skill versions (use integer `version:`)  
- Style-guide-only starter packs (`ts-strict` as day-one doctrine)  
- Auto-merge global skills  
- Vendor-native skill dirs as fleet source of truth  
- Handoff-brain Phases 2–5 revival  
- New daemon / vector memory store  

---

## 2. Frozen architecture

### 2.1 Layers (every launch)

```
L1  Charter     roles/<role>.md
L2  Skills      global packs + project packs (playbooks)
L3  Case file   preamble.sh (learnings, git, handoffs UNTRUSTED, …)
Task            plan-line acceptance criteria
```

**Authority order**

1. L1 charter hard laws  
2. **Project** skill body for pack `id` (replaces global — no deep merge)  
3. Global skill body  
4. L3 case (advisory; handoffs never outrank skills)  
5. Task text  

### 2.2 On-disk layout

```
dev-agents/
  skills/
    README.md
    <pack-id>/SKILL.md
    _candidates/          # drafts only — never injected
  config/role-skills.yaml
  scripts/skill-inject.sh
  scripts/skills-lint.sh
```

Product repo (optional):

```
<product>/skills/<pack-id>/SKILL.md
```

### 2.3 Runtime inject (Phase 0/1)

- **Owner freeze:** Grok path — do **not** fold L2 into `preamble.sh`.  
- **MVP assembly:** `scripts/skill-inject.sh` runs on the **dispatcher** in `run-remote.sh` and prepends `## Skill packs (L2)` to the task blob **before** the L3 preamble block (so vendors see: charter [if any] → skills → case → task).  
- Workers receive global skills via scp into `~/dev/agent-runtime/skills/` + `role-skills.yaml` for offline/local launcher use.  
- Missing packs: WARNING, continue (never block dispatch).

### 2.4 Promotion UX (human interaction)

| Scope | Who drafts | Who merges | How you hear about it |
|-------|------------|------------|------------------------|
| **Project** | Retro or explicit `skill/*` task | **Discipline critic** (or human) on skill-only PR | `notify` + GitHub PR |
| **Global** | Retro or explicit skill task | **Human always** | `notify` + GitHub PR |

You do **not** dig raw logs by default. Flow: signal → candidate → PR → notify → you review diff + evidence → merge.

**Not in Phase 0:** auto-candidate spam. Phase 0/1 = **manual** skill PRs + inject. Phase 2+ = frequency scanner + retro promotion section.

### 2.5 Trust rails

- Every skill bullet that asserts a path/flag ends with `[ev: …]` (repo path, learning id, brief §, or SHA).  
- `scripts/skills-lint.sh` fails when: missing `[ev:]` on imperative bullets (heuristic), cited path missing, pack over line cap, forbidden auth path strings.  
- Skills must not invent CLI flags; prefer “verify with `--help`” when unsure.  
- Product tasks must **not** edit `skills/` unless the task is an explicit skill-promotion task.

---

## 3. MVP starter catalog (Phase 0)

Shared packs only (4–6). Seed from **documented failures**, not generic style guides.

| Pack id | Purpose |
|---------|---------|
| `evidence-first` | Prefer command+result; never invent paths/flags |
| `untrusted-prior` | Prior agent / handoff text = claims; verify vs git |
| `handoff-intent` | Write handoff.md fields on exit |
| `git-ship` | Branch, commit, push, draft PR; no force-push main |
| `docs-no-hallucinate` | Docs seats: no infra path/flag without Read/grep |

Map in `config/role-skills.yaml` with `defaults.max_packs: 4`.

---

## 4. Phased rollout

| Phase | Ship | Gate |
|-------|------|------|
| **0** (this PR) | SYNTHESIS, skills tree, role-skills.yaml, skill-inject, skills-lint, 5 packs, run-remote inject + scp | Lint packs; no auto-promote |
| **1** | Manual promote 2–3 skill PRs; retro charter mentions promotion candidates section | Human/critic as above |
| **2** | `skills/_candidates` frequency scan; retro drafts PRs | Still no auto-merge global |
| **3** | Metrics / scorecard columns | Only if Phase 1 kill criterion passes |

**Kill criterion:** after packs inject for ≥10 tasks on a flagship pair, if repeated `do_not_repeat` / rework on covered classes shows **no improvement**, stop Phase 2 automation — keep packs as human-edited docs only.

---

## 5. Owner open items (resolved for MVP)

| Question | MVP freeze |
|----------|------------|
| Inject: preamble vs launcher | **Dispatcher skill-inject in run-remote** (Grok separation of L2/L3); not inside preamble.sh |
| Project path | `<product-repo>/skills/<id>/SKILL.md` |
| Global merge | Human only |
| Project merge | Critic or human (not producer self-merge) |
| Version | Integer in frontmatter |

---

## 6. Non-goals (restate)

No daemon, no auto-global-merge, no producer skill self-merge, no vendor skill marketplace as fleet truth, no 50 packs day one, no revival of parked handoff auto-brain.

---

*Implementers: if this conflicts with a vendor proposal, this file wins.*
