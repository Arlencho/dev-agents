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

The live projector (`scripts/desk_live.py`) runs a second enrichment under the
same rules for the Ops Floor: one issue milestone per plan and one PR per
branch (see [Repo, issue, task line and PR](#repo-issue-task-line-and-pr-issue-72)),
and for Floor v3 the critic verdicts on the PRs in play, the repository
variable names, the open milestones and the newest merged PRs (see
[NEEDS YOU, INITIATIVES and blocked queue entries](#needs-you-initiatives-and-blocked-queue-entries-floor-v3-wave-a)).
Comment and issue bodies are read in-process to find a verdict or an exit
criterion sentence and are never published.

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
| `seq` | int | 1-based, monotonic **per writer**. The dispatcher numbers its own spine in process; a seat reader (`seat_progress`) appends from a separate process, so the two counters share no space and a number can repeat. File order is the true order; the replay scrub cuts the spine on `seq` and the reader's lines on `ts` |
| `ts` | string | UTC ISO-8601 `YYYY-MM-DDTHH:MM:SSZ` |
| `dispatch_id` | string | `<UTC timestamp>-<repo slug>-<dispatcher pid>`, also the filename stem; the pid keeps two dispatches started in the same second apart |
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
| `seat_progress` | the seat's live stream moved (see below) | `task_id`, `agent`, `tool`, `path` (**repo-relative, or the literal `outside-repo`**), `program` (**program name of the last shell command, never its arguments**), `files_edited`, `commands_run`, `tests_run`, `commits_made`, `phase` |
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

Unknown event names (e.g. `progress`, `seat_heartbeat`) still advance
`last_event_ts` and appear in `recent_events` — they do not invent seats.

### Seat heartbeats (follow live while agents work)

`scripts/dispatch.sh` emits **`seat_heartbeat`** for every still-running seat
while waiting on a wave (default every **45s**, env `FLEET_HEARTBEAT_S`; set
`0` to disable). That keeps Ops Floor `last_event_ts` fresh so a healthy long
seat does **not** flip to STALE/QUIET solely because of event silence between
`seat_dispatch` and `seat_exit`.

If STALE/QUIET still appears **with** heartbeats, the stream truly stopped
(agent dead, emitter disabled, or heartbeats off) — not “task too hard.”

When `status=running` and no event has arrived for `quiet_after_s` (default 90),
the projection adds `waiting_on[]` entry `kind=quiet_stream` so the Floor can
show **QUIET** instead of a silent green live run.

An unwritable directory disables the stream with a warning — a dispatch is never
failed by its own telemetry.

### Seat activity (`seat_progress`, what the seat is doing right now)

Heartbeats prove a seat is **alive**. `seat_progress` says what it is **doing**.

| Piece | File |
|-------|------|
| Writer | `scripts/seat-progress.py` (a pass-through filter on the agent stream) |
| Wiring | `providers/lib.sh` `run_and_classify` (`AGENT_STREAM_READER`), env from `scripts/run-remote.sh` |
| Emitter | `scripts/fleet-events.sh emit seat_progress` (the same writer as every other event) |

The launcher runs the vendor CLI in print mode with a streamed JSON output, so
the stream arrives line by line instead of in one block at the end. The reader
sits between the CLI and the `tee`, writes every byte through unchanged (the
agent log is exactly what the CLI printed), and folds the stream into counts.
`PIPESTATUS[0]` still belongs to the CLI, so exit codes and rate-cap
classification are untouched.

| Key | Type | Meaning |
|-----|------|---------|
| `task_id` / `agent` | string | which seat this belongs to (matches `seat_dispatch`) |
| `tool` | string | tool name only, e.g. `Read`, `Edit`, `Bash` |
| `path` | string | repo-relative path when the tool targets a file; anything resolving outside the repo becomes the literal **`outside-repo`** |
| `files_edited` | int | distinct paths written so far |
| `commands_run` | int | commands run so far |
| `tests_run` | int | commands that ran a test suite so far |
| `commits_made` | int | commands that made a commit so far |
| `phase` | string | `reading` · `reviewing` · `editing` · `testing` · `committing` |
| `program` | string | **Program name of the last shell command** the seat ran: its first token only (see the reduction below). Omitted while the seat has run no command, and omitted again when the command reduces to nothing publishable |

`phase` is derived from the counts alone, as a monotone ladder (commits, else
tests, else edits, else commands, else nothing yet). It says how far the seat
has got, not what its last keystroke was.

#### Program name (the only thing a command line contributes)

A devops seat spends most of its life in `Bash`, so `tool` alone reads as
nothing. `program` is the **program name of the last shell command**, so the
Floor can say *"testing (make)"* instead of *"Bash"*. It is reduced in the
reader, in this order, and a command that survives none of it publishes nothing:

| Command | `program` | Rule |
|---------|-----------|------|
| `make test` | `make` | first token only, never an argument |
| `FOO=bar BAZ=1 make test` | `make` | leading env assignments are dropped, **values included** |
| `sudo nohup time systemctl restart nginx` | `systemctl` | the wrappers `sudo`, `nohup`, `time` are dropped when they lead |
| `/usr/local/bin/python3 -m pytest` | `python3` | a token that looks like a path is reduced to its **basename**, so no directory leaves the reader, inside the repo or outside it |
| `./scripts/deploy.sh --prod` | `deploy.sh` | same rule, same basename |
| `sudo -u deploy ./x.sh` | *(omitted)* | an option is not a program name; the reader says nothing rather than publishing an argument |
| `echo 'unbalanced` | *(omitted)* | unparseable quoting is not tokenised on a guess |
| `sudo ~/.ssh/ghp_<token>` | `redacted` | a basename shaped like a credential is replaced by the literal word `redacted` **before it is written**, whole, never a truncated prefix. Same shapes as the Almanac scrub (`scripts/experience_data.py`): `ghp_`/`github_pat_`, `sk-`, `xox?-`, `AKIA`, a JWT. The Floor learns that a command ran, never which |
| `A=1 B=2 C=3 D=4 E=5 F=6 G=7 H=8 make` | *(omitted)* | the reader inspects at most the first **eight** tokens (assignments and wrappers included); a program buried deeper publishes nothing rather than a guess |

The name is **sticky per seat**: it describes the last shell command, so it
survives the reads and edits that follow, and a later command replaces it even
when that command reduces to nothing. Published names are one bare word of at
most 40 chars (`[A-Za-z0-9][A-Za-z0-9._+-]*`); `desk_live.py` re-applies that
shape, so a hand-written stream line cannot put a path on the page either.

**Cadence:** one event on **every tool call**, plus **at most one event per 15
seconds** (`SEAT_PROGRESS_INTERVAL_S`) while the stream moves without tool
calls, plus one closing event at end of stream.

**Redaction (writer-enforced, do not weaken):** prompts, task bodies, message
text, thinking, tool argument values and command lines **never** leave the
reader. Command lines are inspected in-process only, to tell a test run from a
commit from any other command, and are never emitted, not even truncated.
Absolute paths never leave it either; `desk_live.py` refuses to trust that
twice and re-marks any absolute or escaping path as `outside-repo`.

**Scope:** the env that turns emitting on is passed for a **local worker** only,
because the stream file lives on the dispatcher. On a true remote host the
reader degrades to a plain pass-through: the agent log is unchanged and no
progress events appear. Every other failure mode (no `python3`, missing reader,
unwritable stream) degrades the same way.

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
| `seats[]` | array | one per `task_id`: `agent`, `branch`, `wave`, `provider`, `worker`, `model`, `status`, `pipeline`, `exit`, `attempt`, `started_at`, `ended_at`, `duration_s`, `elapsed_s` (running), `providers_tried[]`, `failovers[]`, `ratecapped`, `log`, `activity` (newest `seat_progress`: `{ts, phase, tool, path, program, files_edited, commands_run, tests_run, commits_made}`, else `null`), `now` (one sentence worth of facts for a **running** seat, else `null`; see below) |
| `counts` | object | pipeline counts: `queued`, `in_flight`, `blocked`, `settled`, `total` |
| `summary` | object | The Floor's top line in plain counts: `running`, `queued`, `landed_today`, plus `last_event_ts`. **`null` on a replay** (see below) |
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
* a seat still marked `running` on a stream that has gone `offline` (no event
  for `offline_after_s`, no `dispatch_end`) becomes **`unknown`** the same way,
  in the live view: a crashed wave is not a running seat. A replay keeps the
  stream's own word, because the past has no "now";
* an old stream reads `stale` then `offline` — never `live`;
* an empty events dir projects `idle` with a reason, not an empty "running" desk;
* malformed lines are skipped and counted in `warnings`, never guessed at;
* **Phase C:** when `view=replay` (or `--as-of-seq` / `--replay`), `staleness.state`
  is forced to **`replay`** and `replay.watermark` is **`REPLAY`** — never a green LIVE LED.

### Ops Floor queue (`logs/fleet-queue.json`, schema `fleet-queue/1`)

The event stream says what **ran**. The queue says what the orchestrator
**declared** should run next, in which order, and why. They are different kinds
of truth and are stored separately: the stream is per-machine runtime (gitignored),
the queue is intent and is **tracked in git** so the order survives a machine.

```text
scripts/queue.sh  ──►  logs/fleet-queue.json   (schema fleet-queue/1)
scripts/dispatch.sh ─┘         │                start / settle, best effort
                               ▼
                     scripts/desk_live.py  ──► live.json: queue[] + today[]
```

| Piece | File |
|-------|------|
| Store + CLI | `scripts/queue.sh` (`make queue-add`, `make queue-list`, `make queue-rm`) |
| Writer (machine) | `scripts/dispatch.sh` at `dispatch_start` / `dispatch_end` |
| Reader / projector | `scripts/desk_live.py` |
| Tests | `tests/run-desk-live-tests.sh` Part F |

#### Document

```json
{
  "schema": "fleet-queue/1",
  "updated_at": "2026-09-12T15:40:00Z",
  "entries": [
    {
      "plan": "wave-plans/assistant-channel/2026-09-12-w2b-read-tools.plan",
      "repo": "olympus-platform",
      "purpose": "Assistant Channel W2-B: the six read tools and the cost quota. Issue 2800.",
      "issue": 2800,
      "added_at": "2026-09-12T15:40:00Z",
      "status": "queued",
      "dispatch_id": null,
      "settled_at": null,
      "settled_status": null
    }
  ]
}
```

| Field | Notes |
|-------|-------|
| `plan` | Plan path **relative to the repo**; an absolute path inside the repo is rewritten, one outside keeps its basename |
| `repo` | Target repo slug the plan dispatches into (`olympus-platform`), not the plan's own repo |
| `purpose` | One line the orchestrator writes. Defaults to the **first comment line of the plan file**; never a task body |
| `issue` | int or `null`. Written at `add` and `start`: the number the plan header names (pattern `Issue NNNN`, the same parse the Floor uses), `null` when no header line names one. Stored so a plan that is gone from disk still names its requirement; a reader falls back to parsing `purpose` only for entries written before this field existed |
| `added_at` | UTC ISO-8601, when the entry was declared. The newest one stamps the Floor block |
| `status` | `queued` · `running` · `settled` |
| `dispatch_id` | Set when a dispatch claims the plan; matches the event-stream id |
| `settled_at`, `settled_status` | Written at `dispatch_end` (`completed` · `aborted`) |
| `blocked` | Optional. A reason set by `queue.sh block <plan> <reason>` (the queue runner sets it when a plan cannot start, an operator can too); `queue.sh unblock` clears it. The projection shows it as `queue[].blocked` and the runner skips the plan while it is set |
| `waiting` | Why the runner is not starting the plan yet: its `# AFTER:` header names a plan that has not landed. Written and cleared by the runner itself (`queue.sh wait`) |

Top level, beside `entries`: `hold` is the queue-wide reason nothing starts
(the runner's memory guard writes it with `queue.sh hold` and clears it with
`queue.sh release`); empty or absent when starts are free.

`entries` is **ordered**: position 1 is next. Order is intent, never motion.

#### Commands

```bash
./scripts/queue.sh add <plan> <repo> [purpose]   # append (purpose defaults to the plan header)
./scripts/queue.sh rm <plan>                     # drop
./scripts/queue.sh mv <plan> <position>          # reorder (1-based)
./scripts/queue.sh start <plan> [dispatch_id]    # mark running (dispatch.sh calls this)
./scripts/queue.sh settle <plan> [status]        # mark settled (dispatch.sh calls this)
./scripts/queue.sh block <plan> <reason>         # hold a plan back; the runner skips it
./scripts/queue.sh unblock <plan>
./scripts/queue.sh wait <plan> [reason]          # AFTER bookkeeping (the runner calls this)
./scripts/queue.sh hold <reason>                 # queue-wide hold (the memory guard calls this)
./scripts/queue.sh release
./scripts/queue.sh list                          # print the order
make queue-add PLAN=wave-plans/x.plan REPO=olympus-platform PURPOSE="one line"
make queue-list
make queue-rm PLAN=wave-plans/x.plan
```

Every subcommand prints the resulting order. A plan is matched by repo-relative
path first, then by basename, so the same entry is reachable from any spelling.

#### Rules

* **Append-safe.** Every write lands in a temp file in the same directory, is
  fsynced, then renamed over the queue: a reader never sees a half file and an
  interrupted write never loses an entry. Concurrent writers take an exclusive
  lock on `<queue>.lock` (5s timeout), so two dispatches cannot clobber each
  other (the suite proves 8 parallel adds keep 8 entries).
* **Never destructive on bad input.** A malformed or off-schema queue is refused
  with a non-zero exit and left byte-for-byte untouched.
* **Machine-maintained.** `dispatch.sh` marks the plan `running` with the
  dispatch id at `dispatch_start` (appending it as `running` when it was never
  armed) and `settled` at `dispatch_end`, aborted runs included. Both calls are
  best effort: a missing `queue.sh`, an unwritable `logs/`, a busy lock or a
  missing `python3` are swallowed. **A dispatch is never blocked by its queue.**
* **Same redaction law as the stream.** Purposes come from the plan header only.
  No task description, prompt or handoff prose ever enters the queue.
* Opt-out: `FLEET_QUEUE=0` silences every write. Override the path with
  `FLEET_QUEUE_FILE=/path` (or `--queue-file` on `desk_live.py`).

### Queue + day fields in the projection (`live/1`)

`desk_live.py` folds the queue and the whole local day into the same
`live.json`. These keys always exist, so a page never has to guess why they are
missing.

| Key | Type | Meaning |
|-----|------|---------|
| `queue[]` | array | Entries with status `queued`, **in declared order**: `position`, `plan`, `plan_basename`, `repo`, `purpose`, `added_at`, `status` (always `queued`), `blocked` (reason or `null`), `waiting` (the runner's AFTER reason or `null`) |
| `queue_meta` | object | `{source, declared, declared_at, total, queued, running, settled, hold}`. `declared_at` is the `added_at` of the **newest** entry and stamps the Floor block; `hold` is the runner's queue-wide reason nothing starts (memory guard), else `null` |
| `stops[]` | array | The queue runner's **open** stops, newest first, from `logs/fleet-stops.jsonl` (see below): `key`, `kind`, `at`, `repo`, `plan` (basename), `dispatch_id`, `pr`, `pr_url`, `branch`, `verdict`, `sentence`, `action`. `[]` on a replay |
| `stops_meta` | object | `{source, open, total}`: the file (repo-relative), how many keys are open, how many keys the file holds |
| `today[]` | array | One entry per dispatch whose **`dispatch_end` falls on the local calendar day**: `dispatch_id`, `source`, `plan`, `plan_basename`, `repo`, `purpose` (+ `purpose_source`: `queue` or `none`), `status` (`settled` · `aborted`, kept for compatibility), `outcome` (`landed` · `failed` · `aborted`, see below), `end_status`, `duration_s`, `started_at`, `ended_at`, `seats`, `succeeded`, `failed`, `branches[]` |
| `today_meta` | object | `{date, streams_read, live[], ended}`: the local day, how many streams were read, which dispatch ids are still live (no `dispatch_end` yet, started on this local date or the one before) |
| `multi_dispatch` | object | Present only when a second dispatch is live on the day: `{live[], followed, merged_seats}` |
| `seats[].dispatch_id` | string | Which run a seat belongs to |
| `seats[].foreign` | bool | `true` when the seat comes from a live dispatch other than the followed one |

`today[].outcome` is the word the page prints for a finished run. `status`
only mirrors the close-out (`settled` for `completed`, else the close-out
status as written), and `dispatch.sh` writes `aborted` from its exit trap
whenever it does not reach the normal close-out, so `status` alone cannot tell
an operator's Ctrl-C from a run that died by itself after a seat failed. The
seat exits can, so `outcome` is derived from both (a seat's **last**
`seat_exit` counts, so a retry overrides):

* `landed`: the close-out is `completed`, every seat's last `seat_exit` is
  `success`, and the dispatcher counted no failure;
* `failed`: at least one seat's last `seat_exit` is not `success` and every
  dispatched seat has exited, so the run ended by itself. A `completed`
  close-out with a failure counted is `failed` too;
* `aborted`: anything else: the dispatcher was stopped while a seat was still
  in flight, or before the normal close-out with nothing having failed.


### Runner stops (`logs/fleet-stops.jsonl`, schema `fleet-stops/1`)

What the queue runner (`scripts/queue-runner.sh`, `scripts/queue_loop.py`)
refused to do by itself, so a person can. Append-only JSONL, per machine,
gitignored. One line per stop, one per clearance, folded by `key`: the newest
line for a key decides, and only keys whose newest `state` is `open` reach the
Floor. `make stops-list` prints them.

```json
{"schema":"fleet-stops/1","ts":"2026-09-13T14:02:11Z","key":"20260913-134500-product-1234","state":"open",
 "kind":"second_block","repo":"product","plan":"w2b-fix1.plan","dispatch_id":"20260913-134500-product-1234",
 "pr":2841,"pr_url":"https://github.com/you/repo/pull/2841","branch":"feat/w2b","verdict":"BLOCK-FIX",
 "sentence":"CRITIC W2B ROUND 2: BLOCK-FIX","action":"open the comment; the runner fired its one fix round"}
{"schema":"fleet-stops/1","ts":"2026-09-13T15:10:00Z","key":"20260913-134500-product-1234","state":"cleared","reason":"PR #2841 is merged"}
```

| Field | Notes |
|-------|-------|
| `key` | The dispatch id the stop belongs to; `memory-guard` for the guard |
| `state` | `open` · `cleared` |
| `kind` | `guard` · `second_block` · `escalate` · `close` · `unparsed` · `critic_silent` · `red_checks` · `not_clean` · `merge_refused` · `no_pr` · `pr_closed` · `no_producer` |
| `sentence` | The critic's verdict line **as parsed** (heading, round, verdict: `CRITIC W2B ROUND 2: BLOCK-FIX`), or the runner's own one-line reason. Never the raw first line, **never the body**. Every text field of a record goes through the task-line law of `seats[].task_line` (`desk_live.first_sentence`): first sentence only, a slash token outside this worktree reads `outside-repo`, secret shapes redacted, capped at 200 |
| `action` | One action per kind, the words the NEEDS YOU row ends with |
| `plan` | Basename only. No absolute path ever enters the file, in this or any other field |

Clearance is automatic: the guard's stop clears when memory recovers; a
dispatch stop clears when its PR merges or closes (one `gh pr view` per open
stop per tick, at most ten) or when its plan is removed from the queue.

### The now view (`seats[]` additions + `plan_context`)

The Floor answers "what is this seat doing, and for how long" from data the
stream and the plan file already carry. The stream travels with a plan
**basename** only, so `desk_live.py` resolves that basename to the plan file on
disk (queue entry first, then a walk of `wave-plans/`) and reads three things
from it: the header, the seat's own line, the wave count.

| Key | Type | Meaning |
|-----|------|---------|
| `plan_context` | object | `{plan, purpose, waves, seats}` for the followed run |
| `seats[].plan_purpose` | string | First **prose** comment line of the seat's plan header. A machine directive (`DISPATCH:`, `Law:`, `Schema:`, `Protocol:`, `Usage:`, `Ref:`/`Refs:`, `Generated by`) is skipped, the same rule as `now.purpose` and `scripts/queue.sh` |
| `seats[].task` | string | **First sentence** of that seat's line in the plan, cut at 120 chars. Never the whole task body |
| `seats[].wave_total` | int | Wave count of the plan, so a seat reads "wave 2 of 3" |
| `seats[].attempt` | int | Attempt number from `seat_dispatch` |
| `seats[].started_at` | string | `seat_dispatch` timestamp; the browser ticks elapsed from it every second |
| `seats[].last_heartbeat_ts` | string | Newest `seat_heartbeat` for that seat, `null` when none arrived |
| `seats[].heartbeat_age_s` | int | Seconds since the last sign of life (heartbeat, else `seat_dispatch`) |
| `seats[].quiet` | bool | `true` when a **running** seat has had no sign of life for `quiet_after_s` (90) |

Rules:

* the plan is joined to seats by **branch** first, then seat index, then agent;
  a seat the plan cannot explain keeps its stream facts and says so on the page
  rather than showing a guessed task;
* a plan that is not on this machine yields `plan_purpose: null` and
  `task: null`, never an invented line;
* `seat_heartbeat` updates liveness but **never creates a seat**;
* published task text passes the same secret scrub as the Almanac and is a
  single line;
* `quiet` uses the same threshold as the `quiet_stream` entry in `waiting_on`,
  and the Floor marks it in the REPLAY watermark language (violet badge), never
  as a green live seat.

Rules the projector enforces:

* the day view reads **every stream file of the day**, not only the newest, so
  concurrent dispatches all appear (files are mtime-prefiltered to a 48h window
  and summaries are cached by mtime and size);
* the single-dispatch follow is unchanged: the resolved stream still owns
  `status`, `wave`, `waiting_on` and the event tail. When more than one dispatch
  is live, the other seats are **appended** and labelled `foreign`, never merged
  into the followed run's identity;
* a queued plan is only ever `queued`, so the Floor cannot claim it is running;
* a malformed queue degrades to an empty `queue[]` plus a `warnings[]` line;
* **replay projections carry neither `queue[]` nor `today[]`**: a historical
  scrub must not borrow today's intent.

On the Floor: the **Queued** pipeline cell counts declared plans (with the file
named under it), **Up next** lists position, purpose, repo and plan basename with
the dashed "declared, not observed" treatment, and **Landed today** lists
purpose, status, duration and the branches created. `make experience` rebuilds
`data/`, so write the projection after it (`make desk-live-once`, or leave
`make desk-live` running and the page repaints itself).

### The plain sentence (`seats[].now`) and the top line (`summary`)

The Floor has to read like sentences, not like a schema (issue 69). A page
should not join three objects to write one line, so every fact one sentence
needs is projected in **one place per live seat**, and the four numbers of the
header in **one object**. Neither is new truth: both are folds of the stream,
the queue and the plan file documented above.

`seats[].now` is present for a seat whose `status` is `running`, and `null`
otherwise (a settled or `unknown` seat has no present tense):

| Key | Type | Meaning |
|-----|------|---------|
| `role` | string | The seat's role name (`agent`), the subject of the sentence |
| `phase` | string\|null | Phase word of the newest `seat_progress`, `null` before any arrived |
| `program` | string\|null | Program name of the seat's last shell command (reduction above), `null` when it ran none |
| `purpose` | string\|null | Why this run exists: the **queue entry's** purpose when the plan is armed, else the **plan header**, cut to its first sentence (≤ 120 chars). `null` when neither is on this machine |
| `purpose_source` | string | `queue` · `plan` · `none`: which of the two spoke, so the page never implies a purpose it invented |
| `wave` | int\|null | The seat's wave, from `seat_dispatch` |
| `wave_total` | int\|null | Wave count **of the plan file**, so the sentence reads "wave 2 of 3" |
| `elapsed_s` | int\|null | Seconds since `seat_dispatch` |
| `heartbeat_age_s` | int\|null | Seconds since the last sign of life (heartbeat, else `seat_dispatch`) |

`summary` is the header line, over the whole local day, not only the followed run:

| Key | Type | Meaning |
|-----|------|---------|
| `running` | int | Seats with `status: running`, **across every live dispatch** of the day (the followed run plus any `foreign` seats) |
| `queued` | int | Plans the queue declares `queued` (`queue_meta.queued`); intent, never motion |
| `landed_today` | int | Dispatches that ended on this local calendar day (`len(today)`), landed and aborted alike |
| `last_event_ts` | string\|null | Timestamp of the newest event (the same value as the top-level `last_event_ts`); `null` when no event has ever arrived. A timestamp, never a precomputed age: the page computes the age live from it, so the header ticks with the rest of the chrome and cannot disagree with the state note once the watcher is gone |

Rules the projector enforces:

* a seat that is not running carries `now: null`, because the sentence is present
  tense and is never written for a finished seat;
* every field of `now` is independently nullable, so the page drops that clause
  instead of printing a guess;
* the queue wins over the plan header for `purpose` (it is what the orchestrator
  declared for this run) and `purpose_source` always says which one was used;
* a plan header line that is a **machine directive** (`DISPATCH:`, `Law:`,
  `Schema:`, `Protocol:`, `Usage:`, `Ref:`/`Refs:`, `Generated by …`) or that
  carries no letters is never a purpose: the first prose comment wins. The same
  rule lives in `scripts/queue.sh`, so the queue and the Floor cannot disagree
  about why a run exists;
* `summary` counts only what the other blocks already publish, so the header can
  always be reconciled against them (`running` = running seats, `queued` =
  `len(queue)`, `landed_today` = `len(today)`);
* **a replay carries neither**: `summary` is `null` and every `now` is `null`,
  for the same reason replay carries no `queue[]` or `today[]`: a historical
  scrub must not borrow the present.

### Repo, issue, task line and PR (issue 72)

With two repos live at once the Floor has to say which repo a seat belongs to
and which requirement it serves. The projector follows **every dispatch still
in motion**: no `dispatch_end` yet and started on this local date or the one
before, so a run that crossed local midnight is still followed and counted (the
followed run plus every `foreign` one), and `repo` is a
first-class field on every seat, queue entry and landing. Three more facts ride
along: the issue the plan header names, the seat's one-line task, and the PR
for its branch. Only the milestone title and the PR number plus title come from
`gh`; everything else is read from the stream, the queue and the plan file.

| Key | Type | Meaning |
|-----|------|---------|
| `seats[].repo` | string | Repo of the dispatch the seat belongs to (`dispatch_start.repo`), on followed and `foreign` seats alike. Present on replay seats too |
| `seats[].issue` | object | The issue this seat's plan serves (shape below). Always present, on replay seats too |
| `seats[].task_line` | string\|null | **First sentence** of that seat's line in the plan file: cut at the first sentence end whatever its length, else at 120 chars. Passed through the same secret scrub as `now.program` plus the path law of `activity.path`: a slash token that is not a path inside this worktree (absolute, home, variable, parent escape, `file:` URL) reads `outside-repo`, and a path inside it is printed repo-relative. Never more of the task body. `null` when the plan is not on this machine. Present on replay seats too. (`seats[].task` keeps the same value for older readers). The seat's own line is found by seat, not by branch alone (issue 86): the stream's `task_id` is the plan line index (used when the branch agrees), then branch and wave together (a critic seat shares its producer's branch but sits in a later wave), then branch, then agent |
| `seats[].pr` | object | The open, else merged, PR for the seat's branch (shape below). Always present, on replay seats too |
| `queue[].repo` | string | Already first-class since #68; the first word of an UP NEXT row |
| `queue[].issue` | object | Same shape as `seats[].issue`. When the plan file is gone, the number comes from the `issue` field `scripts/queue.sh` stored at `add`/`start`, else from the stored header line (`purpose`) |
| `today[].repo` | string | Already first-class since #68; the first word of a LANDED TODAY row |
| `today[].pr` | object | The PR for the landing's branch: the first branch with a PR found, else the first branch's lookup, else a skipped record with reason `no branch` |
| `today[].prs[]` | array | One `pr` object per entry of `branches[]`, in the same order |
| `repos[]` | array | One counts object per repo seen today, sorted by `seats_live` then `dispatches_live` descending: `{repo, seats_live, dispatches_live, queued, landed_today, dispatch_ids[]}`. A repo the stream did not name is bucketed as `unknown`. **`[]` on a replay** (the past has no present), like `summary` |
| `gh_enrichment` | object | What the enrichment did for this projection: `{status, reason, owner, calls, cached, skipped}`. `status` is `ok` · `skipped` (nothing needed a lookup) · `disabled` · `unavailable` · `unauthenticated` · `error` |

`issue` object:

| Key | Type | Meaning |
|-----|------|---------|
| `number` | int\|null | Parsed from the plan header line that names it, pattern `Issue NNNN` (`Issue #NNNN` and any case accepted). `null` when no header line names one |
| `source` | string | `plan` (header on disk) · `queue` (the `issue` field or the header line `queue.sh` stored) · `none` |
| `milestone` | string\|null | Milestone title from `gh issue view`, capped at 120 chars and scrubbed. Only present when `lookup` is `verified` |
| `lookup` | string | `verified` when gh answered for this repo and issue, else `skipped` |
| `reason` | string\|null | Why it was skipped (`no plan header names an issue`, `disabled (...)`, `gh not on PATH`, `... timed out after 8.0s`, `... failed (exit 1)`, budget spent) |

`pr` object:

| Key | Type | Meaning |
|-----|------|---------|
| `branch` | string\|null | The branch asked about |
| `number` / `title` / `state` / `url` | mixed | From `gh pr list --head <branch>`: the **open** PR when one exists, else the **merged** one; closed-unmerged PRs are ignored. Title capped at 120 chars and scrubbed. All `null` when none |
| `lookup` | string | `verified` when gh answered (a verified absence is `verified` with `number: null` and reason `no open or merged PR for this branch`), else `skipped` |
| `reason` | string\|null | Why nothing is there |

Rules the projector enforces:

* the enrichment **never fails and never blocks the projection**: a missing
  `gh`, missing auth, a per-call timeout (`FLEET_GH_TIMEOUT_S`, default 8 s), a
  non-zero exit or a bad payload degrade to `lookup: skipped` with a reason, and
  `live.json` is written either way;
* one question per run: answers (and failures) are cached per projection and
  for 300 s across projections, so the watcher does not ask the same question
  every two seconds, and a projection spends at most 60 gh calls (the rest are
  skipped with a budget reason). An idle desk with nothing to look up makes no
  call at all;
* a repo name in the stream is a directory name, so the slug asked of gh is
  `<owner>/<repo>` with the owner from `FLEET_GH_OWNER`, else the owner of this
  repo's `origin` remote. A lookup is only `verified` when gh answered for that
  slug, so a wrong owner reads as skipped, never as a guess;
* the redaction law holds: `task_line` is the first sentence only, cut at 120
  and scrubbed, and it never carries a path outside the repo (such a token
  reads `outside-repo`); the enrichment adds
  only the issue number, the milestone title and the PR number plus title
  (never an issue or PR body, never a comment);
* honesty rules unchanged: a queued entry is still only `queued`, stale and
  offline still degrade every element, and a replay carries no `repos[]` and
  no `summary`, though its seats keep `repo`, `issue`, `task_line` and `pr`
  (the plan on disk explains a historical seat too; gh stays optional);
* turn the enrichment off with `--no-gh` or `FLEET_DESK_NO_GH=1`
  (`gh_enrichment.status: disabled`).

`scripts/queue.sh` stores `issue` on every entry at `add` and `start`: the
number the plan header names, else the number the declared purpose names, else
`null`. `queue.sh list` prints it as `#NNNN` beside the plan.

The Floor page (`templates/experience/floor.js`, mirrored by the build-time
snapshot in `scripts/experience_build.py`) reads these fields in the v3 order
([`floor-v3-purpose.md`](proposals/floor-v3-purpose.md) § 4): first the status
strip (running, up next, landed, failed, needs you, last event; every figure
links to its section, "needs you" is red when non-zero, the failed figure
counts aborted beside failed because the list it links to lists both, a
needs-you figure beside skipped checks names them so a zero never reads as
verified, and under stale or
offline the strip says so first in words, before any number); then NEEDS YOU
(newest first, one reachable action each: the source url when there is one,
else the replay of the run, the queue row the item blocks, or the NOW card;
empty state "Nothing needs you.", replaced by "Nothing found in the checks
that ran; ... not checked" naming the skipped checks and their reasons when
any check was skipped); then NOW
grouped by repo with a header per repo carrying its own seats-live and
dispatches-live counts (a replay drops the word "live", since the seats shown
are history); each seat card reads repo, issue and milestone (with a
"milestone unverified" mark when the lookup was skipped), purpose, the seat
task line, the status clause (the heartbeat age derives from
`last_heartbeat_ts` and ticks on the same clock as the strip's "last event",
so a frozen projection never leaves a fresh heartbeat under a green LED),
the branch dim, and the PR number and title
when one exists; then UP NEXT (repo first, issue, purpose, plan file dim, a
blocked plan shows its `blocked` reason in place); then INITIATIVES (one row
per open milestone, a fallback row says "streams and queue alone"); then
FAILED and LANDED today (failed first when non-empty, rows lead with the repo
and carry the receipts: a landed PR number links to the PR and prints its
title, and every row links the replay of its own stream, plus the trail when
the Almanac join exists); last, one `<details>`
control, closed by default, holding replay and the scrubber, stream facts,
the schema line, the pipeline tiles, the lanes or spine, the event tail and
the trail links.

### NEEDS YOU, INITIATIVES and blocked queue entries (Floor v3, wave A)

Law: [`docs/proposals/floor-v3-purpose.md`](proposals/floor-v3-purpose.md)
§ 4.2, § 4.4 and § 4.5. The page exists so the owner never has to ask "is
anything waiting on me" and "where does each initiative stand". Both answers
are projected as data first; the page (wave v3-B) only reads them.

**The honesty rule: `needs_you` never invents an item.** Every entry cites
where it came from (a comment id, a stream event, or a file and line) and
carries a `verified` flag. A check that could not run (gh absent, no
checkout on this machine) is listed in `needs_you_meta.checks` as `skipped`
with its reason, so the page can say "critic verdicts unverified" instead of
"nothing needs you". A check that ran and found nothing is `ok`.

| Key | Type | Meaning |
|-----|------|---------|
| `needs_you[]` | array | One entry per item, **newest first** by `at`. Shape below |
| `needs_you_meta` | object | `{count, unverified, checks[], superseded[], comment_lookback_days, quiet_after_s}`. `checks[]` has one `{check, status, reason, looked_at}` per type: `status` is `ok` or `skipped`, `looked_at` how many candidates the check inspected. `superseded[]` holds the failed dispatches a later round replaced (issue 86, rule below), newest first, each the entry it would have been plus `superseded_by` |
| `summary.needs_you` | int | The count of **verified** entries, for the status strip |
| `queue[].blocked` | string\|null | Why a queued plan is not ready, in place: the reason `scripts/queue.sh block` stored, else the text of the NEEDS YOU item that names the plan (a PRD row awaiting sign-off, a variable unset) or `PR N awaits merge` when a ready PR sits on one of the plan's branches. `null` when nothing names it |
| `queue[].blocked_by` | object\|null | `{type, source}`: the item type (`queue` for a stored reason) and the same `source` object the item carries |
| `initiatives[]` | array | One row per open milestone with activity in the last 30 days, in each repo the queue or the day names. Shape below |
| `initiatives_meta` | object | `{count, repos[], active_days, plans_seen}`; `repos[]` says per repo whether gh listed its milestones (`verified`) or the row is a fallback (`skipped` + reason) |

`needs_you[]` entry:

| Key | Type | Meaning |
|-----|------|---------|
| `type` | string | `critic_block` · `ready_to_merge` · `quiet_seat` · `failed_dispatch` · `prd_proposed` · `missing_variable` |
| `text` | string | One line in plain words, ≤ 160 chars, scrubbed |
| `action` | string | The one action: `open the comment` · `merge` · `check the log` · `see the output` · `approve or edit` · `set it` |
| `source` | object | Where the item came from; `kind` is `comment`, `pr`, `stream` or `file` (fields below) |
| `verified` | bool | `true` when the fact was confirmed at its source. Stream and file items always are; a gh item is `true` only when gh answered. A check that could not run adds no entry at all: the `skipped` row in `needs_you_meta.checks` is the record |
| `at` | string\|null | The time that orders the list: the comment time, the stream event time, or the queue entry's `added_at` for file items |
| `repo` / `branch` / `pr` / `plan` | mixed | What the item names, so the queue and the seat cards can join to it; each `null` when not applicable |

Types, their rule and their source:

| Type | Rule | `source` |
|------|------|----------|
| `critic_block` | The newest comment of a critic thread on an open PR, or on the findings issue a plan's critic seat posts to, is `BLOCK-FIX`, `BLOCK-ESCALATE`, `BLOCK-CLOSE` or `BLOCK`, and no fix wave is running or queued for that branch or PR (a running seat on the branch, or a queued or running plan whose file lists the branch or whose header names the PR). Through gh | `{kind: comment, repo, comment_id, url, pr, issue, verdict, round, stem}` |
| `ready_to_merge` | The PR is open, not a draft, every critic thread's newest verdict is `SAFE-TO-MERGE`, `SAFE` or `APPROVE-MERGE`, and `mergeStateStatus` is `CLEAN` (`UNKNOWN`, `BEHIND`, `DIRTY`, `BLOCKED` are not ready). Through gh | `{kind: pr, repo, pr, url, merge_state, comments[]}` (the verdict comments, reduced as below) |
| `quiet_seat` | A running seat with `quiet: true` (no heartbeat for `quiet_after_s`, 90 s). Never when the seat's own stream is `offline` (no event for `offline_after_s`, 900 s): that stream has stopped, its seats with no close-out read `unknown`, and a crashed wave is not a quiet seat. From the stream | `{kind: stream, dispatch_id, event: seat_heartbeat or seat_dispatch, task_id, ts}` |
| `failed_dispatch` | A `today[]` row whose `outcome` is `failed` or `aborted`, unless a later round superseded it (below). The text starts at the plan purpose; the repo rides the entry's `repo` field and the page renders it once, as the row's chip. From the stream | `{kind: stream, dispatch_id, stream (basename), event: dispatch_end, ts}` |
| `prd_proposed` | A queued plan names `S<n>` and a table row whose first cell is `S<n>` under `docs/prd/` of the target checkout carries `PROPOSED` and not `ACCEPTED`. Grep of the checkout | `{kind: file, checkout (repo name), file (relative to it), line, named_by (plan basename)}` |
| `missing_variable` | A queued plan names an `UPPER_SNAKE` name, a row of `docs/operations/env-vars-*.md` in the target checkout says it comes from a repository variable (or secret), and `gh variable list` (or `gh secret list`, names only) does not have it. When gh could not answer there is no entry: the `missing_variable` check reads `skipped` with the reason in `needs_you_meta.checks`, because an item with action `set it` would ask the owner to set a value nobody checked | `{kind: file, checkout, file, line, named_by, lookup, reason}` |

The critic first-line convention, as read: the first line of the comment
carries the word `CRITIC`; the verdict opens the text after a colon on that
line or closes the line (`CRITIC K ROUND 2: BLOCK-FIX on two items`, `CRITIC
FLOOR V3A BLOCK-FIX`), else it opens a later line of its own (`BLOCK-FIX on
two items`, `Verdict: SAFE-TO-MERGE`); the same start-of-token rule on both,
so a verdict quoted mid-sentence never counts (`CRITIC V3A NOTE: the last
review said BLOCK-FIX but this is not a verdict.` is no verdict) and a heading
word `BLOCK` or `SAFE` before the colon never steals `BLOCK-FIX` or
`SAFE-TO-MERGE` after it (`CRITIC V3A BLOCK: BLOCK-FIX` reads `BLOCK-FIX`).
Two different verdict words standing as tokens of their own where the
verdict is read (after the first colon, else anywhere on a line with no
colon) make the first line ambiguous and it carries no verdict: `CRITIC
FLOOR V3A BLOCK-FIX SAFE-TO-MERGE`, with or without a colon, in either
order, invents neither a `critic_block` nor a `ready_to_merge`; a critic
who wants one read writes one token. `ROUND n` names the round (1 when absent). A thread is the heading of the first line (its leading run of
upper-case words, verdict and round removed), and the newest comment of each
thread is its current verdict, so one critic's re-review replaces its own
earlier round and never another critic's. PR comments and PR reviews are
read from `gh pr view`; findings-issue comments from
`gh api .../issues/N/comments?since=` (7 days) and attributed to a PR by the
`PR N` it names or the branch name it carries. What is published of a
comment is `{id, url, at, kind, verdict, round, stem}`: **never the body**.
Bodies are read in-process to find the verdict and the attribution, and
dropped.

**Superseded failed dispatches (issue 86).** A `failed_dispatch` row leaves
`needs_you[]` when a later round replaced it; it is not deleted, it moves to
`needs_you_meta.superseded[]` with a `superseded_by` note, and the page shows
the fold under the NEEDS YOU list, closed by default. The status strip's
failed and aborted figures still count these rows (they happened); only
`needs_you` counts what is still open. Same repo and later than the row
(`ended_at` for settled dispatches, `started_at` for one still running), a
row is superseded when:

1. another dispatch of the same plan file ran today, same repo (any outcome:
   the newest failure of a chain is itself the open row, the ones before it
   are replaced). A live re-dispatch folds the failure only once a seat
   exists for it: a dispatch that has only seen `dispatch_start` leaves the
   row open while NOW has nothing to take its place;
2. a dispatch ran a fix round for it: the plan file is the same stem with a
   fix suffix (`x.plan` → `x-fix.plan`, `x-fix2.plan`), or the plan header
   carries fix-round wording (`fix round`, `fix wave`, any case) and names the
   row by its stem or its branch (a row branch in the header or among the
   candidate's own branches, or the candidate stem growing out of the row's
   stem), never by a subset of the row's title words;
3. a dispatch on one of its branches ended `landed`;
4. gh says the branch has merged (`gh pr list --state merged`), same repo and
   `merged_at` later than the row (`ended_at`, else `started_at`): optional,
   so when gh cannot answer the rule does not fire and the `merged_branch`
   check reads `skipped` with the reason.

`superseded_by` is `{kind, plan, dispatch_id, branch, pr}`: `kind` is `plan`
(later dispatch of the same or a fix-round plan), `landed` (same branch landed
later) or `merge` (branch merged, `pr` its number).

The target checkout for the file checks is `FLEET_CHECKOUTS` (colon-separated
roots holding `<repo>/`), else the fetch point `scripts/run-remote.sh` keeps at
`~/dev/<repo>`, else a sibling of this repo. Only the repo name and a path
relative to it are published, never where the checkout is. No checkout on
this machine marks the check `skipped`.

`initiatives[]` row:

| Key | Type | Meaning |
|-----|------|---------|
| `repo` / `title` / `number` / `url` | mixed | The milestone. `number` and `url` are `null` on a fallback row |
| `lookup` / `reason` | string | `verified` when gh listed the milestone, else `skipped` and why (the row then comes from the streams and the queue alone). A fallback row carries every key of this table: `number`, `url`, `epic`, `epic_title`, `exit`, `open_issues`, `last_landed` and `updated_at` are `null` and `exit_lookup` is `skipped` |
| `epic` / `epic_title` | int\|null, string\|null | The issue of the milestone whose title carries the word `epic`, when there is one |
| `exit` / `exit_lookup` | string\|null | The exit criterion sentence from the epic body: the text after a line opening `Exit criterion:`, `Exit:`, `Done when:` or `Definition of done:`, first sentence, ≤ 200 chars, scrubbed. `null` when the body carries none (`exit_lookup: verified`) or when it was not read (`skipped`). The body is read in-process only; nothing else leaves it |
| `waves` | object | `{landed, planned, landed_ids[], planned_ids[]}`. Planned: the distinct wave ids of the plans that belong to the milestone, from the plan naming convention (`W2-A` in the header, else `-w2a-` in the file name) across `wave-plans/` and the queue. Landed: those whose plan landed today in the streams or whose branch has a merged PR (`gh pr list --state merged`, the newest 100) |
| `open_issues` | int\|null | From the milestone; `null` on a fallback row |
| `last_landed` | object\|null | `{number, title, branch, merged_at, milestone}` of the newest merged PR whose branch belongs to a plan of the milestone, or that carries the milestone, or whose title names one of its issues |
| `updated_at` | string\|null | Milestone activity time; rows sort by it, newest first |
| `plans` | array | Basenames of the plans that belong to the milestone: header names an issue of the milestone or its epic, or carries the milestone title |
| `source` | object | What each field came from and whether that lookup was `verified` |

Fallback rows (gh absent, disabled, unauthenticated or over budget): one row
per track name the plan headers name before their wave id ("Assistant
Channel W2-A: …" reads as "Assistant Channel"), over the plans landed today,
queued, or live; `lookup: skipped` with the reason, milestone number, open
issues, exit and last landed all `null`, and `waves` from the streams and
the queue alone.

Rules the projector enforces:

* every entry cites its source and says whether it was verified; a check
  that could not run is `skipped` with a reason in `needs_you_meta.checks`,
  never silently empty;
* no comment body, issue body or PR body reaches the projection; no checkout
  path either;
* a queued plan is still only `queued`; `blocked` explains why it is not
  ready, it never claims the plan ran;
* **a replay carries neither `needs_you[]` nor `initiatives[]`** (both `[]`),
  for the same reason it carries no queue and no day;
* the gh rules are unchanged: optional, cached, budgeted (60 calls per
  projection), never fatal, off with `--no-gh` or `FLEET_DESK_NO_GH=1`.

### Yesterday and the push (Floor v3, wave C)

Law: [`docs/proposals/floor-v3-purpose.md`](proposals/floor-v3-purpose.md)
§ 5. The strip offers today and yesterday; history deeper than that stays in
the Almanac. Nothing pushes unless the owner turns it on.

| Key | Type | Meaning |
|-----|------|---------|
| `yesterday[]` | array | One entry per dispatch whose `dispatch_end` fell on the **previous** local calendar day, read from the same streams the same way as `today[]`: every key of a `today[]` row, the same `outcome` rule, newest first |
| `yesterday_meta` | object | `{day: "yesterday", date, streams_read, live, ended}`, the keys of `today_meta`. `live` is always `[]`: a run with no close-out is in motion now and belongs to today. `today_meta` carries `day: "today"`, so the payload says which day a block is, never its position |
| `summary.landed_yesterday` | int | The row count of `yesterday[]`, next to `landed_today` |

Rules:

* a replay carries `yesterday: []` like `today: []`;
* on the page the toggle switches only the landed and failed figures and the
  two lists; running, up next and needs you are the present and do not
  switch. A projection without `yesterday_meta` (an older watcher) hides the
  toggle and reads today;
* the day-stream scan looks back 50 hours by file mtime (yesterday plus a
  25 hour DST day); nothing older is read here.

**The push.** `scripts/notify.sh needs-you [live.json]` reads the projection
and sends **one macOS notification per NEEDS YOU item** that has had no
action for N minutes. Once per item, never twice: sent items are recorded in
a seen file by their stable identity, the `type`, the `source.kind` and what
names the item for that kind (the comment id; the repo and PR number; the
dispatch and seat; the checkout, file and line). Never the whole `source`: a
later SAFE comment on the same PR changes `source.comments`, not the item,
and makes no second toast. `desk_live.py` calls it after every write
(`--once`, `--watch` and the server's watcher), never fatally, and only when
the variable is set.

The toast text is built from **fixed phrases and identifiers only**, never
from a PR title, a comment body, a task line or the item's own `text`. The
shape is `<repo> <item type phrase> PR <number>` (`olympus-platform ready to
merge PR 102`); a critic block reads `<repo> blocked by <critic stem word>
round <n> PR <number>` (`dev-agents blocked by frontend critic round 2 PR
80`). The item type phrase is the type name with spaces (`ready_to_merge`
reads "ready to merge"); the PR suffix appears only when the item carries a
PR number; the stem word is the critic heading lowercased when it is plain
words, else the fixed word `critic`. An item whose identifiers are missing
or malformed (no repo name, an unknown type) is refused with one stderr
line, never sent and not recorded as seen: no free text reaches a
lock-screen toast, whatever a hand-written `live.json` says.

The page rows are separate from this. Their `text` is scrubbed as before:
the projector checks every slash token of a NEEDS YOU line, and of a PR
title before it, against the worktree exactly as it does a task line
(`outside-repo` for an absolute, home, variable or parent-escape path,
encoded or not; repo-relative paths, branches and URLs pass). That scrub now
serves the page alone.

| Variable | Meaning |
|----------|---------|
| `FLEET_NOTIFY_NEEDS_YOU_MIN` | N, in minutes. **Unset or empty: nothing is sent and nothing is written** (the default). `FLEET_NOTIFY_NEEDS_YOU_MIN=10 make desk-follow` turns it on |
| `FLEET_NOTIFY_NEEDS_YOU_STATE` | The seen file (default `logs/notify-state/needs-you.seen`, gitignored with the rest of `logs/`) |
| `FLEET_NOTIFY_SILENT=1` | Still gates the toast, as for seat outcomes; the stdout line and the seen record happen either way |

What is pushed, and what never is: only a `view: live` projection (a replay
is history), only `verified` items, only an item whose `at` proves it has
waited N minutes (an item with `at: null` cannot prove it and is never
pushed). An item that leaves the list (the owner acted) is simply never
pushed; one that comes back with a new source is a new item.

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
make desk-follow                   # recommended: watch + serve + open browser
make desk-live                     # watch + serve http://127.0.0.1:8777/live/ (SSE at /events)
make desk-live PORT=9000           # different port
make desk-live-once                # write live.json once, no server (file:// desks)
python3 scripts/desk_live.py --watch          # rewrite live.json on a timer, no server
python3 scripts/desk_live.py --once --dispatch-id 20260729-100000-dev-agents --print
python3 scripts/desk_live.py --once --dispatch-id ID --as-of-seq 4 --replay
python3 scripts/desk_live.py --once --no-gh    # no gh enrichment (also FLEET_DESK_NO_GH=1)
python3 scripts/desk_live.py --list-runs
FLEET_NOTIFY_NEEDS_YOU_MIN=10 make desk-follow   # push: one toast per NEEDS YOU item idle 10 min
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
