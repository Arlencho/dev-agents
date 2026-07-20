# Olympus — GO-LIVE from sandbox: issue audit + wave proposal

**Date:** 2026-07-21  
**Repo:** `Arlencho/olympus-platform`  
**Orchestration:** `dev-agents/companies/olympus.md`  
**Legal entity (company setup):** **Pelops AI AB**, org nr **559579-1574**  
  - Manifest: `companies/olympus.md` frontmatter (`legal_entity`, `legal_org_nr`) — commit `c2036fa`  
  - Claude memory: `~/.claude/projects/-Users-arlenrios/memory/pelops-ai.md` (indexed in MEMORY.md)  
**Stage today (docs):** Beta / sandbox Stripe + Duffel sandbox; live product URLs exist but **real payments blocked** on KYC / merchant-of-record under Pelops.

---

## Goal of this task (single planning ticket)

1. Inventory **open GitHub issues** on `Arlencho/olympus-platform`.  
2. Classify each as: **GO-LIVE blocker / P1 pre-live / P2 post-soft-live / Hermes-only / noise**.  
3. Produce a **dispatchable multi-wave plan** (WAVE | AGENT | TASK | BRANCH) to kickstart **GO-LIVE execution from sandbox** — not a feature free-for-all.  
4. Fold in **company/legal readiness** (Pelops AI AB) as human + devops tracks, not only code.

**Out of scope for wave 0:** implementing features; Hermes chat-native booking as the critical path (parallel track only).

---

## Context snapshot (2026-07-21 issue pull)

Hundreds of open issues; high-signal **GO-LIVE / sandbox → real money** candidates include:

| # | Title (short) | Why it matters for GO-LIVE |
|---|---------------|----------------------------|
| **1882** | Rate limiter bypass via `X-Forwarded-For` (anon LLM/SerpAPI spend) | **P1 security** — uncapped cost in public mode |
| **1883** | Prod Postgres single-zone, never-executed restore drill | **P1 ops** — durability before real bookings |
| **1884** | Migrations run AFTER traffic switch | **P1 deploy safety** |
| **1994** | Hermes pay-link amount server-truth + expire sessions | **Before public payments** (label says so) |
| **1967** | Production `validate()` gates per binary / secret surface | Hardening for prod binaries |
| **1913** | QA coverage payments/auth before next payments wave | Gate for payment work |
| **1987 / 1770** | Booking store integration test collisions | CI trust for booking path |
| **1639** | Composer disabled at flight/stay pick | **P1 product** — core Atlas flow broken |
| **1702** | Purge invented numbers on product surfaces | Trust / compliance copy |
| **1724** | AI-native cabin selection (in progress) | Product depth; not always a hard legal go-live |
| **284** | Human: DPAs + SCCs with vendors | **Human-task** compliance |
| **404 / 400 / 278** | Compliance / access matrix / DD trackers | Launch checklist debt |
| **1649–1651** | Duffel settlement currency EUR + currency PRD | Money path correctness |
| Pelops memory | Footer/terms/privacy; Stripe/GCP/Vercel under Pelops | **Human / ops** company setup |

