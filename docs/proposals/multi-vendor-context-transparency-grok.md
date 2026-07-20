# Multi-Vendor Agent Orchestration: Shared Project Brain  
### Grok version — proposal

| | |
|--|--|
| **Status** | Draft for review |
| **Author** | Grok (xAI / Grok Build) with Arlen |
| **Date** | 2026-07-20 |
| **Repo** | `~/Desktop/dev-projects/AI-Orchestration/dev-agents` |
| **Audience** | Fleet owners deciding how Claude, Kimi, and Grok share work without sharing a chat |
| **Depends on** | Multi-vendor CLI launchers (`providers/*/launch.sh`), dispatch / run-remote, learnings, scorecard |

> **Filename note:** This is the **Grok** write-up of the multi-supplier transparency idea. It stands alone; it does not replace other drafts under `docs/proposals/`.

---

## Why write this

Same-supplier multi-agent stacks feel “alive” because everyone is in **one session**: one transcript, one memory, one set of open threads.

Our fleet is different on purpose. We route roles across **Claude Code**, **Kimi Code**, and **Grok Build** as separate CLIs, zero API keys, with failover when a vendor rate-caps. Each run is a **new process**. Git keeps the *code*. Almost nothing keeps the *thinking* that produced it.

This proposal is about closing that gap until multi-supplier orchestration feels as coherent as same-session multi-agent — and, in places, **more** reliable for humans and for failover.

---

## The real gap (not “more prompt”)

| What still works across vendors | What dies at process exit |
|--------------------------------|---------------------------|
| Repo, branch, PR, CI | Conversation memory |
| Role charters | “We already tried X and it failed” |
| Task text + preamble snippets | Open questions and deliberate non-goals |
| Logs if someone remembers to read them | Confidence and partial progress on failover |

So the problem is not “make the prompt longer.” It is:

**Who holds durable memory when no vendor holds the full chat?**

Answer we propose: **the orchestrator**, using plain files and git — not a new daemon and not each vendor’s private memory product.

---

## North-star principle

```
Orchestrator memory  >  any single vendor’s session memory
```

Or, shorter:

> **Every supplier is a strong specialist with amnesia. The fleet’s brain lives in artifacts.**

Within one vendor you may still use multi-agent tools and resume flags for a tight revise loop. Across vendors and across roles, **artifacts are the only truth**.

That is not a downgrade from shared context. Shared context also copies one model’s mistakes into every subagent and rots over a long session. We want **shared facts, independent judgment**.

---

## Picture of the system

```
                 ┌─────────────────────────────────────┐
                 │     PROJECT BRAIN (files + git)     │
                 │  handoffs · decisions · evidence    │
                 │  blacklist · provider cooldowns     │
                 └──────────────────┬──────────────────┘
                    inject at start │  write at end
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
     Claude CLI                Kimi CLI                  Grok CLI
     (local multi-agent        (local multi-agent        (local multi-agent
      fine inside job)          fine inside job)          fine inside job)
```

Humans and scorecards read the same brain. No vendor is special.

---

## What we need to build

### 1. Handoff records (the main product)

A **handoff** is a small structured document every meaningful job must leave behind.

**Suggested location (product repo, travels with the work):**

```text
.agent-ledger/<task_id>.jsonl
```

One JSON object per line (same operational style as learnings / ratecap logs).

**Minimum fields:**

| Field | Purpose |
|-------|---------|
| `task_id`, `wave`, `agent` | Who / where in the plan |
| `provenance.vendor`, `model`, `host` | Transparency + later analytics |
| `branch`, `base_sha`, `head_sha` | Workspace identity |
| `status` | `done` / `blocked` / `needs_review` / `partial` |
| `summary` | Short plain-language story |
| `decisions[]` | Choices that are not obvious from the diff |
| `open_questions[]` | What the next role must resolve or accept |
| `do_not_repeat[]` | Dead ends (kills rework loops) |
| `files_touched[]` | Map to the PR |
| `evidence[]` | Commands, log paths, URLs — not vibes |
| `next_role`, `next_hint` | Routing aid for dispatch / humans |
| `failover` | Optional: previous vendor, RATE_CAP, partial flag |

**Example:**

```json
{
  "task_id": "W2-web-frontend-seo",
  "wave": 2,
  "agent": "web-frontend",
  "provenance": { "vendor": "kimi", "model": "k3", "host": "local" },
  "branch": "feat/seo-meta",
  "base_sha": "aaa111",
  "head_sha": "bbb222",
  "ts": "2026-07-20T14:00:00Z",
  "status": "done",
  "summary": "SEO meta tags on index; no og:image until asset exists.",
  "files_touched": ["index.html"],
  "decisions": ["Skip og:image for now"],
  "open_questions": ["Canonical trailing slash?"],
  "do_not_repeat": [],
  "confidence": "high",
  "evidence": [
    { "type": "cmd", "value": "make test-short", "result": "pass" }
  ],
  "blockers": [],
  "next_role": "frontend-critic",
  "next_hint": "Check canonical URL consistency",
  "failover": null
}
```

Without a valid handoff, “exit 0” should eventually mean **incomplete** to the orchestrator.

---

### 2. Inject the brain on every launch

Extend the existing preamble path (`preamble.sh` / `run-remote` FULL_TASK assembly) so every vendor receives the **same shape** of context:

