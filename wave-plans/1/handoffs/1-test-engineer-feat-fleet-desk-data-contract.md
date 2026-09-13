# Handoff — critic loop 2, PR #46 `feat/fleet-desk-data-contract`

Seat: critic / verify-only. No production code modified, no UI redesign, no
re-implementation. Reviewed `f41484c` (= `origin/feat/fleet-desk-data-contract`).

## VERDICT: APPROVE

Both blocking findings (F1, F2) are fixed, and the fixes are proven by
executable mutation evidence rather than by green-suite assertion. 11 mutants
applied on a clean tree and reverted: **9 killed, 2 verified equivalent, 0
surviving defects.**

## Built

Nothing. Verification only. `handoff.md` is the sole file written.

## Evidence

Baseline, clean tree:

```
$ git rev-parse HEAD; git rev-parse origin/feat/fleet-desk-data-contract
f41484c9745ef687bb0b0f421d9ba972b4aec1da
f41484c9745ef687bb0b0f421d9ba972b4aec1da
$ bash tests/run-experience-tests.sh | tail -1
== 97 passed, 0 failed ==
```

### F1 — `make experience-data` must not wipe the rendered site — FIXED

Reproduced the original failure path end to end:

```
$ rm -rf site/experience && make experience
html count: 48   data/index.json md5 904e9d52496d7c77b13a3d458d74d6fb
$ make experience-data
index.html exists: YES
html count: 48
data/index.json exists: YES   md5 982c9bd78aedf90abe46e61ca6636aa0
```

HTML survives (48 → 48) and the JSON genuinely changed. The fix was **not**
traded for a stale-page regression — hygiene moved to the HTML owner and still
works:

```
$ mkdir -p site/experience/trail/ghost-trail && echo … > …/index.html
$ echo GHOSTDATA > site/experience/data/stray-asset.txt && make experience
ghost page pruned: YES
ghost dir pruned:  YES
data/index.json intact: YES
```

Part C is non-vacuous by construction: it stamps `generated_at='STALE-STAMP'`
and asserts the stamp is gone, so it proves a real refresh rather than mere
file existence (confirmed by mutant M8b below).

### F2 — no-dump assertions are non-vacuous — FIXED

Fixtures now carry 4 absolute operator log paths (3× `/Users/fixtureop/…`,
1× `/home/fixtureop/…`; 18 remain empty) plus a real transcript on disk with
marker, token shapes and home paths. The guards at
`tests/run-experience-tests.sh:126-139` make fixture rot loud — verified by
mutating the fixtures, not just the code (M4, M5).

### Mutation results

| # | Mutant | Result |
| --- | --- | --- |
| M1 | `rmtree(out_dir)` restored in `write_dataset` | **killed** — 5 fails (Part C) |
| M2 | log body read into `trails[].source.log_body` | **killed** — 4 fails |
| M3 | `log_name` keeps full path (`str` not `.name`) | **killed** — 3 fails |
| M4 | fixture rot: all `"log"` back to `""` (the original F2 cause) | **killed** — 2 fails |
| M5 | fixture transcript deleted from disk | **killed** — 3 fails |
| M6 | `clean_html()` made a no-op | **killed** — 1 fail |
| M7 | `data/` exclusion removed from `clean_html` | survived — **equivalent** |
| M8 | `write_dataset` early-returns when `index.json` exists | survived — **equivalent** |
| M8b | data step rewrites stale content (true no-op refresh) | **killed** — 1 fail |
| M9 | PMI P2 gate `and` → `or` | **killed** — 3 fails |
| M10 | Phase 0 cap `P2` → `P3` | **killed** — 2 fails |
| M11 | join company-id validation bypassed | **killed** — 1 fail |

M1–M3 independently reproduce the producer's claimed table exactly. M4–M11 are
mine; the producer did not test them.

**Equivalence proven, not assumed:**

- **M7** — `data/` holds only `index.json`: verified `0` `*.html` files under
  `data/` (nothing for the unlink loop to take) and the dir is never empty
  (nothing for the prune loop to take). The exclusion is defensive, correct to
  keep, unobservable today.
- **M8** — `rmtree(data_dir)` runs *before* the mutated guard, so `index.json`
  never exists at that point and the early return is unreachable. Replaced with
  M8b, which forces a genuine stale refresh and **is** caught — so the "stale
  stamp gone" assertion is real.

### SYNTHESIS contract, PMI P2 gate, joins — re-checked

The revise diff touches only cleaning logic:

```
$ git diff 3682027..1823655 --stat -- scripts/
 scripts/experience-build.sh |  4 ++--
 scripts/experience_build.py | 22 ++++++++++++++++++++++
 scripts/experience_data.py  | 15 +++++++++++----
```

`experience_data.py` changes are confined to `write_dataset()` and the
`--no-clean` help string. Projection, PMI and join logic are byte-identical to
the reviewed commit, so loop-1's verification carries. Spot-checked anyway with
live mutants M9/M10 (PMI P2 gate + Phase 0 cap) and M11 (joins cannot invent a
company) — all killed. `docs/experience.md:40-43` documents the ownership split
and matches observed behavior.

## Decisions

- Re-derived F1/F2 from the failing behavior rather than trusting the
  producer's evidence block; the three claimed mutants were re-run from scratch.
- Added fixture-level mutants (M4, M5). F2 was a *fixture* defect, so mutating
  only code would have left the new guards themselves unverified.
- Reported M7/M8 as equivalent with proof instead of filing them as coverage
  gaps — matching loop-1's handling of M11/M12.

## Open questions / follow-ups (non-blocking, do not hold the merge)

- **F3** still open: `counts.unlinked_trails` is documented but unasserted
  (`grep -c unlinked_trails tests/run-experience-tests.sh` → `0`).
- **F4** still open: `handoff_truncated` remains undocumented
  (`grep -c handoff_truncated docs/experience-data.md` → `0`).
- Both were explicitly non-blocking and out of scope for an F1/F2-only revise.
  Worth a small follow-up PR.
- Producer's own note stands: if a future phase ships real non-HTML assets,
  `clean_html()`'s empty-dir prune should be revisited (M7 stops being
  equivalent at that point).

## Do not repeat

- Do not "simplify" the two-sided clean split back into one rmtree — M1 and M6
  fail in opposite directions and both are now guarded.
- Do not set fixture `"log"` fields back to `""` to quiet anything; M4 shows
  the vacuity guards fire immediately.
- Do not re-file M7/M8 as bugs. They are equivalent mutants with proof above.
