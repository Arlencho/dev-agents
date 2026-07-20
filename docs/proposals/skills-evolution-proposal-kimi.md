# Proposal: Skills + Experience Evolution — Kimi Version

| Field | Value |
|-------|-------|
| **Status** | Draft for review |
| **Author** | Kimi Code session (2026-07-20) |
| **Repo** | `dev-agents` |
| **Scope** | Design only — global + project skill stores, runtime loading, evolution gates |
| **Related** | `roles/*.md`, `scripts/preamble.sh`, `scripts/learnings.sh`, `scripts/retro-data.sh`, `providers/*/launch.sh`, `config/workers.yaml`, `config/routing.yaml` |

---

## 1. Executive Summary

This proposal turns the fleet from "a charter per role" into "a charter plus a small set of versioned, reusable skill packs per role." Skills are concrete playbooks (not identity statements) that live in two git-backed stores: a **global** store in `dev-agents` and a **project** store in each product repo. Experience is captured from handoffs, learnings, and critic REVISE findings, then promoted into skill updates through a gated review process. The runtime is unchanged in spirit: `preamble.sh` and the vendor launchers concatenate charter + skills + case context into the prompt. No new daemon, no vendor-native memory syncing, no invented CLI flags or auth paths.

Key design choices:
- **L2 skills are plain markdown files** with a tiny YAML frontmatter header. They are human-readable, diff-reviewable, and trivial to inject into any vendor prompt.
- **Project skills override global skills** for the same tag; conflicts are resolved by precedence, not merge magic.
- **Promotion to global skills requires a critic or human gate** because the blast radius is fleet-wide.
- **Project skill promotions can be auto-merged** by the producer role when the change is scoped to that product and tests pass.
- **Anti-hallucination is structural**: every skill references verifiable files or commands; a skill manifest is validated before injection.

---

## 2. Basic Skills Catalog Approach

### 2.1 Starter set: small, shared, role-mapped

We do **not** write 50 bespoke skill packs on day one. We seed a small catalog of **cross-cutting skill packs** and map them to roles in a single YAML file.

Proposed initial catalog (6–8 global packs):

| Skill pack | Applies to | What it teaches |
|------------|-----------|-----------------|
| `git-hygiene` | All producers | Branch naming, atomic commits, never commit secrets, handoff-before-exit |
| `prompt-discipline` | All | No invented CLI flags/auth paths; verify before relying; cite evidence |
| `ts-strict` | `web-frontend`, `mobile` | No `any`, no `@ts-ignore`, controlled components, `next/image` |
| `go-style` | `go-backend`, `api-designer` | Error handling, interfaces, generated client usage |
| `sqlc-migrations` | `db-architect` | Migration safety, index gotchas, rollback discipline |
| `openapi-contracts` | `api-designer`, `go-backend`, `web-frontend` | Spec-first, generated clients, response envelopes |
| `critique-format` | All critics | Verdict grammar, file:line citation, no LGTM noise |
| `security-smell` | `security-reviewer`, all critics | Common injection / auth / secret leak patterns |

Roles declare which packs they load. A role like `web-frontend` loads `git-hygiene`, `prompt-discipline`, `ts-strict`, and optionally project-specific packs. A critic role loads `critique-format`, `prompt-discipline`, and a subset of the producer packs for the discipline it reviews.

### 2.2 Role-to-skill mapping

A single file, `config/role-skills.yaml`, lists each role and its skill tags:

```yaml
roles:
  web-frontend:
    global: [git-hygiene, prompt-discipline, ts-strict]
    project: [true]   # load project skills tagged for this role
  frontend-critic:
    global: [prompt-discipline, critique-format, ts-strict]
    project: [true]
  go-backend:
    global: [git-hygiene, prompt-discipline, go-style]
    project: [true]
  # ... etc
```

Keeping the mapping explicit prevents silent skill inflation and makes it obvious which roles carry which expectations.

### 2.3 Skill file format

Each pack is a markdown file with a small frontmatter block:

