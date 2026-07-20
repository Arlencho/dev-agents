# Proposal: Multi-Vendor Context Transparency  
## (Shared Project Brain / Orchestrator as Hippocampus)

| Field | Value |
|--------|--------|
| **Status** | Draft for review |
| **Authors** | Arlen + Grok (Build); incorporates prior draft notes (Claude Fable session, 2026-07-20) |
| **Date** | 2026-07-20 |
| **Repo** | `AI-Orchestration/dev-agents` |
| **Branch context** | Multi-vendor CLI orchestration (`feat/cross-vendor-seats` / merged multi-vendor work) |
| **Related** | `providers/*/launch.sh`, `scripts/preamble.sh`, `scripts/run-remote.sh`, `scripts/dispatch.sh`, `scripts/learnings.sh`, `scripts/provider-scorecard.sh`, plan-critic `VERDICT:` grammar, Paperclip board |

---

## 1. Executive summary

Within one vendor’s multi-agent session, orchestration feels strong because **context and memory are shared** (one transcript, one working memory, continuous tool state).

Our fleet now runs **Claude / Kimi / Grok** as separate subscription CLIs, each a **fresh process per task**. Git carries *output* (branches, diffs, PRs). It does **not** carry *intent*: what was tried and rejected, open questions, deliberate non-goals, confidence, or “what the next role must not redo.”

**Goal:** recover the *function* of a shared session for multi-supplier waves — and in several dimensions do **better** than a single shared context window.

**Strategy in one line:**

> Treat every supplier as a brilliant amnesiac specialist; make the orchestrator the hippocampus.

**Target state:** agents share **ground truth** (facts, artifacts, decisions, evidence) but **reason independently** over it — shared facts, decorrelated reasoning. That is stricter and more auditable than one contaminated shared reasoning stream.

---

## 2. Problem statement

### 2.1 What same-session multi-agent gives for free

| Shared asset | Why it matters |
|--------------|----------------|
| Transcript | Decisions, dead ends, who said what |
| Working memory | Assumptions, open threads, “we already tried X” |
| Tool / workspace state | Same cwd, branch, recent test results “in mind” |
| Role continuity | Subagents inherit the parent frame |
| Implicit norms | How *this* run uses the codebase |

### 2.2 What multi-supplier has today

| Still shared | Lost on every hop |
|--------------|-------------------|
| Git, filesystem, GitHub | Transcript continuity |
| Role charters + task string | Model-native memory |
| Preamble (CLAUDE.md head, learnings, git, issue) | In-session multi-agent sub-orchestration continuity |
| Provider failover / scorecard | Intent behind the diff |

**Result:** each launch is closer to a smart contractor with a brief than a teammate who sat through the last hour.

### 2.3 Why “better than one session” is achievable

A single shared context window:

- Propagates one model’s blind spots to every subagent  
- Accumulates context rot  
- Is opaque to humans and non-surviving across machines/days  

We already rejected model homogeneity for quality. We should reject **forced shared reasoning** for the same reason.

---

## 3. Goals and non-goals

### Goals

1. **Vendor-neutral durable substrate** that plays the transcript’s role across Claude / Kimi / Grok.  
2. **Handoff packets** so successors and critics see *intent*, not only diffs.  
3. **Provenance** on durable artifacts (agent / vendor / model / task).  
4. **Injection parity** — every vendor gets the same *kind* of context at task start (charter + brain slice + task).  
5. **Human transparency** — wave board / scorecard answers “who did what, on which provider, with what evidence?” without opening a TUI.  
6. **Failover-safe continuity** — rate-cap hop (exit 75) does not erase partial work or intent.  
7. **Sticky sessions where they help** — same-vendor revise loops may resume; cross-vendor always cold-starts through the brain.

### Non-goals

