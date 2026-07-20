# Proposal: Skills + Experience Evolution for the Multi-Vendor Fleet

**Author:** Claude seat
**Date:** 2026-07-20
**Status:** Draft for three-way comparison
**Brief:** [skills-evolution-BRIEF.md](skills-evolution-BRIEF.md)

---

## 1. Executive summary

Agents today have L1 charters (`roles/*.md`) and raw experience streams (learnings JSONL, handoffs, retros) but no L2 skill layer and no loop that turns experience into durable capability. This proposal adds:

1. A small **shared skills tree** (`skills/<pack>/SKILL.md`) in `dev-agents`, mapped to roles via `config/role-skills.yaml` — ~10 packs on day one, reused across roles.
2. A **vendor-neutral runtime**: `scripts/preamble.sh` (which already assembles charter + learnings + handoffs) gains a skills slice, so claude/kimi/grok all receive identical skill text with zero vendor-specific plumbing.
3. **Experience capture reuse**: learnings and handoffs stay the raw stream; a new `promote` verb tags entries as skill candidates instead of inventing a new store.
4. A **promotion pipeline** where the `retro` role drafts skill diffs as PRs; project skills merge on critic approval, **global skills always require human merge** (fleet blast radius).
5. **Trust rails**: every skill bullet must cite evidence (SHA, learning id, or log); a lint script rejects uncited claims, invented flags/paths, and oversized packs.

MVP (2 weeks): skills tree + role mapping + preamble injection + manual promotion PR flow. Automation of candidate harvesting and retro-driven drafting comes after the loop is proven by hand.

---

## 2. Basic skills catalog approach

### 2.1 Principles

- **Few packs, heavy reuse.** The brief's 19 roles do not get 19 skill sets. They share ~10 packs; `role-skills.yaml` composes them.
- **Playbooks, not identity.** Charters say *who you are and what you never touch*. Skills say *how to do a class of work well here* — checklists, known traps, verified commands.
- **Every bullet earns its place.** A skill line exists because it prevented (or would have prevented) a real failure, or encodes a repo-verified procedure. Speculative "best practices" content is banned; that's what model pretraining already provides.

### 2.2 Starter inventory (proposed packs)

| Pack | Path | Consumed by |
|------|------|-------------|
| `git-discipline` | `skills/git-discipline/SKILL.md` | all producers + critics |
| `handoff-writing` | `skills/handoff-writing/SKILL.md` | all producers |
| `critic-review` | `skills/critic-review/SKILL.md` | all critics, security-reviewer, pr-sentinel |
| `branch-verification` | `skills/branch-verification/SKILL.md` | all critics (fixes the known "critic on wrong branch" class) |
| `frontend-work` | `skills/frontend-work/SKILL.md` | web-frontend, mobile, frontend-critic |
| `backend-work` | `skills/backend-work/SKILL.md` | go-backend, api-designer, backend-critic, api-critic |
| `data-work` | `skills/data-work/SKILL.md` | db-architect, database-critic |
| `ops-work` | `skills/ops-work/SKILL.md` | devops, orchestrator |
| `docs-work` | `skills/docs-work/SKILL.md` | docs-writer (must encode the anti-confabulation rule from brief §2.5: never state an infra path or CLI flag you did not verify with Read/grep) |
| `investigation` | `skills/investigation/SKILL.md` | investigate, retro, cto, plan-critic |

Ten packs, each ≤80 lines. Day-one content is seeded from what we already know went wrong: plan `|` delimiter bugs, critic branch checkout, Keychain vs `~/.claude/.credentials.json` on SSH workers, docs confabulation. That gives the tree immediate, evidence-backed value rather than boilerplate.

### 2.3 Pack format

```markdown
---
pack: branch-verification
version: 3            # integer, bumped on every merged change
scope: global
roles: [frontend-critic, backend-critic, database-critic, api-critic, plan-critic]
---

# Branch verification (critics)

## Before reviewing
- [ ] `git fetch origin && git checkout <branch>` — never review from main. [ev: learnings/dev-agents.jsonl#L14]
- [ ] Confirm HEAD matches the handoff's `head_sha`; mismatch → report, don't guess. [ev: brief §2.4]
...
```

The `[ev: …]` citation is mandatory per bullet (see §7). Version is an integer, not semver — simpler diffs, no bikeshedding.

### 2.4 Role mapping

`config/role-skills.yaml` (new file, grep-parseable like existing configs):

```yaml
# role: space-separated pack list; order = injection order
web-frontend: git-discipline handoff-writing frontend-work
frontend-critic: git-discipline critic-review branch-verification frontend-work
docs-writer: git-discipline handoff-writing docs-work
# ...
```

---

## 3. Runtime load model (claude / kimi / grok)

### 3.1 The one mechanism that already works for all three vendors

