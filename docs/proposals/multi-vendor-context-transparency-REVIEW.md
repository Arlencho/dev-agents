# Objective review: three multi-vendor context proposals

| Field | Value |
|-------|-------|
| **Date** | 2026-07-20 |
| **Reviewer** | Grok (xAI) — comparative review, not an advocate for any single draft |
| **Inputs** | Claude counterpart · Grok full draft · Kimi full draft |
| **Question** | Which proposal is best *as a solution*, and is a fourth synthesis better? |

---

## Documents reviewed

| ID | Path | Nature |
|----|------|--------|
| **P1 Claude** | `docs/proposals/multi-vendor-context-transparency.claude.md` | Companion / diff on Grok; trust & verification |
| **P2 Grok** | `docs/proposals/multi-vendor-context-transparency-grok.md` | Standalone system design |
| **P3 Kimi** | `docs/proposals/multi-vendor-context-transparency-kimi-version.md` | Standalone + file-level Phase 1 plan |

---

## Evaluation criteria (solution-first)

| Criterion | Weight | What “good” means |
|-----------|--------|-------------------|
| **Correct problem frame** | High | Diagnoses lost *intent*, not “need more tokens” |
| **Trust model** | High | Does not treat model self-report as ground truth |
| **Implementability on this fleet** | High | Fits bash/git/preamble/dispatch; Phase 1 is concrete |
| **Anti-rot / anti-telephone** | Medium | Long waves don’t degrade intent |
| **Vendor asymmetry** | Medium | Uses sticky/native memory where safe |
| **Falsifiability** | Medium | Can prove the brain helps before Phases 2–5 |
| **Completeness as a solo doc** | Medium | Can ship from one document alone |
| **Over-design risk** | Medium | Avoids schema/daemon theater before habit exists |

---

## Scorecard (1–5, higher = better for *solution quality*)

| Criterion | P1 Claude | P2 Grok | P3 Kimi |
|-----------|:---------:|:-------:|:-------:|
| Problem frame | 5 | 5 | 5 |
| Trust / verification | **5** | 2 | 3 |
| Implementability / Phase 1 | 2 | 3 | **5** |
| Completeness (standalone) | 1 | **5** | 4 |
| Anti-drift (telephone) | **5** | 3 | 3 |
| Vendor asymmetry | **5** | 3 | 4 |
| Falsifiability (A/B) | **5** | 2 | 4 |
| Human ops (board / DoD) | 3 | 4 | **5** |
| Over-design restraint | 3 | 3 | **5** |
| Failover / partial work | 3 | **4** | 4 |
| **Weighted sense (qualitative)** | Trust champion, not a plan | Architecture champion | Ship champion |

---

## What each proposal gets uniquely right

### P2 Grok — best *architecture spine*

- Clear north star: orchestrator memory > vendor session memory.  
- Full package: handoff fields, inject order, sticky vs cold, wave board, provenance, phased 0–5, fit to existing scripts.  
- Best single document if you need a **vision + schema sketch** everyone can share.

**Gap:** treats the ledger as largely trustworthy shared memory. Under-specifies verification, prompt-injection across vendors, lossy re-summarization of handoffs, and a hard kill-experiment if the brain doesn’t help.

### P1 Claude — best *trust model* (and the only real disagreement that matters)

- Handoffs are **claims**, verified against git (files_touched ↔ diff, head_sha real, evidence re-runnable or marked unverified).  
- Cross-vendor handoff text = **untrusted input** (advisory, delimited, not commands).  
- Immutable raw ledger; **only orchestrator** compacts for inject.  
- Brain is a **floor**, not a ceiling (use Claude/Kimi/Grok native continuity inside a lane).  
- Intent addressable via git (`why file:line`).  
- **A/B falsifiability** before Phases 2–5.

**Gap:** not implementable alone — explicitly a counterpart. Some verification (re-run every evidence cmd on every accept) is heavy for day one if taken literally.

### P3 Kimi — best *path to value*

- “Team with a wiki” reframe is operationally accurate.  
- **Markdown handoffs first, schema later** — correct sequencing for agent behavior change.  
- File-level Phase 1: preamble.sh, run-remote.sh, one charter, one kimi→claude proof pair, measure intent-misunderstand loops.  
- Continuity registry for session resume IDs.  
- Tagged learnings retrieval; glossary + DoD; soft warning on missing handoff.  
- Explicit non-goal: no validator before anyone has written a note.

**Gap:** weaker trust story than Claude; markdown harder to gate machine-side later unless Tier 2 freezes schema; product-repo vs wave-plans home still a bit soft; less depth on immutable-raw vs summary drift.

---

## Head-to-head conclusions

| Question | Winner |
|----------|--------|
| Best **standalone vision** | **Grok** |
| Best **critical safety / trust insights** | **Claude** |
| Best **first sprint to ship** | **Kimi** |
| Best **document to implement from *alone*** | **Neither pure winner** — Grok without Claude is naive on trust; Claude without Grok/Kimi is incomplete; Kimi without Claude under-verifies |

**If forced to pick one of the three as-written for the *best overall solution design*:**

### Runner-up: Kimi (P3)
Wins on **shipping the habit** that all three need. Closest to something you can dispatch as a one-wave change tomorrow. Loses on trust architecture.

### Second: Grok (P2)
Wins on **coherent system design**. Best foundation document. Loses if implemented naively as “write JSON and trust it.”

### Not a full proposal: Claude (P1)
Wins on **what must not be wrong**. Highest signal density per page. Cannot be the only approved doc.

---

## Official pick among the three

**There is no single best full proposal.**  
**Best combination of correctness + shippability:**

1. **Adopt Grok as the system shape** (brain, handoff as unit, sticky/cold, board, phases).  
2. **Adopt Claude’s trust amendments as non-negotiable requirements** (verify claims, untrusted cross-vendor inject, immutable ledger, A/B).  
3. **Adopt Kimi’s Phase 1 execution plan almost verbatim** (md notes first, soft gate, preamble inject, one producer→critic proof, measure).

If you must put a **single name** on “best of the three as a *base* to build from”: **Grok (P2)** — then **immediately fold Claude A–F and Kimi Tier-1 plan into it** before coding.  
If you must put a **single name** on “best of the three as a *first PR*”: **Kimi (P3)** — then add Claude’s claim-verification and untrusted-input charter language in the same PR scope.

---

## Is a better fourth proposal justified?

**Yes.** None of the three is optimal alone:

| Missing if you only pick… | |
|---------------------------|--|
| Grok only | Trusting liars; no A/B; telephone risk |
| Claude only | No Phase 1 file plan; incomplete spine |
| Kimi only | Soft trust; delayed structure for gates/failover analytics |

A **synthesis** that is Grok-shaped, Claude-hardened, and Kimi-sequenced is strictly better than any single draft.

That document is written as:

**`docs/proposals/multi-vendor-context-transparency-SYNTHESIS.md`**

(See companion file for the full recommended design.)

---

## Decision matrix for Arlen

| If you care most about… | Do this |
|-------------------------|---------|
| Shipping this week | Kimi Phase 1 + Claude “untrusted claim” charter line + light git check on files_touched |
| Long-term architecture doc | Grok + Claude amendments as the spec |
| Correct *solution* (recommended) | **Approve the SYNTHESIS** as the canonical proposal; archive the three as historical alternatives |

---

## One-sentence verdict

**Grok built the brain; Claude taught us not to trust it blindly; Kimi told us how to start tomorrow — the best proposal is all three fused, not any one alone.**