```markdown
---
id: ts-strict
version: 1.0.0
scope: [web-frontend, mobile]
kind: playbook   # playbook | checklist | anti-pattern | template
requires: [git-hygiene]
---

# TypeScript strict-mode playbook

## Rule: no explicit `any`
- Prefer `unknown` + narrow; if you must type an external shape, use a generated or hand-written interface.
- Evidence command: `npx tsc --noEmit` must pass.

## Rule: images
- Use `next/image` with explicit `width`, `height`, and `alt`.
- Counter-example: `<img src="..." />` without `alt` fails a11y review.
```

This format is intentionally boring: it is readable in GitHub, diffable in PRs, and injectable into any vendor prompt without a parser beyond `strip_frontmatter` (already in `providers/lib.sh`).

---

## 3. Runtime Model

### 3.1 Loading order

When `dispatch.sh` invokes a vendor launcher, the prompt is assembled in this fixed order:

1. **L1 Charter** — `roles/<role>.md` (existing behavior).
2. **Global skills** — `skills/global/<skill-id>.md` for every tag in `config/role-skills.yaml → global` for this role.
3. **Project skills** — `<product-repo>/skills/<skill-id>.md` (or tagged project packs) for this role.
4. **Preamble** — `scripts/preamble.sh` output: CLAUDE.md slice, learnings, git state, issue context, provider continuity, upstream handoffs.
5. **Task** — the current task string.

The order matters: skills establish reusable rules before the transient case file arrives. Project skills come after global skills so they can refine or override.

### 3.2 Multi-vendor injection

All three launchers already inject the charter by prepending it to the task prompt (`providers/kimi/launch.sh`, `providers/grok/launch.sh`) or by relying on the `--agent` name (`providers/claude/launch.sh`). We extend only the non-Claude launchers; Claude can load skills by adding a `--agent`-like indirection or by having the orchestrator prepend them.

Concrete changes to `providers/kimi/launch.sh` and `providers/grok/launch.sh`:

```bash
SKILLS_DIR="${SKILLS_DIR:-$SCRIPT_DIR/../../skills/global}"
PROJECT_SKILLS_DIR="${PROJECT_SKILLS_DIR:-}"   # set by dispatch.sh from companies/<product>.md
ROLE_SKILLS_FILE="$SCRIPT_DIR/../../config/role-skills.yaml"

SKILLS_TEXT=""
# Load global skills for this role by reading role-skills.yaml (grep-based, no yaml lib)
for tag in $(grep -A5 "^  $ROLE:" "$ROLE_SKILLS_FILE" | grep 'global:' | tr -d '[]' | tr ',' '\n' | tr -d ' '); do
    [ -f "$SKILLS_DIR/$tag.md" ] && SKILLS_TEXT+="$(strip_frontmatter "$SKILLS_DIR/$tag.md")\n\n"
done
# Load project skills if present
if [ -n "$PROJECT_SKILLS_DIR" ] && [ -d "$PROJECT_SKILLS_DIR" ]; then
    for tag in ...; do
        [ -f "$PROJECT_SKILLS_DIR/$tag.md" ] && SKILLS_TEXT+="$(strip_frontmatter "$PROJECT_SKILLS_DIR/$tag.md")\n\n"
    done
fi

PROMPT="## Your Role Charter
$(strip_frontmatter "$CHARTER_FILE")

## Skills
${SKILLS_TEXT}

## Task
$TASK"
```

This reuses `strip_frontmatter` from `providers/lib.sh` and requires no new CLI flags.

### 3.3 Project skills path resolution

The orchestrator already knows which product repo it is working in via `companies/<product>.md` (e.g. `companies/olympus.md`, `companies/safeplace.md`). That manifest gains one optional field:

```yaml
skills_dir: skills   # relative to product repo root
```

`dispatch.sh` exports `PROJECT_SKILLS_DIR=<repo-root>/<skills_dir>` when launching an agent. If the directory does not exist, project skills are skipped silently.

---

## 4. Experience Capture

