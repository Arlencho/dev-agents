# Handoff — Fleet Desk Phase 1 DATA CONTRACT (`feat/fleet-desk-phase1-data`)

Seat: devops. Data layer only — **no visual redesign**. Renderer touched in three
caption lines that read values out of the JSON (the Phase 0 "capped at P2" text
would otherwise lie now that P3 is real) plus one `.band-p3` CSS rule.

## Built

| File | Change |
|------|--------|
| `scripts/experience_data.py` | `SCHEMA_VERSION 1 → 2`, `phase 0 → 1`; skill git history; critic pairing by branch; optional `gh` enrichment; optional snapshot; `--no-gh` / `--snapshot` / `--snapshot-dir` flags |
| `scripts/experience_build.py` | Reads `pmi_policy.display_cap` (was `phase0_cap`), `fleet.critic_rate_label`, `phase` — caption text only, no layout change |
| `templates/experience/site.css` | One rule: `.pmi.band-p3` (P2 tokens + inset outline) |
| `scripts/experience-build.sh` | Forwards extra args to the data step (`--no-gh`, `--snapshot`) |
| `Makefile` | New `experience-snapshot` target (with `## comment`) |
| `docs/experience-data.md` | Phase 1 fields, exact P3 gate, pairing + fallback, gh rules, snapshot, **v1 → v2 migration table** |
| `docs/experience.md` | Phase 1 enrichment table, snapshot command, 3 new troubleshooting rows |
| `tests/run-experience-tests.sh` | +61 assertions (117 → 178), new Part A2 |
| `tests/fixtures/experience-mini/` | critic-1 now shares the widget-x branch; new `fixture-veteran` role (wave 7, 5 done) that must stay P2 |

**(1) Skill git history** — `git log --follow -n20 --date=short` per
`skills/*/SKILL.md` **and** `skills/_candidates/*/SKILL.md`. Per skill:
`git_history[{sha,date,ts,subject}]`, `revisions`, `first_commit`, `last_commit`,
`history_available`, `history_truncated`, `history_depth`, `promotes`.
Top level: `skill_history {available, depth, source, reason, skills_with_history}`.