**De-prioritize for first GO-LIVE waves (parallel, not blocking soft-live):** most `epic:hermes` product expansion (#1991, #1898 epic work beyond pay-link security), open-jaw features, weekly digest, flaky vitest P3s, em-dash voice polish.

---

## Proposed wave structure (draft — refine after full audit)

### Wave 0 — Human + inventory (no product code)

| Who | Work |
|-----|------|
| **You (Arlen)** | Confirm GO-LIVE definition: soft-live (sandbox Stripe + public product) vs hard-live (Stripe live + Pelops MoR) |
| **Human** | Pelops checklist: Stripe/GCP/Vercel billing entity; DPAs #284; legal copy when hard-live |
| **plan-critic / orchestrator** | This audit → freeze wave plan + label issues `golive:blocker` / `golive:p1` |

### Wave 1 — Security & cost blast radius (must before public spend)

1. `go-backend` — #1882 XFF rate-limit fix + tests  
2. `security-reviewer` — review #1882  
3. `go-backend` — #1967 production validate() scoping (if still open after audit)  
4. `devops` — confirm production env gates / secrets inventory  

### Wave 2 — Deploy & data safety

1. `devops` — #1884 migrate-before-traffic (or expand/contract order fix)  
2. `devops` — #1883 HA + restore drill plan (may split human vs agent)  
3. `test-engineer` — booking store tests #1987 / #1770 green on main  

### Wave 3 — Money path (still sandbox until KYC)

1. `go-backend` + `security-reviewer` — #1994 pay-link integrity if Hermes in scope; else web checkout payment integrity checklist  
2. `qa` / `test-engineer` — #1913 coverage gate on payment/auth  
3. `devops` — Duffel org settlement currency #1649 if hard-live path needs EUR  

### Wave 4 — Product trust on critical path (Atlas web)

1. `web-frontend` — #1639 composer at pick step  
2. `web-frontend` — #1702 invent-numbers purge (scope to checkout/results)  
3. `web-frontend` — #1885 dead `/checkout` navigation if still open  
4. Critics on each PR  

### Wave 5 — Soft-live checklist (orchestrator/docs)

- E2E smoke: search → select → pay **sandbox** → confirmation  
- Monitoring / error budget (Sentry free tier per COST_INVENTORY)  
- Update `companies/olympus.md` Active phase: GO-LIVE wave id + definition of done  
- **Do not** flip Stripe live until Pelops KYC + human sign-off  

---

## Paste-ready task (Claude CLI / fleet agent)

Copy everything below into Claude (or dispatch as `plan-critic` / `orchestrator`):

```text
Repo: https://github.com/Arlencho/olympus-platform.git
Branch: plan/olympus-golive-from-sandbox-2026-07-21
Role: plan-critic (or orchestrator) — PLAN ONLY, no product feature implementation.

Context (must read):
- dev-agents companies/olympus.md — legal_entity: Pelops AI AB, legal_org_nr: 559579-1574 (c2036fa)
- Claude memory pelops-ai.md — company setup propagation checklist
- docs/ARCHITECTURE.md — sandbox Stripe, Duffel sandbox, beta stage
- Open GitHub issues: gh issue list -R Arlencho/olympus-platform --state open

Task:
1. List open issues (use gh). Group into: GO-LIVE blocker | P1 pre-live | P2 later | Hermes parallel | ignore/noise.
2. Define GO-LIVE for this wave series:
   - Soft-live = public product + sandbox payments + Pelops entity named in ops docs
   - Hard-live = Stripe live + Pelops merchant-of-record (explicitly human-gated)
3. Write a multi-wave dispatch plan to:
   docs/plans/2026-07-21-olympus-golive-from-sandbox.plan.md
   (or wave-plans/olympus-golive-from-sandbox-2026-07-21.plan in dev-agents)
   Format: WAVE | AGENT | TASK | BRANCH
   Each task must cite issue number(s) and acceptance criteria.
4. Prefer existing issues over inventing new work. Max ~12 agent tasks in waves 1–4.
5. Include a Human wave for Pelops/Stripe/DPA items that agents must not fake.
6. Commit + push the plan only. No Co-Authored-By / Made with / Generated with branding.
7. Write handoff.md: Built / Decisions / Do not repeat / Evidence (gh issue counts + plan path).

Acceptance:
- Plan file exists, parseable WAVE lines, ordered so security/deploy before product polish
- Explicit soft-live vs hard-live definition
- Issue → wave mapping table in the plan header
- Branch pushed; draft PR if gh works
```

---

## How to run it

**Option A — Other Claude CLI (interactive):** paste the block above; keep this chat free.

**Option B — Fleet (from dev-agents):**

```bash
# After plan file exists:
./scripts/dispatch.sh git@github.com:Arlencho/olympus-platform.git \
  wave-plans/olympus-golive-from-sandbox-2026-07-21.plan --auto --retries 2
```

First dispatch should be **one** planning seat (wave 0), not the full implement waves — approve the plan, then trigger implement waves.

---

## Definition of done for “kickstart”

- [ ] Soft-live vs hard-live written down  
- [ ] Wave plan frozen with issue numbers  
- [ ] Wave 1 (security/cost) scheduled first  
- [ ] Pelops human checklist visible (not buried in agent tasks)  
- [ ] Hermes product epic **not** blocking soft-live unless pay-link #1994 is in scope  