### 4.1 Existing mechanisms we keep and extend

| Mechanism | What we change | What stays the same |
|-----------|---------------|---------------------|
| `scripts/learnings.sh` | Add `skill-candidate` type and structured `suggestion` field | Storage in `learnings/<project>.jsonl`, severity, pruning |
| Handoffs (`wave-plans/<wave>/handoffs/`) | Add a `learnings:` section to each handoff | Provenance header, untrusted-input framing |
| Critic verdicts | REVISE must cite the violated skill or propose a new one | Existing `VERDICT: PASS | REVISE | BLOCK` grammar |
| `scripts/retro-data.sh` | Include skill-candidate counts and repeated `do_not_repeat` themes | Existing log/learnings/git aggregation |

### 4.2 New `skill-candidate` learning type

Agents can append a candidate learning that suggests a skill addition or update:

```bash
./scripts/learnings.sh add dev-agents web-frontend skill-candidate \
  "web-frontend repeatedly omits alt text on next/image; add alt-text checklist to ts-strict skill" \
  --severity medium
```

Stored as:

```json
{
  "ts": "2026-07-20T21:00:00Z",
  "project": "dev-agents",
  "agent": "web-frontend",
  "type": "skill-candidate",
  "summary": "web-frontend repeatedly omits alt text on next/image; add alt-text checklist to ts-strict skill",
  "severity": "medium",
  "skill_id": "ts-strict",
  "scope": "project"
}
```

The `scope` field is `project` by default (promote to project skills first) and `global` only if the candidate clearly affects multiple products.

### 4.3 Handoff `learnings:` section

Each handoff gains a short `learnings` section:

```markdown
## Learnings for skill promotion
- [project] `ts-strict`: add alt-text checklist (observed in this task).
- [global] `prompt-discipline`: verify that a recommended CLI flag exists in `--help` before using it.
```

These are claims, not promotions. The retro agent or a critic must validate them before they become skill updates.

---

## 5. Promotion / Evolution Mechanism

### 5.1 Two promotion lanes

| Lane | Source | Gate | Target | Merge authority |
|------|--------|------|--------|-----------------|
| **Project skill update** | Handoff `learnings:` + `skill-candidate` entries | Producer role + green CI/tests | `<product-repo>/skills/<id>.md` | Producer agent on that repo |
| **Global skill update** | Repeated project promotions or fleet-wide pattern | Critic review (`plan-critic` or discipline critic) + human/CTO for `version` bumps | `dev-agents/skills/global/<id>.md` | Human or CTO gate |

### 5.2 Promotion flow

1. **Collect**. On task exit, the orchestrator (or a small `scripts/promote-skill.sh` helper) scans the handoff and recent `skill-candidate` learnings for the project.
2. **Deduplicate**. A learning becomes promotable only after it appears in at least **two independent tasks** or is raised by a critic REVISE. This prevents one-off noise from becoming doctrine.
3. **Draft**. The producer agent (or `retro` agent) writes a proposed skill update as a markdown file in a branch: `feat/skill-<id>-v<version>`.
4. **Review**.
   - Project scope: the discipline critic reviews the diff. If it passes, the producer merges.
   - Global scope: a critic reviews, then a human (or `cto` agent under human approval) merges.
5. **Tag**. Skill files carry `version: major.minor.patch`. A patch is a clarification; minor is a new rule/checklist; major is a breaking change to an existing rule.

### 5.3 Spam prevention

- **Two-task threshold** before promotion.
- **Project-first rule**: almost every new rule starts in a project skill and only graduates to global after it generalizes.
- **Version pinning**: `config/role-skills.yaml` can pin a skill version, so a bad promotion does not automatically infect every future task.
- **Revert path**: because skills are git files, a bad promotion is reverted like any other commit.

---

## 6. Global vs Project Split

### 6.1 Ownership

