# Proposal: Multi-Vendor Context Transparency — Kimi Version

| Field | Value |
|-------|-------|
| **Status** | Draft for review — alternative cut to `multi-vendor-context-transparency.md` |
| **Author** | Kimi Code session (2026-07-20) |
| **Repo** | `AI-Orchestration/dev-agents` |
| **Scope** | Tier 1 design + file-level Phase 1 plan, grounded in the current codebase |
| **Related** | `scripts/preamble.sh`, `scripts/run-remote.sh`, `scripts/dispatch.sh`, `scripts/learnings.sh`, `providers/*/launch.sh`, `wave-plans/` |

---

## 1. The reframe

Same-vendor multi-agent feels magical for one reason: **one model holds the whole transcript.** Decisions, dead ends, half-finished edits — all in-head, all the time.

Across Claude / Kimi / Grok that mechanism does not exist and cannot be bought back. Each task is a fresh process in a fresh context window. So stop trying to replicate the transcript.

> Same-vendor orchestration is *one brain with a transcript*.
> Multi-vendor orchestration is *a team with a good wiki*.

The goal of this proposal is not "shared session." It is: **every task starts with exactly the slice of shared fleet state it needs** — facts, artifacts, decisions, warnings — and ends by adding its own slice back. The vendors stay stateless; the fleet becomes the memory.

A team with disciplined handoffs gets surprisingly close to one brain. On long-horizon work it can win outright, because no single context window ever fills up.

---

## 2. What we have vs. what we need

**Already shared today (verified in the merged multi-vendor work):**

- Git: branches, diffs, pushed work per task.
- `preamble.sh`: CLAUDE.md head, repo learnings, git state, issue context — same for every vendor.
- Role charters injected identically into all three CLIs.
- Provider routing, failover, cooldowns, scorecard.

**Lost on every vendor hop:**

- *Intent* — why this diff, what was rejected, what's still open.
- *Warnings* — "don't redo X, it fails because Y."
- *Continuity* — the feeling of picking up where a teammate stopped.

The gap is not context volume. It is the **handoff**: nobody writes down what the next specialist needs, so every agent starts from the diff alone.

---

## 3. Design principles

1. **Share facts, not transcripts.** Full-history sharing is noisy, huge, and leaks irrelevant context. The illusion of a shared session comes from shared *facts* — decisions, artifacts, warnings.
2. **One canonical memory in the repo — never mirror into vendor silos.** Kimi's, Claude's, and Grok's native memory stores differ in format and drift independently. Vendor memories are caches; the repo ledger is the record.
3. **Sticky within a vendor, handoff across.** Resume sessions for revise loops on the same vendor; always cross vendor boundaries through the shared ledger, cold and explicit.
4. **Divergence is a feature — channel it.** We chose vendor heterogeneity for independent judgment. Consistency belongs in contracts and gates (schemas, verdict grammar, critics), not in forcing uniform thinking.
5. **Bounded injection.** Every vendor gets the same *shape* of context, budgeted to its window. A 10 KB focused preamble beats a 100 KB dump.

---

## 4. The four mechanisms

### 4.1 Handoff protocol (highest leverage — Tier 1)

Every non-trivial task **ends** by writing a handoff note; every dependent task **starts** by reading the upstream ones.

