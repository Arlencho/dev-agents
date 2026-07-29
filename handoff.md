# Critic verdict — PR #48 Fleet Desk Phase 1 data contract (schema v2)

**VERDICT: REVISE** (narrow — test coverage only; **no production bug found**)

Branch `feat/fleet-desk-phase1-data` @ `7cb1bd6`. Verify-only pass: no production
file modified, working tree clean.

Every claim in the PR body verifies, and all seven requested checks pass
functionally. The revise is for four **surviving mutants** on the headline P3
gate: the code is correct today, but the contract's central promise is not pinned
by any test, and one mutant silently inflates the **real fleet's** published PMI
bands while all 178 tests stay green.

---

## Built

Adversarial verification only. Mutation harness in a throwaway clone (`/tmp/mut`);
scratch git fixtures in `/tmp/{deep,honest,nopair}`. Nothing added to the repo
except this handoff.

## Evidence

### Baseline green (item 7)

```
$ make test
== 178 passed, 0 failed ==     |  All test suites passed.

$ make experience / experience-data / desk / experience-snapshot
all resolve and run — 19 trails, 5 companies, 9 critic pairs

$ python3 scripts/experience_build.py …    # after hand-editing schema_version -> 99
schema mismatch: … is v99, renderer expects v2 — re-run scripts/experience_data.py
exit code = 1
```

PR claim "`make lint` drift is pre-existing" — **verified honest**: identical
`FAIL: 11 file(s) out of sync` on this branch *and* on clean `main`.

### (1) Schema v2 ↔ docs ↔ shipped JSON — PASS

Field-level diff of `docs/experience-data.md` against the built JSON:

```
doc-only top: []            undocumented top: []
doc-only trail: []          undocumented trail: ['handoff_truncated']
doc-only skill/learning: [] undocumented skill: []   undocumented learning: []
doc-only pair: []           undocumented pair: []
undocumented role_stats: ['role']
phase0_cap present anywhere: False
```

The two undocumented fields **pre-date this PR** (both present and equally
undocumented on `main`, via `git show main:scripts/experience_data.py`). Not a
regression; nit only. `phase0_cap` is genuinely removed, not aliased.

### (2) Skill git history honest — PASS

Proved the two states are never conflated, using real git:

| Case | `skill_history.available` | per-skill | meaning |
|------|---------------------------|-----------|---------|
| no git work tree | `False` | `revisions=0`, `history_available=False` | git unreadable |
| git repo, file uncommitted | `True` | `revisions=0`, `history_available=True` | no commits yet |

Depth cap genuinely applied: a pack with 26 commits yields exactly 20 entries and
`history_truncated=True`.

### (3) PMI P3 gate — behavior PASS, coverage FAIL (see Blocking)

P2 outcome bar preserved (`compute_pmi` requires `p2_ok` for both P2 and P3);
`display_cap` is `P3`; `fixture-veteran` (defaults only, 5/5 done) correctly stays
P2; the Phase 0 "capped at P2" caption is gone everywhere except the migration
table, where it belongs.

### (4) Critic pairing by branch — PASS

`critic_pairs[]`, `reviewed_by`/`reviews`, and `critic_rate_method: branch_pairing`
all correct. Forced the documented fallback (re-branched fixture critics onto
their own branches):

```
critic_pairs = 0    method = role_name_fallback
rate = 0.0741  == critic_trails/trails  -> match: True
```

### (5) `gh` never fatal + redaction + offline fixtures — PASS

```
gh removed from PATH  -> exit=0  status=unavailable      warnings=[…build continued…]
gh present, exits 1   -> exit=0  status=unauthenticated  warnings=[…build continued…]
```

`pr_url` / `pr_state` / `pr_number` / `issue_links_resolved` exist on every trail
in both cases. Disabling `redact()` is caught by 5 tests. `trails_with_pr: 0` on
the real repo is **correct, not a bug** — all 19 trails are product-repo
`feat/ab-T*` branches, which is the foreign-repo guard working as designed.

### (6) Snapshot — PASS

24.9 KiB (matches claim). `0` secret-shape matches, `0` home-path matches, and no
key containing `body` anywhere in the payload; `git_history` blobs dropped.

---

## Blocking — 4 surviving mutants (all fixable with fixtures, no production change)

Each mutation was run through the full suite in a clean clone. "SURVIVED" = the
mutation changed real output while `== 178 passed, 0 failed ==` still printed.

**B1 — `specialized` → `packs` survives, and inflates the real fleet. (highest)**

`docs/experience-data.md` promises "Shared default packs are excluded on purpose".
Nothing tests it, because no fixture default pack qualifies as evidence. On the
**real repo**, `git-ship` is a shared default at `v2` / `revisions=2`, so it does:

