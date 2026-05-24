# Local PR Sentinel — Live Validation Runbook

**Goal:** Confirm that the Local PR Sentinel works correctly in production conditions with Paperclip + real agents over multiple days.

**Duration:** Recommended 3–5 days of natural operation + targeted test cases.

---

## Prerequisites

- Paperclip running (`make paperclip-up`)
- At minimum these agents hired in the Olympus company:
  - CTO
  - DevOps Engineer
  - (Optional but recommended) Backend Engineer, Frontend Engineer
- GitHub CLI authenticated with push rights to the repo
- Local Sentinel installed as background service (`make local-sentinel-install`)
- You have `make fleet-status` as your daily monitoring command

---

## Phase 1: Baseline (Day 0)

1. Run:
   ```bash
   make fleet-status
   make local-sentinel-dry
   ```
2. Note the current state of:
   - Open PRs
   - Merge Queue Digest
   - Local Sentinel last run + counters
   - Any existing errors

3. Confirm the background service is running:
   ```bash
   make local-sentinel-status
   ```

---

## Phase 2: Natural Operation (Days 1–3)

Let the system run normally for 2–3 days.

Monitor daily with:

```bash
make fleet-status
```

Watch for:
- New tasks appearing in Paperclip from the Local Sentinel
- Merge Queue Digest being updated
- No duplicate filings
- Reasonable counter growth

---

## Phase 3: Targeted Test Cases (Do these deliberately)

You should try to trigger each of the following scenarios at least once:

### Test Case A: New Unattached Feature/Fix PR

1. Create (or wait for) a new PR on a `feat/*` or `fix/*` branch that is **not** on a `task/*` branch.
2. Expected behavior:
   - Local Sentinel detects it as unattached
   - Files a task assigned to CTO
   - Posts the tracking comment on the PR

### Test Case B: Draft Auto-Flip

1. As a producer, open a draft PR on a `task/oly-XXX` branch.
2. Move the corresponding Paperclip task to `in_review`.
3. Make sure CI is green on the PR.
4. Expected:
   - Local Sentinel detects the draft + `in_review` task + green CI
   - Runs `gh pr ready`
   - Files a "CTO Loop 1" task
   - Posts the auto-flipped comment

### Test Case C: BLOCK-FIX + Fix Commit

1. Have the CTO give a `BLOCK-FIX` on a PR.
2. Push a new commit (even a trivial one) on that PR.
3. Expected:
   - Local Sentinel detects the new commit after BLOCK-FIX
   - Files the correct "CTO Loop N+1" re-review task
   - Does **not** create duplicates if already handled

### Test Case D: Self-Author Block (Safety)

1. Create a PR from the `Arlencho` account on a non-`task/*` branch.
2. Have it receive at least one verdict comment (e.g., from a previous manual review).
3. Expected:
   - Local Sentinel detects it as self-author-blocked
   - Does **not** file a new routing task
   - Posts the `[paperclip-sentinel: self-author-blocked]` comment
   - Surfaces it in the Merge Queue Digest Anomalies section

### Test Case E: Error Resilience (Optional but valuable)

1. Temporarily stop Ollama or Paperclip for one cycle.
2. Confirm the script does not crash.
3. Confirm errors appear in `fleet-status` under "Recent errors".
4. Bring the service back and confirm recovery.

---

## Phase 4: Validation Criteria (Pass/Fail)

At the end of the test period, verify:

- [ ] No duplicate tasks were created for the same PR
- [ ] All expected routing tasks appeared in Paperclip
- [ ] Draft auto-flips happened correctly when conditions were met
- [ ] BLOCK-FIX re-routes were created with correct Loop numbers
- [ ] Merge Queue Digest remained useful and up to date
- [ ] `make fleet-status` gave clear, trustworthy information throughout
- [ ] Error reporting worked when services were intentionally degraded
- [ ] No surprising behavior or crashes over multiple days

---

## How to Monitor During Validation

**Daily (or more):**
```bash
make fleet-status
```

**After interesting events:**
```bash
make local-sentinel-logs | tail -100
```

**In Paperclip, regularly check:**
- "Local PR Sentinel - Activity Log" (for structured scan summaries)
- "Merge Queue Digest — Olympus"
- Newly created tasks from the Local Sentinel

---

## Rollback / Emergency

If something goes wrong:

```bash
make local-sentinel-uninstall     # Stop background runs immediately
```

You can always fall back to the old Paperclip PR Sentinel (with heartbeat) if needed, though it is more expensive.

---

## Success Definition

You have successfully validated the Local PR Sentinel when:

- It has been running autonomously for several days
- All major code paths (triage, draft flip, BLOCK-FIX, self-author, digest) have been exercised with real data
- `make fleet-status` has become your trusted single source of truth for the discovery layer
- You feel confident leaving it as the primary always-on discovery mechanism

Once validated, you can confidently rely on the hybrid model:
**Cheap autonomous discovery (Local) + High-quality execution (Grok + Claude scoped agents) + Strong governance (Paperclip).**

---

*Run this checklist when you have a stable Paperclip environment with agents hired.*
