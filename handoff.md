# CRITIC VERDICT — PR #49 `feat/fleet-desk-phase1-ui`

**VERDICT: REVISE** — 2 executable failures, both in the honesty surfaces this
PR exists to build. Loop 1 of 2.

Verified independently on `feat/fleet-desk-phase1-ui` @ `fd3e78c`. Producer
handoff claims were re-derived from the code, not taken on trust.

## What passed (re-verified, not assumed)

| Gate | Result | Evidence |
|---|---|---|
| (5) `experience_data.py` join/PMI untouched | **PASS** | `git diff --stat origin/main...HEAD` lists only `docs/experience.md`, `handoff.md`, `scripts/experience_build.py`, `tests/run-experience-tests.sh` |
| (5) renderer still JSON-only | **PASS** | `experience_build.py:855` is the only read (`data/index.json`); no `subprocess`, no git, no repo walk |
| (3) skill history: 3 states never conflated | **PASS** | no-git render → "git history unavailable…", 0 history cards, 0 rev counts. `available:true, revisions:0` → "no commits recorded yet", 0 history cards. Present → real subjects + rev count |
| (4) Home/About | **PASS** | home `critic pairs = 1`; about renders `gh enrichment: disabled — …`, `method branch_pairing`, full `critic_rate_basis` |
| (1) PR row + pairing links | **PASS** | injected `pr_url` → `PR #49 open`; `Reviewed by`/`Reviews` resolve (dir at `:480` uses the same raw `task_id` as `pair_link`, and `assert_links_resolve` crawls it) |
| (2) no false "capped at P2" | **PASS** | no such copy in the renderer; guard test still green |
| (6) `make test` | **PASS** | `215 passed, 0 failed`; "All test suites passed." |
| (6) smokes non-vacuous | **PASS** | reverting **only** `experience_build.py` to `origin/main` turns **20** new assertions RED (`195 passed, 20 failed`) — genuinely targeted, not decorative |

The test work here is strong. The two defects below are the ones no assertion covers.

---

## C1 — A sub-P3 role advertises the P3 gate as satisfied

`scripts/experience_build.py:571-583`

`proven_loop_evidence` is computed independently of the band
(`experience_data.py:1022`), so a role can carry evidence while **failing the P2
outcome gate**. The renderer branches on evidence only, never on band. The
negative branch says the gate "is not met"; the positive branch says nothing
about the gate at all. Result: the two pages below are **byte-identical** in this
region, and only the badge distinguishes them.

Already reachable in the shipped fixture — no synthetic input needed:

```
fixture-runner  | band P1 | n_done 4 (<5, P2 outcome gate FAILS) | ev ['fixture-pack promotes lesson-one']
fixture-builder | band P3 | n_done 6                             | ev ['fixture-pack promotes lesson-one']
```

Rendered `role/fixture-runner/index.html` (band **P1**):

> …Display capped at P3 — **P3 needs proven-loop evidence**: a specialized pack
> with version ≥ 2 and ≥ 2 recorded revisions, or a specialized pack citing a
> promoted learning. **Proven loop evidence (P3 gate): fixture-pack promotes lesson-one**

The page states the P3 requirement, then presents evidence satisfying it, and
never says the role is still short of P2. That is the same overclaim class the
"no false capped at P2" guard exists to prevent, pointed the other way.

**Repro:** `python3 scripts/experience_data.py --repo tests/fixtures/experience-mini --out /tmp/fx --no-gh && python3 scripts/experience_build.py --out /tmp/fx` → open `/tmp/fx/role/fixture-runner/index.html`.

## C2 — Cited issue refs are silently dropped when resolution is partial

`scripts/experience_build.py:392-406`

`if resolved:` **replaces** the whole Links row; the raw `issue_links` fallback is
reached only when *nothing* resolved. So one hit hides every miss. This is a
regression: before this PR all refs rendered via the raw branch.

It destroys a distinction the data layer builds on purpose —
`experience_data.py:875` deliberately keeps product-repo refs unresolved "rather
than pointing at an unrelated dev-agents issue". The renderer then discards
exactly those. `resolved[:8]` (`experience_data.py:885`) can also truncate
silently, with no note (skills got a truncation note; issues didn't).

Injected 3 cited refs, 1 resolvable, rendered:

```
Links  #12 (open · only this one resolved)

'#12'                     present in page: True
'other/product/issues/9'  present in page: False   <-- cited, dropped
'#77'                     present in page: False   <-- cited, dropped
```

---

## Failing tests (RED on `fd3e78c`, preconditions green)

Proposed for the Phase 1 section of `tests/run-experience-tests.sh`. Not
committed — the branch suite stays green until the producer fixes and lands
these together.

```bash
# ── CRITIC C1: evidence must not overclaim the P3 gate on a sub-P3 role ──
grep -q 'class="pmi band-p1">P1' "$FIXOUT/role/fixture-runner/index.html" \
  && ok "precondition: fixture-runner is P1" || bad "precondition: fixture-runner is P1"
grep -q 'Proven loop evidence (P3 gate)' "$FIXOUT/role/fixture-runner/index.html" \
  && ok "precondition: P1 role renders the P3-gate evidence list" \
  || bad "precondition: P1 role renders the P3-gate evidence list"
grep -q 'P3 gate is not met\|does not meet the P3 gate\|not met' \
     "$FIXOUT/role/fixture-runner/index.html" \
  && ok "P1 role with evidence states the P3 gate is still unmet" \
  || bad "P1 role with evidence states the P3 gate is still unmet"

# ── CRITIC C2: cited issue refs survive partial gh resolution ──
# inject into $INJ/data/index.json: issue_links = ["#12", "https://github.com/other/product/issues/9", "#77"]
# with issue_links_resolved = [ {ref:"#12", ...} ] only, then re-render.
for ref in '#12' 'other/product/issues/9' '#77'; do
  grep -qF "$ref" "$INJ/trail/conductor-fixture-note/index.html" \
    && ok "Links row still shows cited ref $ref" || bad "Links row still shows cited ref $ref"
done
```

Observed:

```
== CRITIC C1 ==
  ok   precondition: fixture-runner is P1
  ok   precondition: P1 role renders the P3-gate evidence list
  FAIL P1 role with evidence states the P3 gate is still unmet
== CRITIC C2 ==
  ok   Links row still shows cited ref #12
  FAIL Links row still shows cited ref other/product/issues/9
  FAIL Links row still shows cited ref #77
== 3 passed, 3 failed ==
```

## Scope note

Both fixes are renderer-only and land inside the two blocks already touched by
this PR. No data-contract change, no restyle, no new CSS. Direction is the
producer's call — I do not prescribe copy.

## Next (loop 2)

Re-run C1 + C2 plus the full suite. If the producer disputes C1 as
copy-not-defect, that escalates to CTO rather than a third loop.
