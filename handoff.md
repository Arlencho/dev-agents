# Critic loop 2 — PR #48 `feat/fleet-desk-phase1-data`

**VERDICT: APPROVE.**

Verify-only pass over `abd6736` (producer REVISE) + `59b7bff` (handoff), branch
tip `59b7bff`. Every blocking item B1–B4 was re-killed by re-introducing the
original mutant against the **committed** tree. All four are load-bearing. No
production logic moved. Nothing was redesigned or re-implemented.

## Built

Nothing. This is a review. `git status` is empty, `scripts/experience_data.py`
was never edited in the working tree — all mutation ran in throwaway copies
under `/tmp/mut/` (`cp -R` of the repo incl. `.git`, so git-derived facts stay
real). The only file this pass writes is this `handoff.md`.

## Evidence

Control first: the isolated copy reproduces the committed baseline, so a RED
result below is attributable to the mutant and not to the harness.

```
make test              (working tree)  == 188 passed, 0 failed ==  All test suites passed.
tests/run-experience-tests.sh (/tmp/mut/base, pristine copy)
                                       == 188 passed, 0 failed ==
```

Each mutant re-applied to a fresh copy of the committed tree, each proven
non-no-op by `git diff` before running:

| # | Mutation (anchor verified unique) | Result | Killing assertions |
| --- | --- | --- | --- |
| **B1** | `proven_loop_evidence(specialized, …)` → `(packs, …)` | **179 / 9 RED** | `shared default pack never grants P3`, `no role cites a default pack as evidence`, `no git: default pack promotion still grants no P3`, `git: over-qualified default pack still grants no P3` (+5) |
| **B2** | `if p2_ok and evidence:` → `if evidence:` | **184 / 4 RED** | `evidence without the P2 outcome bar stays below P3`, `P3 needs the P2 outcome bar too`, `n_done<5 stays P1 even at 80%`, `specialized pack alone never grants P2` |
| **B3** | drop `and s["revisions"] >= PMI_GATES["p3_min_pack_revisions"]` | **186 / 2 RED** | `pack born at v2 but never revised is not a proven loop`, `git: v2 pack with exactly 1 commit is not a proven loop` |
| **B4** | remove `f"-n{int(depth)}"` from `git_file_history` | **187 / 1 RED** | `git: history is truncated AT the published depth` |

Every count matches the producer's reported figures exactly (188/0, 179/9,
184/4, 186/2, 187/1). The claimed evidence is reproducible, not narrated.

**B1 and B3 are each killed in more than one environment** (fixture build,
`--no-git` projection, throwaway git repo), so a single weak environment cannot
hide either mutant — the producer's multi-environment claim holds.

### No silent production change (P3 path intact)

```
git diff 7cb1bd6..HEAD -- scripts/     -> empty
git diff 3f6669d..HEAD -- scripts/experience_data.py -> empty
git diff --name-only 3f6669d..HEAD | grep -vE '^(tests/|docs/|handoff.md)'  -> no matches
```

`scripts/experience_data.py` is byte-identical to the originally reviewed
commit. The P3 gate (`compute_pmi` ll. 946–955, `proven_loop_evidence` ll.
912–937) is unchanged. The REVISE fixed *tests*, which is exactly what the
REVISE asked for — no defect was invented to justify a production edit.

### Independent mutants (not in the producer's set)

I did not simply re-run the producer's script. Four extra mutants on the areas
flagged for re-check, all **RED**:

| Area | Mutation | Result |
| --- | --- | --- |
| pairing | `p["reviewed_by"] = [...]` → `[]` | 185 / 3 RED |
| schema v2 | `SCHEMA_VERSION = 2` → `3` | 184 / 4 RED |
| snapshot privacy | leak `handoff_sections` into snapshot trails | 187 / 1 RED |
| git-history | hardcode `history_truncated: True` | 187 / 1 RED |

The last one confirms the "asserts the cap from both sides" claim: the flag
cannot be hardcoded, `git: an untruncated pack is not falsely flagged` catches it.

### Schema v2 honesty

Docs match code, checked against constants rather than prose:
`MARKDOWN_CAP = 12000` (l. 72) vs doc "≤ 12000 chars"; `GIT_LOG_DEPTH = 20`
(l. 61) vs doc "≤ `history_depth` (20)". The two newly documented rows are real,
verified against built output, not just declared:

```
trail has handoff_truncated: True
role_stats has role:         True
```

### gh soft-fail (the producer's own open question) — verified by hand

Exercised with a poisoned `PATH`, since the suite does not cover it:

```
PATH=/usr/bin:/bin            -> BUILD OK, gh_enrichment: unavailable | gh not on PATH
gh stub exiting 1             -> BUILD OK, gh_enrichment: unauthenticated | gh auth status failed
gh stub: junk stdout, exit 0  -> BUILD OK, gh_enrichment: ok, 0 PRs / 0 issues resolved
```

The contract "gh enrichment never fails the build" **holds in all three**, and
no links are invented in any of them (`trails with pr_url: 0`). `gh_index`
returns a status/reason on every failure path and never raises.

## Decisions

- **Approving with the gh gap open.** B1–B4 were the blocking set; all four are
  now pinned and independently re-killed. The untested gh degradation paths are
  a coverage gap, not a defect — I verified the actual behavior by hand and it
  is correct. Blocking a green, reproducible fix on a follow-up test would be
  scope creep.
- **Accepted the deleted assertion.** `git: a single-commit pack is not a proven
  loop` was removed as doubly vacuous. Its replacement, `git: v2 pack with
  exactly 1 commit is not a proven loop`, is confirmed load-bearing by the B3
  mutant, so coverage went up, not down.
- **Did not sign off on counts alone.** 188 green assertions prove nothing by
  themselves; the eight mutants above are the actual basis for this APPROVE.

## Do not repeat

- Don't re-run the producer's mutation script and call that verification. It
  proves the script works, not that the tests bite. Mutate the **committed**
  tree yourself and diff before running.
- Don't mutate in the working tree. Use `cp -R` including `.git` — B1's revision
  counts and B4's depth cap are read from real git history, so a copy without
  `.git` silently changes what is being tested.
- Don't treat `== N passed, 0 failed ==` as the control. Run the pristine copy
  first; without that, a RED could be the harness rather than the mutant.

## Open questions (non-blocking, for follow-up)

1. **Cosmetic honesty nit, new observation.** A `gh` that exits 0 while emitting
   non-JSON gets `status: "ok"` with the garbage echoed into
   `gh_enrichment.repo` (observed: `"repo": "not json <<<"`). No links are
   invented and the build is fine, so this is not a defect — but `repo` is
   currently whatever `gh repo view -q .nameWithOwner` prints, unvalidated. A
   one-line slug shape check (`owner/name`) would close it. Contrived scenario;
   filed, not blocked.
2. `role_name_fallback` remains unexercised by the suite (producer's note, still
   true).
3. `make experience-snapshot` output path still not gitignored — deliberate per
   SYNTHESIS §10, owner call, untouched.