- Literal shared chat bus across vendor CLIs (unsupported / brittle).  
- New long-running daemon (stay on bash + git + existing logs; Paperclip ideas only).  
- Syncing each vendor’s proprietary memory product.  
- Real-time streaming between concurrent same-wave agents (same-wave tasks stay independent by design; sharing at wave barriers + handoffs).  
- Replacing git as source of truth for code.

---

## 4. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│              Shared Project Brain (orchestrator)               │
│  handoffs · decisions · blacklist · evidence · provider-state  │
└───────────────────────────┬──────────────────────────────────┘
            inject on launch │  write on exit / gate
     ┌──────────────────────┼──────────────────────┐
     ▼                      ▼                      ▼
  Claude session         Kimi session           Grok session
  (local multi-agent OK) (local multi-agent OK) (local multi-agent OK)
```

**Rule:** Prefer sticky **within** a supplier for deep revise loops.  
**Always** use the Project Brain for role boundaries, critics, wave barriers, and failover.

---

## 5. Design pieces

### 5.1 Handoff packet (unit of transparency) — highest leverage

Every non-trivial agent **starts** after reading prior handoffs and **ends** by writing one. Same schema for all vendors.

**Recommended storage (leaning git-native, append-friendly):**

- Per task: `artifacts/handoffs/<task-id>/` **or** append-only  
  `.agent-ledger/<task-id>.jsonl` in the **product** repo (travels with the work, survives Paperclip downtime).  
- Pattern: same discipline as `learnings.jsonl` / `ratecap.log` (one JSON object per line).

**Proposed record (JSONL, one per agent completion):**

```json
{
  "task_id": "W2-web-frontend-seo",
  "wave": 2,
  "agent": "web-frontend",
  "provenance": {
    "vendor": "kimi",
    "model": "k3",
    "host": "worker-host"
  },
  "branch": "feat/seo-meta",
  "base_sha": "abc…",
  "head_sha": "def…",
  "ts": "2026-07-20T13:44:00Z",
  "status": "done",
  "summary": "Added six SEO meta tags to index.html; upsert semantics.",
  "files_touched": ["index.html"],
  "decisions": [
    "Single-quoted attrs for heredoc safety",
    "Left og:image out — no hostable asset yet"
  ],
  "open_questions": [
    "Should og:url use trailing slash in all envs?"
  ],
  "do_not_repeat": [
    "Do not reintroduce landing.html"
  ],
  "confidence": "high",
  "evidence": [
    { "type": "cmd", "value": "make test-short", "result": "pass" },
    { "type": "grep", "value": "meta property=og:", "result": "6 hits" }
  ],
  "blockers": [],
  "next_role": "frontend-critic",
  "next_hint": "Focus on canonical URL consistency",
  "failover": null
}
```

**Failover extension:**

```json
"failover": {
  "from_vendor": "kimi",
  "reason": "RATE_CAP",
  "partial": true,
  "note": "Branch has WIP commits; resume from head_sha"
}
```

**Enforcement (phase in):**

1. Soft: charters require handoff; critics reject “no handoff / prose-only intent.”  
2. Hard: exit 0 without valid handoff → orchestrator marks task incomplete / retryable.  
3. Optional later: git hook or gate job on handoff presence for producer PRs.

### 5.2 Project brain (long-lived, curated)

| Store | Contents | Owner |
|-------|----------|--------|
| Handoff ledger | Per-task intent + evidence | Every agent on exit |
| `learnings/` | Durable cross-project failures / norms | Exit hooks + humans (exists) |
| Decisions / mini-ADRs | Architectural choices | Producers + CTO |
| Blacklist | Dead ends (“tried X, failed because Y”) | Any agent |
| `logs/provider-state/` | Caps / cooldowns | Launchers / dispatch (exists) |
| Wave / exec logs | Provider column, outcomes | dispatch (exists) |

**Injection order** into every `FULL_TASK` (extend `preamble.sh` / run-remote):

1. Role charter (already: Claude `--agent` / Kimi+Grok charter inject)  
2. Issue / wave slice  
3. **Bounded handoff slice** (prior waves for this task/branch — not full history)  
4. Decisions + blacklist (top N relevant)  
5. Git state (branch, SHAs, dirty summary)  
6. Learnings (repo-scoped)  
7. Provider continuity note: e.g. *“You are Claude; prior producer was Kimi; trust artifacts and git, not missing chat.”*

### 5.3 Evidence protocol

Cross-supplier trust dies on “tests pass” with no proof.

Handoffs must prefer:

- Commands + exit codes  
- Paths under `logs/…`  
- Commit SHA / PR URL  

Critics (and QA) are instructed to **re-run or read artifacts**, not re-derive intent from marketing prose when evidence exists.

### 5.4 Shared workspace identity

Handoff always carries `branch`, `base_sha`, `head_sha`.  
Next agent’s first tools: checkout that branch, `git log` / `diff` vs base.  
**No claim of edits without SHA.**

### 5.5 Structured inter-role contracts

Generalize plan-critic’s executable grammar to all critic roles:

| Interaction | Contract |
|-------------|----------|
| Producer → Critic | PR + handoff + claims list |
| Critic → Producer | `VERDICT: PASS \| REVISE \| BLOCK` + numbered findings |
| Producer → QA | Checklist + deploy URL + smoke commands |
| Failover | Same `task_id` + partial handoff + tried-provider set |

Orchestrator parses verdicts for routing; humans get a stable surface.

### 5.6 Sticky sessions (keep same-vendor magic)

| Situation | Policy |
|-----------|--------|
| Producer revise loop after REVISE | Prefer **same vendor**, optional CLI resume (`-c` / continue) if available |
| Role boundary (producer → critic) | **Cold start** + brain inject (critic independence) |
| Rate-cap / unavailable (75 / 69) | Failover chain; inject partial handoff + git state |
| Human override | Force vendor / force cold start |

### 5.7 Human transparency (wave board)

Extend scorecard / add `make wave-board` (even generated markdown):

```
Wave W2
  [done]    api-designer @claude  → handoff · PR#12
  [running] web-frontend @kimi    (attempt 2; failover from claude ratecap)
  [queued]  frontend-critic @claude  (waits on PR#12)
```

Each row links: log, handoff, PR, provider, duration, exit code.

### 5.8 Provenance stamping

On every durable artifact:

- Handoff `provenance` block  
- Git commit trailers: `Agent:`, `Vendor:`, `Model:`, `Task:`  
- PR body header  

Enables later scorecard analysis: which vendor correlates with rework / defect class.

---

## 6. Where this beats a single session

| Capability | Same-vendor session | Multi-supplier + brain |
|------------|---------------------|-------------------------|
| Fast back-and-forth revise | Strong | Sticky provider helps |
| Multi-day / multi-machine | Weak | **Strong** |
| Failover mid-task | Messy | **Designed** |
| Critic independence | Chat contamination risk | **Artifacts-only option** |
| Human audit | Scroll forever | **Handoff + board** |
| Context pollution | High | Bounded inject |

---

## 7. Hard parts (honest)

| Risk | Mitigation |
|------|------------|
| Format drift across vendors | Schema + reject malformed handoffs |
| Stale context if B starts before A commits | Wave barriers; same-wave independence |
| Prompt / argv size (esp. Kimi) | Bounded slice; stdin piping for long prompts |
| Paperclip vs git ledger | Prefer git source of truth; board as index optional |
| Concurrent appends | JSONL line-append (proven by learnings/ratecap) |
| False “done” without handoff | Orchestrator gate on exit 0 |
| Rate-cap pattern false positives | Already tail-25; tune conf; handoffs still survive |

---

## 8. Open questions (decide in Phase 0)

1. **Ledger home:** `.agent-ledger/` in product repo vs `artifacts/handoffs/` vs Paperclip-only vs both (git SoT, board index)?  
2. **Slice policy:** all prior waves on branch vs only immediate predecessor? Token budget cap?  
3. **Schema ownership:** `config/handoff.schema.json` in dev-agents, injected into charters?  
4. **Enforcement:** soft critic-only vs hard orchestrator/git gate?  
5. **Critic isolation:** ban full producer logs for critics (handoff + diff only) for independence?  

---

## 9. Phased implementation plan

### Phase 0 — This proposal

Agree shape; resolve ledger home + enforcement (questions 1 and 4).

### Phase 1 — Minimal proof (recommended first build)

- Handoff JSONL write on producer exit (one path, one role pair is enough).  
- `preamble.sh` injects prior handoff for critic.  
- Provenance in handoff (+ optional commit trailer).  
- **Prove:** Kimi (or Grok) producer intent reaches Claude critic and changes the review.

### Phase 2 — Schema + validation

- `config/handoff.schema.json`  
- Validator script; critics reject malformed/missing handoffs  
- Charter one-liners for all roles  

### Phase 3 — Parity + piping + failover partials

- Audit identical inject shape for claude/kimi/grok  
- Stdin piping for long prompts (Kimi argv ceiling)  
- Failover re-dispatch includes partial handoff + SHAs  

### Phase 4 — Sticky revise + wave board

- Same-vendor resume for REVISE loops when CLI supports it  
- `make wave-board` / scorecard handoff compliance  

### Phase 5 — Analysis loop

- Provenance → scorecard: rework/defect correlation by vendor  
- Optional routing preference updates from data (not vibes)  

---

## 10. Success criteria

- [ ] A critic can cite the producer’s **stated intent and open questions**, not only the diff.  
- [ ] Vendor/model/agent for an artifact is recoverable from git and/or ledger.  
- [ ] A killed/rate-capped agent loses no *shared* context the next agent needs.  
- [ ] Measurable drop in “critic misunderstood producer intent” loops vs pre-ledger baseline (learnings).  
- [ ] Human can answer the six transparency questions (§11) without opening a vendor TUI.  

---

## 11. Transparency checklist (definition of “good”)

Any agent or human can answer from files alone:

1. **What** is in flight and **who** (role + provider)?  
2. **Why** this decision (handoff / ADR)?  
3. **What** was tried and rejected (blacklist / do_not_repeat)?  
4. **What** evidence supports “done”?  
5. **What** should the next role not redo?  
6. **What** happened on failover (partial files, last error, tried set)?  

---

## 12. Primitives already in place

| Primitive | Role in this proposal |
|-----------|------------------------|
| `scripts/preamble.sh` | Read side of shared memory (extend with handoff slice) |
| `scripts/learnings.sh` + `learnings/*.jsonl` | Pattern for append-only ledger |
| `providers/*/launch.sh` + charter inject | Per-vendor session start |
| `VERDICT:` (plan-critic) | Template for all critic contracts |
| Exec log Provider column | Seed for provenance / scorecard |
| `logs/provider-state/` | Failover / cooldown transparency |
| `make scorecard` | Human-facing provider health |
| Wave barriers in `dispatch.sh` | Sequencing for hand-offs |
| Paperclip board | Optional index / checkout coordination |

---

## 13. Recommendation

**Adopt Phase 0–1 now** as the next epic after multi-vendor launchers:

1. Freeze handoff schema (JSONL) and ledger location (prefer git-native in product repo).  
2. Implement producer write + critic inject for one producer→critic pair (e.g. `web-frontend` @ kimi → `frontend-critic` @ claude).  
3. Measure whether critic quality improves before rolling schema enforcement fleet-wide.

Do **not** invest in cross-CLI live memory sync. Invest in **artifacts that outlive every vendor session**.

---

## 14. Appendix — one-sentence strategy (for charters)

> You will not see prior chat from other vendors. Your memory is the handoff ledger, git SHAs, and evidence paths in your preamble. Write a complete handoff before you exit successfully so the next specialist — human or model — does not start blind.

---

*End of proposal.*