Fact: `scripts/preamble.sh <repo> <agent> <branch> [wave] [provider]` already assembles CLAUDE.md, learnings, git state, and handoff slices into text injected at launch, and it is vendor-agnostic. Skills should ride the same rail.

**Proposed change (design, not implemented):** preamble gains a skills section, assembled in this order:

```
L1 charter          roles/<agent>.md                      (already loaded by launchers)
L2 global skills    dev-agents/skills/<pack>/SKILL.md      for each pack in role-skills.yaml
L2 project skills   <product-repo>/skills/<pack>/SKILL.md  same pack names, project overlay
L3 case file        existing preamble output (learnings, git, handoffs, issue)
```

- **Inputs:** `config/role-skills.yaml`, `skills/` tree, product repo `skills/` tree (if present).
- **Output:** a `## Skills` section in preamble text, each pack delimited with its name and version.
- **Budget:** cap via `config/preamble.yaml` (e.g. `skills_max_lines: 400`); if over budget, drop project-overlay refs first, never the checklist headers.
- **Failure mode:** missing pack file → warn to stderr, continue. A broken skills tree must never block dispatch (learnings.sh already follows this "best effort, `|| true`" pattern).

### 3.2 Why not vendor-native skill dirs (yet)

Vendor-native skill dirs exist unevenly outside this repo (brief §2.2, e.g. `~/.grok/skills`) and are not role-mapped. Syncing our tree into vendor dirs would mean three sync targets, drift on SSH workers, and no single audit point. Preamble injection gives one code path, one budget, one diff to review. **Speculation, deferred:** a later `scripts/sync-skills.sh` could mirror packs into vendor-native dirs for vendors that do smart lazy-loading — only worth it if preamble token cost becomes measurable pain.

### 3.3 Project overlay resolution

Same pack name in the product repo **appends after** the global pack (labeled "Project overlay"). It may add and may explicitly override a global bullet by quoting it ("Global says X; in this repo do Y because …"), but silent contradiction is a lint failure. Rationale: append-with-explicit-override keeps global packs authoritative and makes conflicts human-visible instead of resolved by injection order luck.

---

## 4. Experience capture

Reuse the three existing streams; extend, don't replace.

| Event | What gets written | Mechanism |
|-------|-------------------|-----------|
| Task fail / repeated mistake | learning entry, `type: failure` | existing `scripts/learnings.sh add` |
| Critic REVISE verdict | learning entry tagged with the pack it implicates: `--pack branch-verification` (new optional flag on `learnings.sh add` — an extension to our own script, not an invented vendor flag) | extended `learnings.sh` |
| Task success with novel technique | handoff `## Decisions` (already exists); no new writing burden | existing handoff format |
| Human correction mid-session | learning entry, `severity: high` | existing `learnings.sh add` |
| Production incident | `learnings/<project>-<incident>.md` narrative (pattern already in use: `paperclip-cost-runaway-2026-05-13.md`) | existing convention |

One new verb: `learnings.sh promote <id>` sets `candidate: true` on an entry. That's the entire capture-side change — the candidate queue is a filter over the JSONL we already have (`learnings.sh query --candidates`), not a new store. Handoffs stay exactly as Phase 1 left them: human-audit + raw evidence, untrusted cross-vendor claims. We mine them; we do not auto-trust them (brief §2.4).

---

## 5. Promotion / evolution mechanism

### 5.1 Pipeline

```
raw experience ──▶ candidate ──▶ draft skill diff ──▶ review gate ──▶ merged pack (version+1)
(learnings,        (promote       (retro role,          (critic for      (git commit + push)
 handoffs, logs)    flag)          PR on branch)         project; human
                                                         for global)
```

1. **Candidate marking.** Anyone — orchestrator, critic, human, or the retro role — runs `learnings.sh promote <id>`. Threshold heuristic for auto-marking by retro: same failure signature ≥2 times across tasks, or any `severity: high` human correction.
2. **Drafting.** The `retro` role (charter exists: `roles/retro.md`) is the only role allowed to author skill diffs. It reads candidates + relevant handoffs, edits the pack, bumps `version`, cites evidence per bullet, opens a PR on branch `skill/<pack>-v<N>`.
3. **Review gate:**
   - **Project skills** (product repo): one critic seat reviews the PR (OK/REVISE discipline already in critic charters). OK → merge. Humans can audit async.
   - **Global skills** (`dev-agents/skills/`): critic review **plus mandatory human merge**. No exceptions. Blast radius is every agent on every product.
4. **Ship.** Merge to main; next dispatch picks it up via preamble automatically. No cache, no daemon.

### 5.2 Spam / bloat prevention

