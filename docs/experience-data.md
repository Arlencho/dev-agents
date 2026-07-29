# Fleet Desk — data contract (`site/experience/data/index.json`)

**Producer:** `scripts/experience_data.py` (`make experience-data`)
**Consumer:** `scripts/experience_build.py` — the HTML renderer reads **only** this file
**Law:** [`docs/proposals/experience-console-SYNTHESIS.md`](proposals/experience-console-SYNTHESIS.md)
**Current `schema_version`:** `1`

```text
git artifacts ──► experience_data.py ──► site/experience/data/index.json ──► experience_build.py ──► *.html
```

`make experience` runs both steps in that order. The JSON is the stable surface:
anything a future UI (Wave 2 redesign, a JS view, another tool) needs must exist
here first. The renderer never scans the repo, so a field that is not in the JSON
cannot appear on a page.

The whole tree (`site/experience/`, JSON included) is **gitignored** and rebuilt on
demand.

---

## Top level

| Key | Type | Meaning |
|-----|------|---------|
| `schema_version` | int | Bumped on breaking changes. The renderer refuses a version it does not know. |
| `generator` | string | `scripts/experience_data.py` |
| `law` | string | Path to the freeze this projection obeys |
| `phase` | int | Fleet Desk phase (0) |
| `generated_at` | string | UTC ISO-8601 build time |
| `repo` | string | Directory name of the projected repo |
| `counts` | object | `companies`, `trails`, `waves`, `skills`, `learnings`, `roles`, `unlinked_trails` |
| `fleet` | object | `n_done`, `critic_rate` (share of trails whose role name contains `critic`), `vendor_mix` |
| `join_rules` | array | The ordered rules actually applied (`order`, `method`, `source`) |
| `pmi_policy` | object | Frozen PMI gates (see below) |
| `warnings` | array | Non-fatal build warnings (e.g. a join pointing at an unknown company) |
| `companies` | array | See below |
| `trails` | array | See below — newest first |
| `waves` | array | `{wave, n, task_ids}` — numeric waves descending, `wave: null` last |
| `skills` | array | See below |
| `learnings` | array | See below |
| `role_stats` | object | role → stats + PMI |
| `watchlist` | array | `{theme, count}` — do-not-repeat lines seen ≥ 2 times |

## `companies[]`

Source: `companies/*.md` frontmatter.

| Field | Notes |
|-------|-------|
| `id`, `name` | Frontmatter `name`, else filename stem |
| `status` | `active`, `placeholder`, … (verbatim) |
| `repo`, `github_repo` | `TBD…` values are normalised to `""` |
| `phase_note` | First "active phase" line from the body (≤ 120 chars) |
| `source` | Repo-relative manifest path |
| `trail_count` | Trails joined to this company |

Companies come **only** from `companies/*.md`. Nothing else in the pipeline may
create one.

## `trails[]`

One trail = one handoff task. Source: `wave-plans/**/handoffs/*.jsonl` (last line
wins — the file is append-only) plus the sibling `*.md`.

| Field | Notes |
|-------|-------|
| `task_id` | Handoff `task_id`, else JSONL stem |
| `wave` | int or `null` |
| `wave_source` | `handoff_field` · `plan_directory` · `task_id_prefix` · `none` |
| `agent`, `role` | Same value; `role` is the stable name for UIs |
| `status` | `done`, `failed`, `unavailable`, `unknown`, … (verbatim) |
| `branch` | Task branch |
| `provenance` | `{vendor, model, host}` — mechanical, from the handoff |
| `base_sha`, `head_sha` | Short SHAs (12 chars) |
| `ts` | Handoff timestamp |
| `agent_exit` | int or `null` |
| `files_touched`, `diff_stat` | Orchestrator fields |
| `plan_hint` | First `#` heading of the handoff markdown |
| `conductor` | `true` when the handoff lives under `wave-plans/conductor/` |
| `company_id` | Company id or `null` |
| `join_method` | `config_map` · `github_repo` · `repo_path` · `name_token` · `unlinked` |
| `join_evidence` | The token/pattern that matched (empty when unlinked) |
| `project_label` | Ad-hoc project label for unlinked work (never a company) |
| `issue_links` | Up to 8 parsed GitHub URLs / `#123` refs |
| `handoff_summary` | First bullet of `## Built`, ≤ 200 chars |
| `handoff_sections` | `built`, `decisions`, `do_not_repeat`, `evidence`, `open_questions`, `next_hint` → `{text, lines, truncated}`; redacted, ≤ 4000 chars each |
| `handoff_markdown` | Whole handoff, redacted, ≤ 12000 chars |
| `source` | `{jsonl, md, log_name}` — `log_name` is a **filename only**; transcripts are never read |

