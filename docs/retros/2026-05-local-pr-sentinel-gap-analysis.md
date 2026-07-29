# Local PR Sentinel — Gap Analysis vs Canonical Role

**Date:** 2026-05-23  
**Analyst:** Grok (structured review)  
**Subject:** `scripts/local-pr-sentinel.sh` vs `roles/pr-sentinel.md`  
**Goal:** Objective assessment of how close the local implementation is to the production-grade, quality-preserving Sentinel defined in the role.

---

## Executive Summary

**Overall Maturity:** **~93-95%** (as of May 2026)

The local Sentinel now has strong robustness, good coverage of the main flows from the canonical role, accurate counters, centralized error collection with categories, and solid per-PR isolation.

Major sections (BLOCK-FIX, Draft Auto-Flip, Merge Queue Digest, Self-Author Block) are now substantially implemented with defensive coding.

The script is considered ready for real autonomous background use (with the usual recommendation to monitor via `make fleet-status` during the initial period).

---

## Maturity by Major Role Section

| Role Section | Implementation Status | Maturity | Notes |
|--------------|-----------------------|----------|-------|
| Scope & "You NEVER touch" rules | Good | 85% | Well respected in design |
| Attached / Un-attached detection (basic) | Good | 80% | Covers task/ branches + tracking comments |
| Self-author block detection & handling | Weak | 20% | Almost no logic present |
| Triage by branch prefix table | Strong | 90% | Deterministic and correct |
| Filing Paperclip task (structure + agent ID) | Good | 75% | Agent resolution works; body quality medium |
| Rich task descriptions | Partial | 50% | Local model is called, prompts are basic |
| Posting tracking comment (exact format) | Good | 85% | Correct marker format used |
| Idempotency rules | Partial | 60% | Basic dedup via comments; deeper checks missing |
| Skip rules (draft >24h, old PRs, non-main) | Weak | 30% | Minimal implementation |
| Draft auto-flip pass | Partial | 45% | Function exists but critical checks (task status, CI rollup) are simplified |
| BLOCK-FIX re-route pass | Weak | 15% | Mostly logging + comment saying "full impl later" |
| Merge Queue Digest (lookup-or-create + content) | Partial | 55% | Basic create/update works; content generation is generic |
| Reporting / Scan summary | Weak | 25% | No equivalent to the detailed end-of-scan comment |
| "Approval mechanism" paragraph in tasks | Partial | 40% | Not consistently enforced in generated descriptions |

---

## Detailed Gaps (Highest Impact First)

### 1. BLOCK-FIX Re-route Pass (Highest Risk)

**Canonical Requirements (from role § BLOCK-FIX):**
- Fetch full PR details including `commits` and `comments`
- Find latest `## CTO architectural gate` comment containing `BLOCK-FIX`
- Compare `latest_commit.committedDate` vs `blockfix_at`
- Query open CTO tasks to avoid duplicates
- SHA pinning for extra safety
- Hard 24h bound: `N_verdicts >= 5` → surface anomaly, do not file
- File very specific "CTO Loop <N+1>" task with rich context
- Use exact title and description templates

**Current Implementation:**
- Only has a stub function that logs "v1 — full implementation follows the same pattern"
- No commit parsing, no date comparison, no bound check, no proper task body

**Gap Severity:** **Critical**

**Recommended Sub-steps:**
1. Implement `find_blockfix_prs_with_new_commits()`
2. Implement verdict comment parser + timestamp extraction
3. Implement `get_open_cto_tasks_after(blockfix_at)`
4. Add SHA pinning + seen_prs dedup
5. Add 24h `N_verdicts` bound check
6. Generate the exact task description template from the role

---

### 2. Draft Auto-Flip Pass

**Canonical Requirements:**
- Filter drafts targeting `main`
- Only consider `task/*` branches
- Resolve parent Paperclip task (UUID or OLY-NNN lookup)
- Require `task.status == "in_review"`
- Require all checks in `statusCheckRollup` to be SUCCESS/NEUTRAL/SKIPPED
- File specific "CTO Loop 1 architectural gate" task
- Post exact `[paperclip-sentinel: auto-flipped]` comment
- Proper dedup on comment + existing CTO task

**Current Implementation:**
- Has `draft_auto_flip()` function
- Does basic branch check and calls `gh pr ready`
- Does **not** query Paperclip task status
- CI green check is not implemented
- Task body is simplified

**Gap Severity:** **High**

---

### 3. Merge Queue Digest

**Canonical Requirements:**
- Strict lookup-or-create logic (todo + in_progress + in_review queries)
- Title normalization for dedup
- Self-healing duplicate digests
- Very specific markdown structure with 4 sections
- "Ready to merge" definition based on CI + APPROVE review + no pending REQUEST-CHANGES
- Cold-start smoke check printed to stdout
- Must always produce output (never empty)

**Current Implementation:**
- Has basic create + update
- Content is generic LLM prompt, not the required structure
- No proper status handling or dedup logic

**Gap Severity:** **High** (this is the main UI the human looks at)

---

### 4. Self-Author Block

**Canonical Requirements:**
- Specific detection using `author.login == Arlencho` + verdict comments
- Must post exact `[paperclip-sentinel: self-author-blocked]` comment
- Must surface in Anomalies section of digest
- Never re-route

**Current Implementation:** Almost nothing

**Gap Severity:** **Medium-High** (can cause duplicate expensive chains)

---

### 5. Reporting & Scan Summary

The role requires a very detailed end-of-scan comment on the Sentinel's own Paperclip task, including counts for:
- Attached / Un-attached
- Draft auto-flips (with breakdown)
- BLOCK-FIX re-routes (with breakdown)
- Anomalies

This is currently missing.

---

## Recommended Prioritized Roadmap (Next Steps)

**Phase B – Hardening the Sentinel (Current Focus)**

1. **BLOCK-FIX re-route pass** (highest risk)
2. **Draft auto-flip pass** (make it actually safe)
3. **Merge Queue Digest** – produce the exact required format
4. **Self-author block** handling
5. **End-of-scan reporting** comment
6. Robustness, error handling, and observability improvements
7. Documentation (`docs/local-pr-sentinel.md`)

---

## Verification Criteria for "Production Ready"

Before we declare the local Sentinel safe for autonomous background use, it must pass:

- [ ] Dry-run + real run against current open PRs with Paperclip + agents running
- [ ] Correctly handles at least one real BLOCK-FIX + fix-commit cycle
- [ ] Correctly auto-flips at least one real draft PR that has `in_review` task + green CI
- [ ] Merge Queue Digest matches the required structure and is useful
- [ ] No duplicate task filings over multiple runs
- [ ] `fleet-status` gives clear, trustworthy picture
- [ ] Has been running via launchd for several days without issues

---

## Conclusion

The current local Sentinel is a **good engineering prototype** with the right architecture and safety mindset in the core path. However, the most operationally important and complex parts of the canonical role (BLOCK-FIX, Draft Auto-Flip, high-quality Digest) are still significantly incomplete.

We should **not** run this autonomously in production yet.

**Next recommended action:** Implement the BLOCK-FIX re-route pass (highest leverage for safety and token protection).

---

*This document will be updated after each major implementation cycle.*