- **Contract (exit criteria):** a task is not "done" without a handoff note. Phase in soft (critics reject missing notes), harden later (orchestrator gate on exit 0).
- **Shape:** half a page, five fields — *built / decisions(+why) / open questions / do-not-repeat / evidence* (command + result, SHA, or log path). Prose is fine for Tier 1; JSON schema lands in Tier 2 (don't build the schema validator before anyone has written a note).
- **Home:** `wave-plans/<wave-id>/handoffs/<task-id>.md` in dev-agents for fleet artifacts; when a task's output matters to the *product* repo, the note also travels in the branch (append `artifacts/handoffs/<task>.md` there — decide per-project; start with dev-agents only).
- **Provenance header on every note:** agent, vendor, model, host, branch, base/head SHA, timestamp. This is what later lets the scorecard correlate rework with vendors.

### 4.2 Context fabric 2.0 (selective preamble)

`preamble.sh` already assembles generic context for every vendor. Upgrade it from *generic* to *selected*:

- New inputs, in injection order: charter → task → **upstream handoff notes for this wave/branch** → repo learnings (existing) → git state (existing) → provider-continuity line.
- **Provider-continuity line** (one sentence, cheap and surprisingly effective): *"You are Kimi. The previous specialist was Claude. Trust git SHAs, handoff notes, and evidence paths — there is no chat history."* Sets expectations and stops agents from hallucinating a transcript.
- **Budget:** cap the handoff slice (immediate predecessor notes first, then same-wave notes, newest-first, ~200 lines total). Preamble size must stay predictable for argv transport (base64 path from the run-remote fix carries it safely, but size is still a latency cost).

### 4.3 Canonical memory with tags and provenance

Promote `learnings.sh` from "failure log" to the fleet's long-term memory:

- Entries get **tags** (repo, area, kind: `gotcha | decision | norm`) and **provenance** (vendor, agent, date).
- Preamble retrieves by tag match against the task's role + repo instead of the current flat "last N".
- New write path: agents may append candidate learnings in their handoff note (`learnings:` section); a weekly review (or the retro agent) promotes the good ones. Agents propose, fleet disposes — keeps the store clean.

### 4.4 Per-vendor continuity registry

Cross-vendor is handoffs; within-vendor is **resume**.

- CLIs support it: `kimi -r <session>`, `claude --continue`, `grok -c`.
- `dispatch.sh` records `(wave, vendor, role) → session id` per task (parse from launcher output where printed, else from the vendor session stores).
- On a REVISE loop or a same-vendor follow-up task in the same wave, the launcher resumes instead of cold-starting. On any vendor switch or role boundary, cold start through the fabric (critic independence stays intact).

Result: kimi keeps *its* thread, claude keeps *its* thread, the handoff ledger stitches across.

---

## 5. Consistency layer (what makes it *feel* like one mind)

- **Repo glossary** in the preamble: canonical nouns (wave, DeSO, corridor, handoff…) so all three vendors name things identically.
- **One Definition of Done** template appended to every task: tests green where applicable, diff pushed, **handoff note written**.
- **Cross-vendor diff critic** (Tier 3, generalizes the plan-critic pattern): each task's diff reviewed by a *different* vendor than produced it. Same `VERDICT: PASS | REVISE | BLOCK` grammar so the orchestrator can parse it.
- **Glossary of failure signatures** stays in `ratecap-patterns.conf` — unchanged; handoffs survive rate-cap hops because they're files, not session state.

---

## 6. Explicit non-goals

- **No transcript bus.** Unsupported, brittle, and contrary to principle 1.
- **No native-memory syncing.** One canonical store, injected by prompt.
- **No stylistic uniformity.** Consistency lives in contracts and gates.
- **No new daemon.** Bash + git + files, per repo convention.
- **No schema validator before anyone writes a note.** Prove the habit first (Tier 1), then freeze the schema (Tier 2).

---

## 7. Tiered rollout

| Tier | Contents | Files touched |
|------|----------|---------------|
| **1 — Handoff habit** (days) | Handoff notes as exit criteria; preamble injects upstream notes; provider-continuity line | `scripts/preamble.sh`, `scripts/run-remote.sh`, one role charter, `wave-plans/` layout |
| **2 — Memory + continuity** | Tagged learnings w/ retrieval; session-resume registry; `WAVE_STATE.md` per wave | `scripts/learnings.sh` (+ store), `scripts/dispatch.sh`, `providers/*/launch.sh` |
| **3 — Gates** | JSON handoff schema + validator; cross-vendor diff critic; scorecard handoff-compliance column | `config/handoff.schema.json`, critic scripts, `scripts/provider-scorecard.sh` |

Do not start Tier 2 before Tier 1 has produced real notes from real waves — the schema should be frozen from observed usage, not designed in a vacuum.

---

## 8. Phase 1 plan (file level, dispatchable as one wave)

1. **`scripts/preamble.sh`** — add a *Handoffs* section: given wave id + branch (new optional args), print upstream handoff notes (predecessor first, then same-wave, ~200-line cap). Add the provider-continuity line (`$AGENT_PROVIDER` is already available at the call site in `run-remote.sh`).
2. **`scripts/run-remote.sh`** — pass wave id + provider into `preamble.sh`; after the agent exits 0, check `wave-plans/<wave>/handoffs/<task>.md` exists; if missing, log a soft warning (no gate in Phase 1).
3. **Charters** (`roles/web-frontend.md` first, then all) — one paragraph: *"End your task by writing wave-plans/…/handoffs/<task>.md: built / decisions(+why) / open questions / do-not-repeat / evidence. You will not see other vendors' chat — this note is the memory."*
4. **Prove it on one pair:** `web-frontend @ kimi` (producer) → `frontend-critic @ claude` (critic), same wave. Success = the critic's output cites the handoff's stated intent, not just the diff.
5. **Measure:** count "critic misunderstood intent" loops before/after (from learnings log). If it doesn't move, Tier 2 stops here and the design gets revised — not expanded.

Estimated size: ~150 lines of bash + charter text. No new daemons, no schema files, no validators.

---

## 9. Honest limits

- **It is not a shared session.** Revise-loop latency across vendors will always be seconds-to-minutes, not instant. Sticky resume (4.4) only covers the same-vendor part.
- **Handoff quality is behavior, not code.** Agents will write lazy notes at first; the critic-rejects-missing-note loop is what makes the habit stick. Expect one wave of awkward notes before it normalizes.
- **Preamble budget is a real constraint.** The fabric must stay selective; the moment it becomes "inject everything," we're back to context rot — now handmade.
- **Failover splits authorship.** A rate-capped kimi task finished by claude produces a two-vendor handoff. The schema must allow `failover:` provenance from day one, or provenance lies.

---

## 10. Success criteria

- [ ] A critic quotes producer *intent* (decisions, open questions) from the handoff, not only the diff.
- [ ] Any artifact's author (agent + vendor + model) is recoverable from files alone.
- [ ] A rate-capped agent loses no shared context the next agent needs (handoff + SHAs survive).
- [ ] "Critic misunderstood intent" loops measurably drop in the learnings log.
- [ ] A human can answer *who/why/what's rejected/what evidence/what next/what happened on failover* without opening a vendor TUI.

---

*End of proposal — Kimi version. Companion document to `multi-vendor-context-transparency.md`; where they differ, this one favors proving the handoff habit before freezing any schema.*