## `skills[]` / `learnings[]`

| Skill field | Notes |
|-------------|-------|
| `id`, `version`, `scope`, `summary` | `SKILL.md` frontmatter |
| `status` | `active` (`skills/*/SKILL.md`) or `candidate` (`skills/_candidates/*/SKILL.md`) |
| `path` | Repo-relative |
| `roles` | Roles injecting this pack, from `config/role-skills.yaml` |
| `body`, `body_truncated` | Redacted body, ≤ 20000 chars |

| Learning field | Notes |
|----------------|-------|
| `slug`, `title`, `path` | Product learnings are prefixed `<company>-` and titled `[company] …` |
| `status` | `promoted` when a skill body cites the file, else `documented` |
| `company_id` | Set for learnings discovered inside a company repo on disk |
| `body`, `body_truncated` | Redacted body, ≤ 20000 chars |

Promotion stays **PR-only**: this projection reports status, it never writes skills.

## `role_stats`

Per role: `n`, `n_done`, `n_fail`, `n_unknown`, `n_known`, `success_rate`,
`vendor_mix`, `packs`, `specialized_packs`, `skill_coverage`, `is_critic`,
`task_ids`, and `pmi`.

`pmi` = `{band, reason, cap, cap_reason, gates, inputs}` so every displayed band
can be expanded to its raw inputs.

---

## Join rules (ordered, SYNTHESIS §3.5)

1. `config_map` — `config/experience-joins.yaml` (`pattern: company_id`). A pattern
   pointing at a company that does not exist is **dropped** and recorded in `warnings`.
2. `github_repo` — company `github_repo` (full slug or repo name token).
3. `repo_path` — last path segment of company `repo`.
4. `name_token` — company id as a whole token.
5. `unlinked` — no company. An ad-hoc `project_label` may be derived from
   `wave-plans/*.plan` filenames; **a label is not a company**.

Matching is case-insensitive over: task id, branch, plan hint, redacted handoff
markdown, handoff path, and the log **filename**.

## PMI gates (frozen, SYNTHESIS §5.2)

| Band | Gate |
|------|------|
| `P0` | `n < 3` |
| `P1` | `n ≥ 3` |
| `P2` | `n_done ≥ 5` **and** `success_rate ≥ 0.70` (a specialized pack alone never grants P2) |
| `P3` | Phase 1 only — Phase 0 hard-caps display at `P2` (`cap_reason` explains why) |

`success_rate = n_done / (n_done + n_fail)`; percentages are always published next
to their `n`.

## Redaction

Before any handoff/learning/skill text enters the JSON it passes a redactor that
replaces token shapes (`ghp_…`, `github_pat_…`, `sk-…`, `xox…`, `AKIA…`, JWTs,
`Bearer …`, PEM private keys) and `key: value` credential assignments with
`[redacted…]`. Absolute operator paths are rewritten repo-relative or `~/`-relative.
`tests/run-experience-tests.sh` fails the build if secret shapes or home paths
appear in the JSON or HTML.

## Changing the schema

1. Add fields additively when possible; keep `schema_version` at 1.
2. On a breaking change: bump `SCHEMA_VERSION` in `scripts/experience_data.py`,
   update this file, and update `tests/run-experience-tests.sh`.
3. The renderer exits non-zero on an unknown `schema_version` rather than drawing
   a half-correct page.

## Fixture

`tests/fixtures/experience-mini/` is a synthetic repo covering every join method,
every wave source, all PMI bands, and secret redaction. Build it directly:

```bash
python3 scripts/experience_data.py  --repo tests/fixtures/experience-mini --out /tmp/fd
python3 scripts/experience_build.py --repo tests/fixtures/experience-mini --out /tmp/fd
```