```
mutant: evidence = proven_loop_evidence(packs, skill_index)
REAL REPO -> frontend-critic band=P3  ev=['git-ship v2 with 2 recorded revisions']
             web-frontend    band=P3  ev=['git-ship v2 with 2 recorded revisions']
suite: 178 passed, 0 failed
```

Fix: a fixture role clearing P2 with **defaults only**, where a *default* pack has
`version≥2` + `revisions≥2`, asserted to stay P2. (`fixture-veteran` is the right
role; the fixture just needs a qualifying default pack.)

**B2 — dropping the P2 outcome bar from the P3 gate survives.**

`if p2_ok and evidence:` → `if evidence:`. The existing assertion "P3 needs the P2
outcome bar too" is **vacuous**: the only evidence-bearing fixture role
(`fixture-builder`, 6/6) also clears P2 comfortably. Demonstrated by giving
`fixture-runner` (n=5, n_done=4 → below the bar) the evidence-bearing pack:

```
correct: band=P1  ev=['fixture-pack promotes lesson-one']
mutant : band=P3  ev=['fixture-pack promotes lesson-one']
```

Fix: keep a fixture role with proven-loop evidence but sub-P2 outcomes, asserted
non-P3.

**B3 — dropping `revisions >= 2` from the version path survives.**

The docstring explicitly guards "actually revised, not merely born at v2", but
`fixture-pack` is `v2` with `revisions=1`, so the version path never fires in Part
A — only the promotion path is exercised:

```
fixture-pack v2 rev=1 promotes=[]
correct: fixture-veteran band=P2  ev=[]
mutant : fixture-veteran band=P3  ev=['fixture-pack v2 with 1 recorded revisions']
```

Fix: assert that a `v2` / `revisions=1` specialized pack with no promotion yields
no evidence.

**B4 — removing `-n{depth}` from `git_file_history` survives.**

The only depth assertion is `d["skill_history"]["depth"] == 20`, which merely
echoes the constant. With 26 commits on one SKILL.md:

```
correct: git_history entries=20  history_truncated=True   (declared depth=20)
mutant : git_history entries=26  history_truncated=True   (declared depth=20)
```

The mutant publishes a self-contradicting contract and nothing notices. Fix:
assert `len(git_history) <= history_depth` for every skill — cheap, and catches it
without needing a 20-commit fixture.

## Non-blocking nits

- `handoff_truncated` (trails) and `role` (role_stats) undocumented — pre-existing
  on `main`, worth one doc line while the schema table is open.
- `gh` **missing** and **erroring** paths are never exercised by the suite (no
  `PATH=` manipulation). Verified correct by hand; a `PATH=/usr/bin:/bin` build
  would pin it in one line.
- `role_name_fallback` is never exercised by a fixture. Verified correct by hand.
- PR body says "117 before this branch"; `main` actually reports
  `== 124 passed, 0 failed ==`. Cosmetic.
- `make experience-snapshot` writes `docs/experience/snapshot/`, which is **not**
  gitignored (unlike `site/experience/`), so the target leaves untracked files that
  can be committed by accident. Deliberate per SYNTHESIS §10 ("owner call"),
  flagged so it stays a decision rather than a surprise. I removed the copy my run
  generated.

## Decisions

- **REVISE, not APPROVE**, despite zero production defects and a fully green
  suite: three of the four surviving mutants sit on the P3 gate, which is this
  PR's headline and the number the console publishes about the fleet. B1 in
  particular means a single identifier (`specialized`) is the only thing standing
  between the real roster and across-the-board P3 inflation, with no test to catch
  its removal. Coverage alone is not sign-off on a risky path.
- Every finding is a **fixture/assertion addition**. No production change is
  requested and no UI/visual change is implied.
- Did not re-implement, redesign, or touch production code.

## Do not repeat

- Don't "fix" B1–B4 by editing `scripts/experience_data.py` — the production logic
  is already correct. Only the fixtures/assertions are missing.
- Don't assert `skill_history.depth == 20`; it is a constant echo and proves
  nothing. Assert the length of the emitted history instead.
- Don't treat `trails_with_pr: 0` on the real repo as a gh bug — it is the
  foreign-repo guard behaving correctly for `feat/ab-T*` product trails.
- Don't build the P2-bar assertion off `fixture-builder`; it clears P2 anyway,
  which is exactly what made the existing assertion vacuous.

## Next hint

B1 and B4 together are ~6 lines of fixture/assert and cover the two highest-value
gaps. B2 and B3 each need one small fixture role. Afterwards, re-run the four
mutations above and confirm each is caught.
