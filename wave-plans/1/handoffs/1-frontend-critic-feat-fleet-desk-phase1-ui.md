# CRITIC VERDICT — PR #49 `feat/fleet-desk-phase1-ui`

**VERDICT: APPROVE** — both blocking defects from loop 1 are closed, and the
fixes are pinned by assertions that I killed by mutation. Loop 2 of 2. No third
loop needed; nothing escalates to CTO.

Verified independently on `feat/fleet-desk-phase1-ui` @ `8a22cd2`
(`git rev-parse HEAD` == `origin/feat/fleet-desk-phase1-ui`). Producer handoff
claims were re-derived by execution, not taken on trust.

## C1 — CLOSED. Sub-P3 roles no longer advertise the P3 gate as satisfied

`scripts/experience_build.py:574` now branches on `evidence and pmi["band"] == "P3"`.

Rendered from the shipped fixture
(`python3 scripts/experience_data.py --repo tests/fixtures/experience-mini --out /tmp/fx --no-gh && python3 scripts/experience_build.py --out /tmp/fx`):

| role | band | n_done | ev | rendered copy |
|---|---|---|---|---|
| `fixture-builder` | **P3** | 6 | 1 | `Proven loop evidence (P3 gate):` + list — positive framing kept |
| `fixture-runner` | **P1** | 4 | 1 | `…recorded, but the P3 gate is not met — the role is still short of the P2 outcome bar (band P1), so this evidence cannot promote it yet.` |
| `fixture-critic` P0, `fixture-flaky` P1, `fixture-scribe` P0, `fixture-solo` P2, `fixture-veteran` P2 | — | — | 0 | unchanged honest `none recorded … is not met` branch |

The two pages that were byte-identical in this region now differ. Requirement
"only band P3 keeps positive proven-loop framing" holds.

**Stronger than the fixture — the copy is *entailed*, not merely plausible.** I
exhausted the band × evidence state space against `compute_pmi` directly
(n 0–8 × n_done × success ∈ {0,.5,.6,.75,.8,1} × evidence ∈ {∅,{e}}):

```
reachable (band, has_evidence):
   ('P0', False) ('P0', True) ('P1', False) ('P1', True) ('P2', False) ('P3', True)
evidence + band P2 reachable? -> False
sub-P3 WITH evidence -> [('P0', True), ('P1', True)]
```

Because `experience_data.py:950` makes band P3 ⟺ `p2_ok and evidence`, a role
carrying evidence below P3 has `p2_ok == False` **by construction**. So "still
short of the P2 outcome bar" can never be a false statement, in any input. The
band domain is exactly `P0|P1|P2|P3` (`experience_data.py:950,956,969,981`), so
the `== "P3"` equality is exhaustive — no band escapes into the wrong branch.

Full page context on the P1 role is coherent end to end: badge `P1`, reason
`needs n_done≥5 for P2 (have 4)`, then the not-met evidence block. No residual
overclaim anywhere in the region.

## C2 — CLOSED. Cited refs survive partial resolution

`scripts/experience_build.py:393-405` unions instead of replacing:
`covered = {x["ref"] for x in resolved}`, `unresolved = [u for u in t["issue_links"] if u not in covered]`,
guarded by `if resolved or unresolved:`.

Probed by injecting into `data/index.json` and re-rendering — 5 cases, including
**3 the producer's test does not cover**:

| case | issue_links | resolved | cited refs dropped | rendered Links row |
|---|---|---|---|---|
| partial | 3 | 1 | **none** | `#12 (open · an issue) · https://…/other/product/issues/9 · #77` |
| none resolved | 3 | 0 | **none** | `#12 · https://…/other/product/issues/9 · #77` (raw branch intact, no regression) |
| empty | 0 | 0 | **none** | `none parsed` (preserved) |
| **truncation** | 12 | 8 | **none** | 8 enriched + `#9 · #10 · #11 · #12` raw |

The truncation case closes the `resolved[:8]` sub-point I raised in loop 1: refs
past the cap now fall through to the raw branch instead of vanishing.

**Contract-level soundness, not just probe-level.** `experience_data.py:884`
appends `{"ref": ref, **hit}` where `ref` is the *original token* being iterated,
so `covered` always holds the exact source string and the set-difference is
total. `parse_issue_links` (`experience_data.py:290-294`) dedupes and returns
`out[:8]`, so `issue_links` is ≤ 8 unique entries — `resolved[:8]` can never
truncate below it, and duplicate rendering is unreachable.

*(I constructed one synthetic duplicate — resolved `ref="#12"` while `issue_links`
held only the URL form — and it does render twice. I am **not** filing it: the
data layer cannot produce that pair, since the resolver derives `ref` from the
token it iterates. Reporting it would be a false positive.)*

## Loop-1 assertions: landed, green, and non-vacuous

Landed at `tests/run-experience-tests.sh:355-364` (C1) and `:574,590-594` (C2).

Green is worthless on its own, so I killed each fix and confirmed the assertion
dies with it:

| mutation | command | result |
|---|---|---|
| A — whole renderer → pre-fix `fd3e78c` | `git show fd3e78c:scripts/experience_build.py > …` | **218 passed, 3 failed** — exactly the 3 critic assertions RED, nothing else |
| B — C1 hunk only (`and pmi["band"] == "P3"` removed) | targeted edit | **220 passed, 1 failed** — only `P1 role with evidence states the P3 gate is still unmet` |
| C — C2 hunk only (union → replace) | targeted edit | **219 passed, 2 failed** — only the 2 dropped-ref assertions |

B and C are the decisive ones: each assertion is pinned to **its own** fix, not
passing incidentally off the other. Working tree restored to `8a22cd2` after
every mutation (`git status --short` clean, `git diff --stat` empty).

Whole Phase 1 block is non-vacuous too: reverting the renderer to `origin/main`
turns **22** assertions RED. The C2 pair is correctly *absent* from that list —
`main` has no resolution rendering at all, so its raw branch printed every ref.
That is the positive confirmation that C2 was a regression introduced by
`fd3e78c` and is now closed, rather than a pre-existing wart.

## Remaining gates (re-verified this loop, not carried forward)

| Gate | Result | Evidence |
|---|---|---|
| `make test` green | **PASS** | `221 passed, 0 failed` — "All test suites passed." |
| `experience_data.py` untouched | **PASS** | `git diff --stat origin/main...HEAD -- scripts/experience_data.py` → 0 lines |
| renderer JSON-only | **PASS** | no `subprocess`/`urllib`/`requests`/`socket`/git shell-out; sole input `data_path.read_text()` at `:869`. The `rglob`/`iterdir` at `:51-59` walk the **out** dir (pre-existing stale-page prune), never the repo |
| scope held | **PASS** | 4 files vs main: `docs/experience.md`, `handoff.md`, `scripts/experience_build.py`, `tests/run-experience-tests.sh`. No data-contract change, no new CSS |

## Non-blocking observations (do not action in this PR)

1. `proven_loop = True` still appears in the raw **PMI inputs** dump on a sub-P3
   page. It is a faithful echo of a JSON input under a table explicitly labelled
   `PMI inputs (from data/index.json)`, and the not-met copy sits directly above
   it. Changing it would misrepresent the JSON. Not a defect.
2. The C1 honesty grep's third alternative `\|not met` is broader than the other
   two. Mutation B proves it is currently pinned (no other "not met" on that
   page — only one of the three branches ever renders). Flagging only as
   optional future hardening.

## Loop accounting

Loop 1: 2 blocking defects. Loop 2: both closed, mutation-verified. Budget spent,
nothing outstanding. **Ship.**