- **Single author role** (retro) — producers cannot self-serve edit skills after a lucky task.
- **Hard size caps** enforced by lint (§7): pack ≤120 lines post-merge; a PR that grows a pack must justify or also prune ("one in, consider one out").
- **Evidence citation required** per added bullet; uncited additions fail lint, cannot merge.
- **Demotion path:** retro PRs may delete bullets whose failure mode hasn't recurred in N waves (start N=20, tune later). Skills that only grow become charters nobody reads.
- **Rate limit by convention:** at most one open PR per pack at a time.

### 5.3 Charter vs skill promotion

If a learning is about *scope or law* ("docs-writer must never touch OpenAPI specs") it belongs in the L1 charter, and only a human edits charters. Retro flags these as `charter-candidate` in its report instead of drafting a PR.

---

## 6. Global vs project split

| | Global | Project |
|---|--------|---------|
| **Lives at** | `dev-agents/skills/<pack>/SKILL.md` | `<product-repo>/skills/<pack>/SKILL.md` |
| **Mapping** | `dev-agents/config/role-skills.yaml` | inherits global mapping; product repo may add packs via `skills/role-skills.yaml` (same format) |
| **Owner** | fleet owner (human merge) | product lead or critic seat |
| **Merge gate** | critic review + human merge, always | critic OK sufficient |
| **Commit path** | branch `skill/<pack>-v<N>` in dev-agents, push, PR | branch `skill/<pack>-v<N>` in product repo, push, PR |
| **Conflict rule** | authoritative baseline | appends + explicit quoted overrides only (§3.3) |

**Promotion between scopes:** when retro sees the same project-level bullet appear (or apply) in ≥2 product repos, it drafts a global PR hoisting it and follow-up PRs deleting the project copies. Downward is free-form: any project can specialize.

**Why product-repo `skills/` and not `companies/<product>.md`:** the brief allows either; a `skills/` dir keeps pack names symmetric across scopes so the overlay logic in §3.3 is a filename match, not a parser.

---

## 7. Trust & safety

The brief's sharpest warning: *skills that invent CLI flags or file paths will poison the fleet* — and docs agents have already confabulated infra paths (§2.5). Rails:

1. **Evidence citations, mechanically checked.** Every bullet ends with `[ev: <path>#L<n> | <learning-id> | <sha> | brief §x]`. Proposed `scripts/skills-lint.sh` (bash + grep, matching house style) fails a PR when: a bullet lacks `[ev:]`; a cited repo path doesn't exist; a pack exceeds size cap; frontmatter version wasn't bumped; a project overlay contradicts global without quoting it.
2. **Command claims must be greppable.** Any `command --flag` mentioned in a skill must appear in repo scripts, or the bullet must be phrased as "verify with `--help` first." The linter greps `scripts/` and `providers/` for the flag string. This directly targets the confabulation failure mode.
3. **Untrusted self-report stays untrusted.** Handoffs are inputs to drafting, never citable as sole evidence for a command or path — only for intent and outcomes. Git SHAs and logs are the ground truth, consistent with the Phase 1 decision.
4. **No auto-merge to global, ever.** Stated in §5, restated here as a law. A poisoned project pack hurts one product for one wave; a poisoned global pack hurts every seat until someone notices.
5. **Rollback is `git revert`.** Because skills ship as plain files via preamble, reverting the pack commit fully restores prior behavior on the next dispatch. No state to flush anywhere.
6. **Injection hygiene.** Skill text enters the same preamble as untrusted handoff slices; packs are trusted (they passed review), so they are injected *outside* the untrusted-input delimiter that handoffs use.

---

## 8. Retros at scale

Today retros are periodic synthesis not wired to skills (brief §2.3). Proposed:

- **Trigger:** end of every wave-plan (orchestrator appends a retro task as the final wave) plus a weekly fleet-wide retro across projects. No daemon — it's a plan line like any other task.
- **Inputs:** `scripts/retro-data.sh` output (exists), `learnings.sh query --candidates`, wave handoff dirs, dispatch logs, provider scorecard.
- **Outputs, in priority order:** (a) candidate markings, (b) skill-diff PRs (≤2 per retro run — forced prioritization beats a 15-PR spam wall), (c) a `wave-plans/<wave>/retro.md` report listing what it saw but didn't promote, so signal isn't lost, (d) charter-candidate flags for humans.
- **Human bottleneck relief:** humans stop reading raw logs and instead review small, evidence-cited diffs. Project-scope promotion doesn't wait on humans at all (critic gate). The human queue contains only global PRs and charter changes — the two highest-blast-radius, lowest-volume streams.
- **Failure modes:** retro drafts a wrong skill → critic REVISE catches it, or lint blocks it; retro hallucinates evidence → lint path-check fails; retro seat rate-capped (exit 75) → retro task rides normal `routing.yaml` failover like any seat.

---

## 9. Phased rollout

