# Fleet Desk — data contract (`site/experience/data/index.json`)

**Producer:** `scripts/experience_data.py` (`make experience-data`)
**Consumer:** `scripts/experience_build.py` — the HTML renderer reads **only** this file
**Law:** [`docs/proposals/experience-console-SYNTHESIS.md`](proposals/experience-console-SYNTHESIS.md)
**Current `schema_version`:** `2` (Phase 1 enrichment — see [Migration](#migration-v1--v2))

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
| `phase` | int | Fleet Desk phase (`1`) |
| `generated_at` | string | UTC ISO-8601 build time |
| `repo` | string | Directory name of the projected repo |
| `counts` | object | `companies`, `trails`, `waves`, `skills`, `learnings`, `roles`, `unlinked_trails`, `critic_pairs` |
| `fleet` | object | `n_done`, `critic_rate` + `critic_rate_method` / `critic_rate_label` / `critic_rate_basis`, `vendor_mix` |
| `join_rules` | array | The ordered rules actually applied (`order`, `method`, `source`) |
| `pmi_policy` | object | PMI gates + `display_cap`, `cap_reason`, `history_available` (see below) |
| `skill_history` | object | `{available, depth, source, reason, skills_with_history}` — was `git log` readable? |
| `gh_enrichment` | object | `{status, reason, repo, prs_indexed, issues_indexed, fetched_at, trails_with_pr, fields}` |
| `warnings` | array | Non-fatal build warnings (e.g. a join pointing at an unknown company) |
| `companies` | array | See below |
| `trails` | array | See below — newest first |
| `waves` | array | `{wave, n, task_ids}` — numeric waves descending, `wave: null` last |
| `critic_pairs` | array | Producer ↔ critic pairs found on a shared branch (see below) |
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
| `handoff_truncated` | `true` when `handoff_markdown` hit the 12000-char cap |
| `source` | `{jsonl, md, log_name}` — `log_name` is a **filename only**; transcripts are never read |
| `is_critic` | Role name contains `critic` |
| `reviewed_by` | Task ids of critic trails on the **same branch** (empty = not reviewed) |
| `reviews` | Task ids of producer trails this critic trail reviewed |
| `pr_url`, `pr_state`, `pr_number` | From `gh` when enrichment ran; `""` / `null` otherwise |
| `issue_links_resolved` | `{ref, number, url, state, title, kind}` — titles only, never bodies |

## `skills[]` / `learnings[]`

| Skill field | Notes |
|-------------|-------|
| `id`, `version`, `scope`, `summary` | `SKILL.md` frontmatter |
| `status` | `active` (`skills/*/SKILL.md`) or `candidate` (`skills/_candidates/*/SKILL.md`) |
| `path` | Repo-relative |
| `roles` | Roles injecting this pack, from `config/role-skills.yaml` |
| `body`, `body_truncated` | Redacted body, ≤ 20000 chars |
| `git_history` | Newest-first `{sha, date, ts, subject}`, ≤ `history_depth` (20) entries |
| `revisions`, `first_commit`, `last_commit` | Derived from `git_history` |
| `history_available`, `history_truncated`, `history_depth` | `history_available: false` = git could not be read (**not** "no commits") |
| `promotes` | Learning slugs this pack cites (`[ev: learnings/…]`) |

| Learning field | Notes |
|----------------|-------|
| `slug`, `title`, `path` | Product learnings are prefixed `<company>-` and titled `[company] …` |
| `status` | `promoted` when a skill body cites the file, else `documented` |
| `promoted_by` | Skill ids citing this learning (inverse of `skills[].promotes`) |
| `company_id` | Set for learnings discovered inside a company repo on disk |
| `body`, `body_truncated` | Redacted body, ≤ 20000 chars |

Promotion stays **PR-only**: this projection reports status, it never writes skills.

### Skill git history (Phase 1)

`git log --follow -n 20 -- <skill path>` per `skills/*/SKILL.md` **and**
`skills/_candidates/*/SKILL.md`. One `git log` per pack, capped at
`GIT_LOG_DEPTH = 20`; subjects are redacted and capped at 160 chars.

If git is missing or the tree is not a work tree, the build still succeeds:
`skill_history.available` is `false`, every `git_history` is `[]`, and a warning
is recorded. Empty history with `available: true` means the file has no commits
yet — the two cases are never conflated.

## `critic_pairs[]`

One entry per branch that carries **both** a producer trail and a critic trail:

| Field | Notes |
|-------|-------|
| `branch` | The shared branch |
| `wave`, `company_id` | Lowest wave / first company id seen in the group |
| `producers`, `critics` | Task ids |
| `producer_roles`, `critic_roles` | Role names |
| `critic_verdicts` | Distinct critic `status` values on that branch |

## `role_stats`

Per role: `role` (the role name, repeated inside the object so a role entry
survives being read out of the map), `n`, `n_done`, `n_fail`, `n_unknown`, `n_known`, `success_rate`,
`vendor_mix`, `packs`, `specialized_packs`, `skill_coverage`, `is_critic`,
`n_reviewed`, `review_rate`, `n_reviews_given`, `paired_branches`, `task_ids`,
and `pmi`.

`pmi` = `{band, reason, cap, cap_reason, gates, inputs}` so every displayed band
can be expanded to its raw inputs. `inputs` adds `proven_loop`,
`proven_loop_evidence` and `history_available` in schema v2.

---

## Derived views (renderer-side, schema unchanged at v2)

Fleet Desk v2 (Phase A, [`fleet-desk-v2-SYNTHESIS.md`](proposals/fleet-desk-v2-SYNTHESIS.md))
adds pages that are **pure derivations** over the fields above. The renderer
computes them from `trails[]` at render time; nothing new is stored, so
`schema_version` stays `2`, the join rules and PMI gates are untouched, and
`experience_data.py` needs no change.

### Missions

A **mission** is usually a GitHub issue: trails are grouped by their primary
issue anchor, resolved in this order:

1. a gh-resolved link (`issue_links_resolved`, `kind: "issue"`) — wins because
   it carries a verified repo, title and state;
2. a full `…/issues/N` URL from `issue_links` — key = `owner/repo#N`;
3. a bare `#N` ref — **repo-ambiguous**, so the key is scoped per company
   (`<company_id>#N`, `unlinked#N` when unjoined) instead of merging unrelated
   issues that share a number. Refs with 6+ digits are treated as IDs/colors
   (e.g. the hex `#050505` in a theme handoff) and never anchor a mission.

Derived per mission: `company_id` (first non-null among its trails), `repo`
(from the URL key, else the company `github_repo`), waves (distinct `wave`
values), and state: **settled** (all trails `done`) · **blocked** (no `done`,
some `failed`/`unavailable`) · **mixed** (some `done`, some not) · **open**
(nothing `done`, nothing blocked). A mission with exactly one trail is
**simple 1:1** and renders without wave chrome. When no resolved issue
carried a title, the card title falls back to the newest trail's `plan_hint`
and says so (`title from trail`). Trails with no issue link have **no
mission** — they stay honest under Work.

### Pipeline language

Every surface speaks Queued · In flight · Blocked · Settled, mapped from trail
`status`: `done` → Settled; `failed` / `fail` / `unavailable` / `error` →
Blocked. **Queued and In flight are not derivable from settled handoffs**, so
the Almanac renders them as `—` with a pointer to the Ops Floor. Live counts
are never invented, and live state is never written into this contract
(Phase B streams it separately).

### Ops Floor (`/live/`)

A static shell: Wave-lane and Conductor-spine **structure** with empty states.
It ships no data and fakes no agents; Phase B wires `logs/fleet-events/`.

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

## PMI gates (SYNTHESIS §5.2)

| Band | Gate |
|------|------|
| `P0` | `n < 3` |
| `P1` | `n ≥ 3` |
| `P2` | `n_done ≥ 5` **and** `success_rate ≥ 0.70` (a specialized pack alone never grants P2) |
| `P3` | **P2 gate met AND proven-loop evidence** (below). Display cap is now `P3`. |

`success_rate = n_done / (n_done + n_fail)`; percentages are always published next
to their `n`.

### P3 gate (exact, Phase 1)

A role is `P3` when **both** hold:

1. it already clears the P2 outcome bar (`n_done ≥ 5` and `success_rate ≥ 0.70`), **and**
2. at least one of its **specialized** packs (packs beyond the shared defaults
   `evidence-first`, `untrusted-prior`, `git-ship`) shows a closed loop:

   | Path | Condition | Source |
   |------|-----------|--------|
   | version history | `version ≥ 2` **and** `revisions ≥ 2` | `SKILL.md` frontmatter + `git log` |
   | promotion | the pack cites a learning file (`promotes` non-empty) | skill body `[ev: learnings/…]` |

Shared default packs are excluded on purpose: every role gets them, so they prove
nothing about this role. Outcomes alone never reach P3, and a pack alone never
reaches P2 — the two bars are independent and both required.

The exact evidence strings are published in `pmi.inputs.proven_loop_evidence`, so
a `P3` badge always expands to the pack, version, revision count and file path
that earned it.

**Caption:** `pmi_policy.display_cap` is `P3` and `cap_reason` states the gate.
When git could not be read, `cap_reason` is extended with *"git history
unavailable in this projection, so only the promotion path was evaluable"* and
`pmi_policy.history_available` is `false` — the renderer prints whichever caption
the data carries, so the Phase 0 wording (*"P3 needs version/promotion history
(Phase 1)"*) is gone the moment P3 became real.

## Critic pairing (SYNTHESIS §5.1, Phase 1)

Phase 0 counted trails whose **role name** contained `critic`. Phase 1 pairs by
**branch**: a branch that carries at least one non-critic trail and at least one
critic trail is a pair. Both sides record it (`reviewed_by` / `reviews`), and the
pairs are published in `critic_pairs[]`.

```text
critic_rate = paired_producer_trails / producer_trails      # method: branch_pairing
```

**Fallback (documented):** when no branch pairs at all — no critic seat ran, or
critics worked on their own branches — `critic_rate` reverts to the Phase 0
definition (`critic_trails / trails`) and `fleet.critic_rate_method` is
`role_name_fallback`. `fleet.critic_rate_basis` always publishes the raw counts
(`pairs`, `producer_trails`, `paired_producer_trails`, `critic_trails`,
`unpaired_critic_trails`, `trails_without_branch`) so the number is never a bare
percentage. Role identification is still name-based (`critic` in the role name) —
that is the only signal handoffs carry.

## `gh` enrichment (optional, never fatal)

When `gh` is installed **and** authenticated **and** the projected repo is the
git work-tree root, the build makes at most four calls
(`gh auth status`, `gh repo view`, `gh pr list`, `gh issue list`, `--limit 200`,
per-call timeouts) and attaches `pr_url` / `pr_state` / `pr_number` for trails
whose branch matches a PR head ref, plus `issue_links_resolved`.

Rules:

- **Never fails the build.** Missing binary, missing auth, timeout, non-zero exit
  or unparseable JSON all degrade to empty fields plus `gh_enrichment.status`
  (`ok` · `skipped` · `disabled` · `unavailable` · `unauthenticated` · `error` ·
  `bad_payload`) and a `reason`. `bad_payload` covers exit-0 responses that are
  not the expected shape (a non-`owner/repo` slug, or a list call that did not
  return a JSON array) — exit 0 is never reported as `ok` with garbage.
  Non-ok, non-skipped statuses also append a `warnings[]` line.
- Fields **always exist** on every trail (empty when the enrichment did not run),
  so a page never has to guess why they are missing.
- **Titles only** — no issue/PR bodies, no comments, no reviews. Titles pass the
  same redactor and are capped at 120 chars.
- A bare `#123` reference is only resolved when the trail's branch matched a PR
  in this repo; trails dispatched into a product repo keep the raw ref rather
  than pointing at an unrelated `dev-agents` issue. Full URLs resolve only when
  the slug matches.
- Turn it off with `--no-gh` or `FLEET_DESK_NO_GH=1` (status `disabled`).

## Snapshot (optional, shareable)

```bash
make experience-snapshot          # → docs/experience/snapshot/summary.json + README.md
python3 scripts/experience_data.py --snapshot-dir /tmp/snap
```

`summary.json` is a rollup of the contract: counts, fleet metrics, PMI bands +
reasons, critic pairs, waves, skill versions/revisions, learning statuses and
one-line trail rows (`handoff_summary`). Every free-text body is dropped —
no handoff markdown/sections, no skill or learning bodies, no `git_history`
blobs, and everything that remains already passed the redactor. Measured size:
**~25 KiB** for this repo (19 trails), 20 KiB for the fixture (27 trails) — small
enough to commit, but whether to commit it is an owner call (SYNTHESIS §10). The
snapshot is *not* written by `make experience`; `site/experience/` itself stays
gitignored.

## Redaction

Before any handoff/learning/skill text enters the JSON it passes a redactor that
replaces token shapes (`ghp_…`, `github_pat_…`, `sk-…`, `xox…`, `AKIA…`, JWTs,
`Bearer …`, PEM private keys) and `key: value` credential assignments with
`[redacted…]`. Absolute operator paths are rewritten repo-relative or `~/`-relative.
`tests/run-experience-tests.sh` fails the build if secret shapes or home paths
appear in the JSON or HTML.

## Live event stream (Phase B) — `logs/fleet-events/*.jsonl`

The Almanac contract above is **settled history**. Live motion is a separate,
append-only stream so live state never enters `index.json`
([SYNTHESIS §3 Phase B](proposals/fleet-desk-v2-SYNTHESIS.md)).

```text
scripts/dispatch.sh ──► logs/fleet-events/<dispatch_id>.jsonl  (schema fleet-events/1)
                        logs/fleet-events/latest               (pointer: basename)
                                   │
                        scripts/desk_live.py  (make desk-live)
                                   ▼
                        site/experience/data/live.json          (schema live/1)
```

| Piece | File |
|-------|------|
| Writer | `scripts/fleet-events.sh` (sourced by `scripts/dispatch.sh`) |
| Reader / projector | `scripts/desk_live.py` (`make desk-live`, `make desk-live-once`) |
| Tests | `tests/run-desk-live-tests.sh`, fixtures in `tests/fixtures/fleet-events/` |

`logs/fleet-events/` is gitignored — it is per-machine runtime truth, rebuilt by
the next dispatch.

### Event envelope (`fleet-events/1`)

One JSON object per line, appended, never rewritten. Every line carries:

| Key | Type | Meaning |
|-----|------|---------|
| `schema` | string | `fleet-events/1` |
| `seq` | int | 1-based, monotonic within one dispatch |
| `ts` | string | UTC ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` |
| `dispatch_id` | string | `<UTC timestamp>-<repo slug>`, also the filename stem |
| `event` | string | Event type (below) |

### Event types

| `event` | Emitted when | Payload beyond the envelope |
|---------|--------------|-----------------------------|
| `dispatch_start` | run opens | `mode` (`wave`\|`conductor`), `repo`, `plan` (**basename only**) |
| `dispatch_plan` | right after start | `waves`, `seats`, `format` |
| `wave_start` | a wave begins | `wave`, `seats`, `mode` |
| `seat_dispatch` | a seat goes out (first try or retry) | `task_id`, `agent`, `branch`, `wave`, `provider`, `model`, `worker`, `attempt` |
| `seat_exit` | a seat finishes | `task_id`, `agent`, `branch`, `wave`, `provider`, `worker`, `status`, `exit`, `duration_s`, `attempt`, optional `reason` |
| `ratecap` | vendor returned exit 75 | `task_id`, `agent`, `wave`, `provider`, `worker`, `cooldown_minutes` |
| `failover` | a retry landed on a different vendor | `task_id`, `agent`, `branch`, `from_provider`, `to_provider`, `attempt` |
| `human_wait` | dispatcher blocks on the operator | `kind` (`wave_gate`\|`failure_gate`), `wave`, `next_wave`, `waiting_on` (short label) |
| `human_resume` | the operator answered | `kind`, `wave`, `answer` (`continue`\|`abort`) |
| `wave_end` | a wave closes | `wave`, `seats`, `succeeded`, `failed` |
| `seat_log` | log collected | `task_id`, `agent`, `log` (**filename only**) |
| `dispatch_end` | run closes (also on Ctrl-C, via trap) | `status` (`completed`\|`aborted`), `total`, `succeeded`, `failed`, `duration_s` |

`seat_exit.status` ∈ `success` · `failed` · `blocked` (guardrails, exit 77) ·
`ratecap` (exit 75) · `unavailable` (exit 69).

### Redaction law (writer-enforced)

* **No transcript bodies, prompts, task descriptions, or handoff prose.** The
  dispatcher never passes `TASK_DESC` to an event; `tests/run-desk-live-tests.sh`
  greps for that regression.
* Plans and logs travel as **basenames**, never absolute paths.
* Values are control-char stripped, newline-flattened, and truncated to 200
  chars; keys must be `lower_snake` or they are dropped; empty values are
  omitted instead of being emitted as `""`.
* Numbers (`exit`, `wave`, `duration_s`, `attempt`, counts) are JSON numbers;
  `task_id` stays a string so a branch or id that looks numeric never changes type.

### Opt-out and overrides

| Variable | Effect |
|----------|--------|
| `FLEET_EVENTS=0` | writes nothing at all (dispatch behaves exactly as before) |
| `FLEET_EVENTS_DIR=/path` | write the stream somewhere else (default `logs/fleet-events`) |

### Follow bridge (orchestrator / long shell)

`scripts/fleet-session.sh` opens a short stream (mode `session` → Floor wave lanes)
with one `orchestrator` seat, optional `progress` heartbeats, and a clean
`dispatch_end`. Same redaction law as dispatch. Use so autopilot is visible on
`make desk-follow` without a multi-seat plan:

```bash
./scripts/fleet-session.sh run --label my-run --repo dev-agents -- make test
```

Unknown event names (e.g. `progress`) still advance `last_event_ts` and appear in
`recent_events` — they do not invent seats.

When `status=running` and no event has arrived for `quiet_after_s` (default 90),
the projection adds `waiting_on[]` entry `kind=quiet_stream` so the Floor can
show **QUIET** instead of a silent green live run.

An unwritable directory disables the stream with a warning — a dispatch is never
failed by its own telemetry.

### Projection (`live/1`) — `site/experience/data/live.json`

`scripts/desk_live.py` folds the stream (resolved via `--dispatch-id`, else the
`latest` pointer, else the newest `*.jsonl`) into:

| Key | Type | Meaning |
|-----|------|---------|
| `schema` | string | `live/1` |
| `generated_at` | string | UTC build time |
| `dispatch_id` / `source` | string | run id and the repo-relative stream path |
| `repo` / `plan` | string | from `dispatch_start` |
| `mode` | string | `wave` (parallel lanes) or `conductor` (serial spine) |
| `status` | string | `idle` · `running` · `settled` · `aborted` |
| `reason` | string | why it is idle (teaches the next command) |
| `wave` | object | `{current, total}` |
| `seats[]` | array | one per `task_id`: `agent`, `branch`, `wave`, `provider`, `worker`, `model`, `status`, `pipeline`, `exit`, `attempt`, `started_at`, `ended_at`, `duration_s`, `elapsed_s` (running), `providers_tried[]`, `failovers[]`, `ratecapped`, `log` |
| `counts` | object | pipeline counts: `queued`, `in_flight`, `blocked`, `settled`, `total` |
| `waiting_on[]` | array | first-class strip: open human gates, then rate-capped seats, else the longest-running seat. Each entry has `kind` (`human_gate`\|`ratecap`\|`seat`), `label`, `since` |
| `last_event_ts` | string | newest event timestamp seen |
| `staleness` | object | `{seconds, state, stale_after_s: 120, offline_after_s: 900}`; `state` ∈ `live` · `stale` · `offline` · `none` · **`replay`** (Phase C) |
| `events_seen` | int | lines folded |
| `recent_events[]` | array | last 50 raw events (already redaction-safe) |
| `warnings[]` | array | malformed lines, unknown event schema |
| `view` | string | **`live`** (default) or **`replay`** (Phase C scrub) |
| `replay` | object\|null | Phase C: `{as_of_seq, total_events, max_seq, watermark: "REPLAY", settled_run}` when `view=replay` |

Honesty rules the projector enforces:

* a seat still marked `running` after `dispatch_end` becomes **`unknown`**, never
  an eternal spinner;
* an old stream reads `stale` then `offline` — never `live`;
* an empty events dir projects `idle` with a reason, not an empty "running" desk;
* malformed lines are skipped and counted in `warnings`, never guessed at;
* **Phase C:** when `view=replay` (or `--as-of-seq` / `--replay`), `staleness.state`
  is forced to **`replay`** and `replay.watermark` is **`REPLAY`** — never a green LIVE LED.

### Phase C — replay API

| Route / flag | Meaning |
|--------------|---------|
| `GET /api/runs` | catalog of `logs/fleet-events/*.jsonl` (`schema: fleet-runs/1`) |
| `GET /api/replay?dispatch_id=&as_of_seq=` | `live/1` projection truncated at seq, always `view=replay` |
| `--as-of-seq N` | keep only events with `seq <= N` (implies replay view) |
| `--replay` | force replay watermark on the full (or truncated) stream |
| `--list-runs` | print the run catalog to stdout |

### Running it

```bash
make desk-live                     # watch + serve http://127.0.0.1:8777/live/ (SSE at /events)
make desk-live PORT=9000           # different port
make desk-live-once                # write live.json once, no server (file:// desks)
python3 scripts/desk_live.py --watch          # rewrite live.json on a timer, no server
python3 scripts/desk_live.py --once --dispatch-id 20260729-100000-dev-agents --print
python3 scripts/desk_live.py --once --dispatch-id ID --as-of-seq 4 --replay
python3 scripts/desk_live.py --list-runs
```

The server binds loopback only, serves `site/experience/`, and adds routes:
`/live.json` (always fresh), `/events` (SSE), **`/api/runs`**, **`/api/replay`**.
Pages that cannot use SSE poll `data/live.json`; `file://` desks use `--watch` /
`--once` (scrubber UI needs HTTP for the replay API).

## Migration v1 → v2

`schema_version` went to `2` because two published keys changed meaning or name.
The renderer refuses any version it does not know, so both steps ship together.

| Change | v1 | v2 | Consumer action |
|--------|----|----|-----------------|
| PMI cap key | `pmi_policy.phase0_cap` = `"P2"` | `pmi_policy.display_cap` = `"P3"` | **rename** (removed, not aliased) |
| PMI band range | `P0…P2` | `P0…P3` | allow `P3`; add a `band-p3` style |
| `fleet.critic_rate` | share of trails whose role name contains `critic` | share of **producer trails reviewed on the same branch** | read `critic_rate_method` before comparing to historical numbers |
| `phase` | `0` | `1` | captions that hard-coded "Phase 0" must read the field |

Everything else is additive: `counts.critic_pairs`, `critic_pairs[]`,
`skill_history`, `gh_enrichment`, the new `skills[]`, `trails[]` and `role_stats`
fields. A v1 consumer that ignores unknown keys only needs the four rows above.

## Changing the schema

1. Add fields additively when possible; keep `schema_version` at 2.
2. On a breaking change: bump `SCHEMA_VERSION` in `scripts/experience_data.py`,
   add a migration table row here, and update `tests/run-experience-tests.sh`.
3. The renderer exits non-zero on an unknown `schema_version` rather than drawing
   a half-correct page.

## Fixture

`tests/fixtures/experience-mini/` is a synthetic repo covering every join method,
every wave source, all PMI bands (including a `P2` role that must **not** drift to
`P3`), a producer↔critic branch pair, an unpaired critic, and secret redaction.
Build it directly:

```bash
python3 scripts/experience_data.py  --repo tests/fixtures/experience-mini --out /tmp/fd --no-gh
python3 scripts/experience_build.py --repo tests/fixtures/experience-mini --out /tmp/fd
```

Git-dependent behavior is **not** faked in the fixture:
`tests/run-experience-tests.sh` copies it into a throwaway `git init` repo and
makes real commits to prove the revision path to `P3`, and into a non-git
directory to prove the honest degradation.