1. Role charter  
2. Task / issue / wave slice  
3. **Prior handoffs for this task (bounded)**  
4. Decisions + do-not-repeat (curated)  
5. Git identity (branch + SHAs)  
6. Learnings (repo-scoped, already exist)  
7. One line of honesty: *prior work may be from another vendor; trust ledger + git*

**Parity rule:** Claude via `--agent`, Kimi/Grok via charter-in-prompt — but the **brain slice must be identical**. If Kimi hits argv limits, pipe the prompt on stdin (known risk from multi-vendor design).

---

### 3. Evidence, not speeches

Cross-vendor trust fails when one agent says “tests pass” and another cannot check.

Handoffs prefer:

- Command + result  
- Log path under `logs/`  
- Commit / PR  

Critics should be told: **prefer re-run or read artifacts over re-interpreting marketing summaries.**

---

### 4. Contracts between roles (executable surfaces)

We already have a good pattern in plan-critic: a parseable **`VERDICT:`** line.

Generalize:

| From → To | Machine-readable surface |
|-----------|---------------------------|
| Producer → Critic | Handoff + PR + claims |
| Critic → Producer | `VERDICT: PASS \| REVISE \| BLOCK` + numbered findings |
| Producer → QA | Checklist + URL + smoke commands |
| Any → Failover | Same `task_id` + `failover` block + SHAs |

Humans and `dispatch.sh` can both route on that without reading a novel.

---

### 5. Sticky where it helps, cold where it protects

| Case | Policy |
|------|--------|
| Same role revising after REVISE | Prefer **same vendor**; optional CLI resume if available |
| New role (producer → critic) | **Always cold start** + full brain inject |
| Exit 75 / 69 failover | Next vendor in chain + partial handoff + git |
| Human override | Force vendor or force cold start |

This keeps same-session multi-agent strength *inside* a supplier without pretending chat continues across suppliers.

---

### 6. Visibility for humans

`make scorecard` already shows provider cool-downs. Add a thin **wave board** (markdown is enough):

```text
Wave 2
  done     api-designer     @claude   handoff · PR#12
  running  web-frontend     @kimi     attempt 2 (failover from claude)
  queued   frontend-critic  @claude   waits on PR#12
```

If you cannot answer “who is doing what, on which supplier, with what proof?” without opening three TUIs, transparency has failed.

---

### 7. Provenance in git

Optional but cheap and powerful — commit trailers:

```text
Agent: web-frontend
Vendor: kimi
Model: k3
Task: W2-web-frontend-seo
```

Together with handoff `provenance`, this feeds later scorecard analysis (which vendor correlates with rework), not just live cooldowns.

---

## What we explicitly will not do

- Cross-CLI live memory sync  
- A new always-on agent bus / message queue as a prerequisite  
- Depending on Claude/Kimi/Grok proprietary memory features for fleet continuity  
- Dumping full prior transcripts into every prompt (rot + cost + truncation)

---

## Phased delivery

| Phase | Outcome |
|-------|---------|
| **0** | Agree this doc: ledger path, hard vs soft enforcement |
| **1** | One producer writes handoff; one critic gets it in preamble; prove intent crosses vendors |
| **2** | Schema file + validation; missing/malformed handoff fails the gate |
| **3** | Failover partials + stdin for long prompts; inject parity audit |
| **4** | Sticky revise + wave board |
| **5** | Provenance → scorecard analytics → optional routing hints |

**Start at Phase 1.** Do not build the full platform before one Kimi→Claude (or Grok→Claude) handoff improves a real review.

---

## Success looks like

1. Critic cites producer **intent and open questions**, not only the diff.  
2. Rate-cap failover does not orphan partial work or silent intent.  
3. A human reconstructs the wave from ledger + git without vendor UIs.  
4. Fewer “critic misunderstood the producer” loops in learnings over a month.  
5. Same-vendor multi-agent still used where it shines (deep local loops); multi-supplier used where it shines (specialists + failover + audit).

---

## Six questions the brain must always answer

From files alone, anyone should know:

1. What is in flight, and which **role + vendor**?  
2. Why was a decision made?  
3. What was tried and discarded?  
4. What evidence supports “done”?  
5. What must the next role not redo?  
6. What happened on failover?

If those six are always file-backed, multi-supplier can feel **clearer** than a single opaque mega-session.

---

## Fit with current code (no greenfield fantasy)

| Existing piece | How this proposal uses it |
|----------------|---------------------------|
| `preamble.sh` / FULL_TASK | Injection point for handoff slice |
| `learnings.sh` | Pattern for append-only memory |
| Launchers + charters | Session start; brain goes in every FULL_TASK |
| plan-critic `VERDICT:` | Template for all critic exits |
| Provider column + scorecard | Human transparency + later analytics |
| `logs/provider-state/` | Failover / cooldown already transparent |
| Wave barriers in dispatch | Natural handoff boundaries |

---

## Recommendation

Approve **Phase 0–1** as the next epic after multi-vendor launchers are stable:

1. Fix handoff schema + `.agent-ledger/` (or equivalent) in product repos.  
2. Wire producer exit → append handoff; critic start → inject last handoff(s).  
3. Run one real cross-vendor pair and keep the pattern only if the critic quality visibly improves.

**Do not** chase a universal chat. Chase a **universal briefcase** every agent must carry and leave behind.

---

## Closing line (for role charters)

> You will not inherit chat from other vendors. Your memory is the handoff ledger, git SHAs, and evidence in your preamble. Before a successful exit, write a complete handoff so the next specialist — human or model — does not start blind.

---

*Grok version — end of proposal.*