### Phase 0 — MVP (ships in 2 weeks)
1. Create `skills/` tree with the 10 starter packs, seeded only from documented failures (brief §2.5, learnings files). Human-written, critic-reviewed.
2. Add `config/role-skills.yaml`.
3. Extend `scripts/preamble.sh` with the skills section + line budget.
4. Extend `scripts/learnings.sh` with `--pack` tag and `promote` verb.
5. Run promotion **manually**: human plays the retro-drafter role for the first 2–3 skill PRs to validate the format and gates.

### Phase 1 — Loop closes (weeks 3–6)
6. `scripts/skills-lint.sh` + wire into PR checks (pr-sentinel already reviews PRs).
7. Retro role charter updated to draft skill PRs; retro task appended to wave plans.
8. Project `skills/` overlay in one pilot product repo (black-aces — small, active).

### Phase 2 — Scale (after evidence)
9. Cross-project hoisting (project → global promotion heuristic).
10. Metrics dashboard via `make scorecard`-style target (`make skills-report`).
11. **Only if justified by data:** vendor-native skill dir sync (§3.2 speculation).

Kill criteria, learned from the handoff A/B: if after Phase 1 the repeated-failure rate (§10) shows no movement over ~4 weeks, stop investing in automation and keep only the static Phase 0 packs — those are cheap and already paid for.

### 9.1 Cost sketch (Phase 0)

| Item | Estimate |
|------|----------|
| 10 starter packs | ~600 lines of markdown, human-reviewed |
| `role-skills.yaml` | ~25 lines |
| `preamble.sh` change | ~40 lines of bash |
| `learnings.sh` change | ~30 lines of bash |
| New daemons / services | **0** |

---

## 10. Success metrics

All computable from artifacts we already write (bash + jq over JSONL/logs):

1. **Repeated-failure rate** (primary): same failure signature appearing in learnings across ≥2 tasks, per 100 tasks. Success = downward trend after the relevant pack ships.
2. **do_not_repeat recurrence:** how often a handoff `## Do not repeat` item reappears as a later failure. Direct measure of "experience sticking."
3. **Critic REVISE rate** per role, before/after pack version bumps that target that role.
4. **Rework rate:** tasks needing a follow-up fix task in a later wave.
5. **Promotion health:** candidates marked vs promoted vs rejected per month (rejection ≈100% → drafting is noise; ≈0% → gate is rubber-stamping).
6. **Skill mass:** total pack lines over time — should plateau, not climb monotonically (demotion working).
7. **Guard metric — token cost:** preamble size before/after; skills slice stays within its configured budget.

Attribution caveat (marked as such): metrics 1–4 are correlational, not causal — vendor mix and task difficulty shift between waves. The A/B lesson from the handoff brain applies: easy tasks produce ceiling effects, so measure on real backlogs, not synthetic smoke tasks.

---

## 11. Explicit non-goals

- **No auto-merge of any skill change to global scope.** Ever, in any phase.
- **No revival of parked handoff-brain Phases 2–5.** Handoffs remain raw evidence + audit; this proposal reads them, doesn't rebuild them.
- **No per-vendor skill forks.** One pack serves all three CLIs; vendor quirks get a labeled subsection inside a pack, not a parallel tree.
- **No new daemon, DB, or service.** Bash + git + existing scripts only.
- **No skills-as-charters.** Identity, scope, never-touch lists stay in `roles/*.md` under human control.
- **No 50-pack taxonomy on day one.** Packs are created by demonstrated need, capped in size, and deletable.
- **No replacement of multi-vendor orchestration.** The fleet stays; skills make seats better, not fewer.

---

## 12. Open questions for the owner

1. **Critic seat for global skill PRs:** reuse `plan-critic`, or add a dedicated `skills-critic` charter? (I lean reuse until PR volume proves otherwise — fewer seats, fewer charters.)
2. **Pilot product:** is black-aces the right first project overlay, or is olympus/safeplace higher-value despite more risk?
3. **Retro cadence:** per-wave retro task + weekly fleet retro — too much? A per-wave retro on a 10-wave day is 10 extra seat-runs; a cheaper alternative is per-plan (per wave-plan file) rather than per-wave.
4. **Demotion window:** is N=20 waves without recurrence acceptable for deleting a bullet, or do you want human sign-off on all deletions from global packs too?
5. **Learning IDs:** learnings JSONL entries need stable IDs for `promote <id>` and `[ev:]` citations. OK to add an `id` field (e.g. `<project>-<epoch>`) on write, tolerating id-less legacy rows?
6. **Preamble budget:** what's the acceptable ceiling for the skills slice (`skills_max_lines`)? I proposed 400; on small models / rate-capped fallback seats a lower cap may be wise.
7. **Private vs shared learnings:** some human corrections may reference product-confidential context. Should project-scope learnings ever be citable in *global* pack evidence, or must global bullets cite only dev-agents-local evidence?

---

*End of proposal.*