| Store | Lives in | Owned by | Examples |
|-------|----------|----------|----------|
| Global | `dev-agents/skills/global/` | Fleet / CTO | `git-hygiene`, `prompt-discipline`, `critique-format` |
| Project | `<product-repo>/skills/` | Product team / producer role | `olympus-payment-flow`, `safeplace-a11y`, `black-aces-seo` |

### 6.2 Conflict resolution

When the same `skill_id` exists in both stores:

- **Project wins** for tasks running against that product repo.
- **Global wins** only when no project skill with that ID exists.
- No automatic merge. If a project intentionally diverges from global, the project skill file starts with a comment explaining why.

Example precedence in the launcher:

```bash
if [ -f "$PROJECT_SKILLS_DIR/$tag.md" ]; then
    source="$PROJECT_SKILLS_DIR/$tag.md"
elif [ -f "$GLOBAL_SKILLS_DIR/$tag.md" ]; then
    source="$GLOBAL_SKILLS_DIR/$tag.md"
else
    source=""
fi
```

### 6.3 Commit/push paths

- **Global**: skill changes are committed to `dev-agents` on a feature branch and pushed to origin. They ride through the normal PR + critic + CTO gate.
- **Project**: skill changes are committed to the product repo, usually alongside the code change that motivated them, or in a dedicated `feat/skill-*` branch. They are pushed and reviewed through that repo's normal process.

### 6.4 Distribution

Because skills are markdown in git, no runtime registry is required. A worker just needs the repo checked out at the right branch. This matches the existing `run-remote.sh` model.

---

## 7. Trust & Safety

### 7.1 Anti-hallucination constraints

The brief explicitly warns that skills can poison the fleet if they invent CLI flags or file paths. We enforce this structurally:

1. **Manifest validation before injection**. `scripts/validate-skills.sh` runs as a pre-flight check (and as a git pre-commit hook) to ensure every referenced file exists and every referenced command is found in `PATH` or documented in the repo.
2. **No unverified CLI flags**. A skill that recommends a flag must include an `evidence` command such as `claude --help | grep -E '^\s+--flag'` or a link to a docs file in the repo.
3. **Path whitelist**. Skills can only reference paths under the product repo root or `dev-agents/`. Absolute paths outside these roots are rejected.
4. **No auth paths**. Skills must not mention `~/.claude/.credentials.json`, Codeium paths, or any per-machine credential location.

### 7.2 Untrusted self-report

Cross-vendor handoffs are already framed as untrusted claims. The same applies to skill candidates:

- A skill candidate from a Kimi task is not promoted until a Claude critic (or human) verifies it.
- The `retro` agent treats learnings as raw data, not ground truth, and looks for corroboration across tasks.

### 7.3 Global skill gate

No agent may directly commit to `dev-agents/skills/global/` on `main`. The path requires:

1. A feature branch.
2. A critic review (discipline-matched or `plan-critic`).
3. Either a human merge or a CTO-agent merge with `status:approved` label.

This mirrors the existing PR-sentinel pattern and prevents a single misbehaving agent from rewriting fleet doctrine.

---

## 8. Retros at Scale

### 8.1 Retro agent upgrade

`roles/retro.md` already analyzes wave plans, learnings, and git stats. We extend its mandate:

- **Skill-candidate triage**: produce a weekly `docs/retros/<date>-skill-candidates.md` listing promotable candidates, grouped by skill ID and scope.
- **Repeated failure detection**: if the same `do_not_repeat` theme appears in ≥2 handoffs in 30 days, flag it as a skill promotion candidate.
- **Skill velocity metric**: count skill-version bumps per month and per role.

### 8.2 Automation without human bottleneck

| Activity | Automation | Human/Critic gate |
|----------|-----------|-------------------|
| Capture learnings + candidates | Agent on every task exit | None (raw data) |
| Triage candidates into a report | `retro` agent weekly | None (report only) |
| Promote project skill | Producer + critic | Critic review |
| Promote global skill | `retro` or producer drafts | Critic + human/CTO merge |
| Emergency global fix (bad skill causing failures) | Human or CTO agent | Human merge |