**P3 gate (exact, documented in `docs/experience-data.md`):** P2 outcome bar
(`n_done ≥ 5` AND `success_rate ≥ 0.70`) **AND** at least one *specialized* pack
(beyond the three shared defaults) that either has `version ≥ 2` **and**
`revisions ≥ 2`, **or** cites a learning file (`promotes` non-empty). Evidence
strings land in `pmi.inputs.proven_loop_evidence`. `pmi_policy.display_cap` is now
`P3`; when git cannot be read, `cap_reason` says only the promotion path was
evaluable and `history_available: false`. Phase 0 caption ("P3 needs
version/promotion history (Phase 1)" / "Phase 0 caps display at P2") is gone, and
a test fails if that wording returns.

**(2) Critic pairing** — `pair_critics()` groups trails by branch; a branch with
≥1 non-critic and ≥1 critic trail is a pair. New: `critic_pairs[]`,
`counts.critic_pairs`, per-trail `is_critic` / `reviewed_by` / `reviews`,
role_stats `n_reviewed` / `review_rate` / `n_reviews_given` / `paired_branches`.
`fleet.critic_rate = paired_producer_trails / producer_trails` with
`critic_rate_method: branch_pairing`. **Fallback:** zero pairs → Phase 0
name-based rate with `critic_rate_method: role_name_fallback`;
`critic_rate_basis` always publishes the raw counts.

**(3) gh enrichment** — at most 4 calls (`auth status`, `repo view`, `pr list`,
`issue list`, `--limit 200`, per-call timeouts 6/15s), only when `gh` is authed
**and** the projected repo is the git work-tree root. Adds `pr_url`, `pr_state`,
`pr_number`, `issue_links_resolved` (titles only, redacted, ≤120 chars — never
bodies/comments). Fields always exist, empty when it did not run.
`gh_enrichment.status ∈ {ok, skipped, disabled, unavailable, unauthenticated,
error}` + `reason`; non-ok also appends a `warnings[]` line. Off switch:
`--no-gh` / `FLEET_DESK_NO_GH=1`.

**(4) Snapshot** — `make experience-snapshot` → `docs/experience/snapshot/`
(`summary.json` + `README.md`). Rollup only: counts, fleet, PMI bands + reasons,
critic pairs, waves, skill versions/revisions, learning statuses, one-line trail
rows. Every free-text body dropped (`handoff_markdown`, `handoff_sections`,
skill/learning `body`, `git_history`). **Measured 24.9 KiB** on this repo, 20 KiB
on the fixture. Not committed here — committing it is an owner call (SYNTHESIS §10).

**(5) schema_version 2** with a migration table in `docs/experience-data.md`
(4 breaking rows: `phase0_cap`→`display_cap`, band range now includes P3,
`critic_rate` meaning, `phase`). Everything else is additive.

## Decisions

- **`phase0_cap` renamed, not aliased.** Keeping a key named "phase0" holding
  "P3" would be a lie on the surface that most needs honesty. That rename is the
  reason for the version bump.
- **P3 needs BOTH bars.** Outcomes alone never reach P3, evidence alone never
  reaches P2. Shared default packs are excluded from evidence: everyone gets
  them, so they prove nothing about a role.
- **Two P3 paths.** Version history depends on git; promotion depends only on
  files. So a git-less projection can still reach P3 honestly, and the
  `cap_reason` says which path was evaluable.
- **gh auto-detects rather than opt-in.** Opt-in would mean nobody ever sees PR
  links. Safety comes from the work-tree-root gate (fixtures never call gh),
  short timeouts, and status/warnings instead of exceptions.
- **Bare `#123` only resolves when the trail's branch matched a PR in this repo.**
  Otherwise a black-aces trail's `#12` would link to an unrelated dev-agents
  issue. Full URLs resolve only on slug match.
- **Fixture role `fixture-veteran`** (defaults only, 5 done) exists to prove P2
  does **not** drift to P3 — `fixture-builder` alone could not prove that.
- **Git facts are never faked in fixtures.** The revision path to P3 is tested by
  `git init`-ing a throwaway copy and making real commits; the degradation path by
  building a copy outside any work tree.
- **Renderer left alone otherwise.** Trails carry `pr_url`, `reviewed_by`, skill
  `git_history` etc. in the JSON with no page rendering them yet — that is the
  next wave's job, per the task.

## Do not repeat

- Do **not** assert PMI bands against `fixture-builder` as the "P2 example" — it
  is P3 now (promotion path). Use `fixture-veteran`.
- Do **not** point `assert_json` at `snapshot/summary.json`: that helper requires
  `role_stats`/`companies`/`trails` top-level keys and the snapshot uses `roles`.
  Use a bespoke `python3 - <<PY` block.
- Do **not** let fixture builds hit `gh` (flaky/slow in CI). Part A passes
  `--no-gh`; the work-tree-root gate also skips fixtures automatically.
- `make lint` fails on this branch **and on clean `main`** (11 provider-role files
  out of sync, `./scripts/sync-providers.sh`). Pre-existing, unrelated — verified
  by stashing all changes and re-running.
- `redact()` emits `[redacted-token]`, not `[redacted]`, for token shapes.

## Evidence

```
$ make test
… == 178 passed, 0 failed ==
All test suites passed.                      # was 117 passed before this branch

$ python3 scripts/experience_data.py --repo tests/fixtures/experience-mini --out /tmp/fd --no-gh
Fleet Desk data → /tmp/fd/data/index.json (27 trails, 2 companies, 19 unlinked, 1 critic pairs)
  gh enrichment: disabled — disabled (--no-gh or FLEET_DESK_NO_GH=1)
  skill history: available (3/3 packs with commits, depth 20)

$ make experience-snapshot                   # real repo
Fleet Desk data → …/site/experience/data/index.json (19 trails, 5 companies, 19 unlinked, 9 critic pairs)
  gh enrichment: ok
  skill history: available (6/6 packs with commits, depth 20)
  snapshot → …/docs/experience/snapshot/summary.json (24.9 KiB, bodies dropped)

$ grep -cE 'gh[pousr]_[A-Za-z0-9]{16,}|/Users/|BEGIN [A-Z ]*PRIVATE KEY' docs/experience/snapshot/summary.json
0

# real repo fleet block (pairing is live, not a fixture artifact)
"critic_rate": 1.0, "critic_rate_method": "branch_pairing",
"critic_rate_basis": {"pairs": 9, "producer_trails": 9, "paired_producer_trails": 9,
                      "critic_trails": 10, "unpaired_critic_trails": 1, ...}

$ git stash push && make lint   # → same 11-file drift failure without my changes
```

New test groups: `A2.1` no-git degradation, `A2.2` real `git init` + 2 commits →
revision path to P3, `A2.3` env kill switch, `A2.3b` offline unit test of the gh
mapping (foreign-repo refs must not resolve), `A2.4` snapshot (bodies dropped,
no secrets, size bound).

## Open questions

- `trails_with_pr` is 0 on this repo today: every trail's branch belongs to a
  product repo (black-aces), so nothing matches dev-agents PR head refs. Correct
  behavior, but PR enrichment stays unproven against live data until a
  dev-agents-branch trail lands. The mapping itself is unit-tested offline.
- Snapshot is generated but **not** committed. If the owner wants it checked in,
  add a wave that commits `docs/experience/snapshot/` and decides refresh cadence.

## Next hint

Renderer wave: surface `reviewed_by` / `critic_pairs` on trail + work rows,
`git_history` on skill pages, `pr_url` / `pr_state` on trail detail, and the P3
evidence list on role pages. All fields already exist in `data/index.json`; no
data work needed.