The human bottleneck is intentionally reserved for global changes, where the blast radius is largest.

### 8.3 Fleet-scale feedback loop

A good skill reduces failures across products. We detect this by:

- Tagging each learning with the skill IDs it relates to.
- Plotting `failure` entries per skill over 30-day windows.
- If a skill update correlates with a drop in related failures, the version bump is validated. If failures rise, the update is rolled back or revised.

---

## 9. Phased Rollout

### Phase 0 — Foundation (week 1)

- Create `skills/global/` directory with the 6–8 starter packs.
- Add `config/role-skills.yaml` mapping roles to packs.
- Add `scripts/validate-skills.sh` with path/command checks.
- Update `providers/kimi/launch.sh` and `providers/grok/launch.sh` to inject skills.
- Update `roles/retro.md` to mention skill-candidate triage.

### Phase 1 — Project skills (week 2)

- Add `skills_dir` to one or two `companies/<product>.md` manifests.
- Seed one project skill per pilot product from a recent repeated issue.
- Run the promotion lane on real tasks: handoff `learnings:` → producer draft → critic review → merge.
- Measure: do project skill updates reduce repeated failures?

### Phase 2 — Evolution loop (weeks 3–4)

- Enable `skill-candidate` type in `scripts/learnings.sh`.
- Automate the weekly retro skill-candidate report.
- Run the first global skill promotion through the critic + CTO gate.
- Add skill-related columns to `make scorecard`.

### Phase 3 — Scale (later)

- Skill versioning and pinning in `config/role-skills.yaml`.
- Per-product skill effectiveness dashboard.
- Optional: skill packs for `orchestrator` and `cto` meta-roles.

---

## 10. Success Metrics

| Metric | How measured | Target |
|--------|-------------|--------|
| **Repeated failure rate** | `do_not_repeat` themes appearing in ≥2 handoffs / month | Decline over 90 days |
| **Skill promotion velocity** | Version bumps in `skills/global/` and product `skills/` | 2–4 global, 4–8 project per month initially |
| **Rework rate** | Critic REVISE rate on first pass | Decline for roles with active skills |
| **Skill injection coverage** | % of roles with at least 3 active skill packs | 100% of active producer/critic roles |
| **Bad-skill rollback rate** | Reverts or emergency fixes to skill files | <1 per quarter |
| **Runtime cost** | Preamble size increase from skill injection | <20% growth; stays under argv limits |

---

## 11. Explicit Non-Goals

- **No vendor-native skill sync.** Skills live in git and are injected by prompt. We do not sync to `~/.kimi/skills`, `~/.claude/`, or Grok user skills.
- **No automatic global promotion.** Every global skill change passes a critic + human/CTO gate.
- **No transcript bus or shared session state.** Continuity stays handoff-based and git-backed.
- **No new daemon or service.** The runtime is still bash + git + existing scripts.
- **No product UI implementation.** This proposal is fleet infrastructure only.
- **No editing of other vendors' proposal files.** This is the Kimi cut; synthesis happens after all three exist.

---

## 12. Open Questions for the Owner

1. **Starter pack scope**: Are the 6–8 proposed global packs the right set, or should we start smaller (e.g. `git-hygiene`, `prompt-discipline`, `critique-format` only) and grow organically?
2. **Project skill path**: Should project skills live in the product repo under `skills/`, or should they be mirrored in `companies/<product>.md` as inline sections?
3. **CTO gate for global skills**: Is the `cto` agent allowed to approve global skill merges under human delegation, or must a human always click merge?
4. **Version pinning**: Should `config/role-skills.yaml` pin exact skill versions, or always load `main`? Pinning is safer but adds update overhead.
5. **Cross-vendor skill authorship**: Should a skill originally drafted by Kimi be reviewed by Claude before global promotion, or is discipline-matching enough?
6. **Skill effectiveness tracking**: Do we want a lightweight JSON/JSONL ledger of skill-version → failure-count correlations, or is git history + `learnings.sh stats` sufficient?

---

*End of proposal.*
