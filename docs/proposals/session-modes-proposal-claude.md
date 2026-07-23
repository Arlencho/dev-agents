# Session Modes — Conductor / Wave / Auto (Claude seat proposal)

**Status:** DESIGN PROPOSAL — nothing here ships until owner synthesis
**Author seat:** Claude (independent; do not converge with grok/kimi proposals)
**Brief:** [`session-modes-BRIEF.md`](session-modes-BRIEF.md)
**Date:** 2026-07-23
**Angle:** policy clarity, trust, human gates, anti-thrash

---

## 1. Executive summary

Session modes are **behavior contracts for the chat seat**, not new software. The contract text lives in one canonical doc (`docs/session-modes.md`); the *current* mode is a tiny state file under `logs/session-mode/`; the inject path is the existing L2 skill mechanism (one new pack, promoted by normal human-gated PR — no freeze violation). Nothing new runs as a daemon; dispatch, seats, and plan format are untouched.

**Conductor** turns a pinned defect into a one-screen task packet and routes it to the role seat (`workers.yaml` → `provider_preferences`); the chat agent never implements in-scope product code — the ABarranges incident is exactly the failure this forbids. **Wave** is the existing orchestrator planning habit made contractual: plan artifacts in `docs/plan-file-format.md` format, execution only on an explicit human trigger, with a visible *planning → armed* sub-state gate. **Auto** picks Conductor / Wave / stay-in-chat from a documented decision table, announces the choice in one line, and **locks per pin** — one silent upgrade maximum, never a silent downgrade, so it cannot thrash.

Default mode is **Auto** (strawman accepted, with a safety amendment: Auto's Conductor still proposes assignment and waits for "go" in MVP). Rollout is docs-first: Phase A ships the contract doc + task-packet template + orchestrator charter slice in ~1 week with zero script changes; Phase B adds the mode file + preamble slice; Phase C adds metrics. Success is measured by one number above all: **% of pinned product defects self-fixed in chat → should approach 0**.

---

## 2. Mode contracts

### 2.0 Common rules (all modes)

1. Mode is **visible**: the agent acknowledges the active mode on activation, on every gear change, and at the top of any dispatch/assignment proposal.
2. Mode is a contract on the **chat seat's own behavior**. It never changes seats, failover chains, model routing, or guardrails — those stay in config.
3. Human escape hatches always win for **one turn** and do not change the persisted mode: "fix here" / "quick" (self-do), "don't dispatch" (brief/issue only), "switch to X" (persisted switch).
4. Expert output is an **untrusted prior**: verification is against git/live surface, per `skills/untrusted-prior`.

### 2.1 Conductor contract (hard rules)

Active when the human pins a concrete product defect or asks to fix in-scope product code.

1. **Diagnose lightly.** Enough to classify surface → role and write the packet. Read-only commands are fine (`grep`, `gh`, `curl` the live page). Budget guidance: minutes, not an implementation session.
2. **Classify** surface → role using the routing table (§7). If two roles are plausible, pick primary + name the secondary in the packet's out-of-scope line.
3. **Write a task packet** (template §8): symptom, likely root class, scope, done-when, out-of-scope, evidence, learning expectation.
4. **Assign via role seat map.** The conductor names the *role* ("`web-frontend` seat"); vendor comes from `config/workers.yaml provider_preferences` + `config/routing.yaml provider_failover`. The human never has to say "use Kimi".
5. **MVP gate: propose, then wait for "go".** First-ship Conductor does not dispatch on its own — it shows the packet + the single-seat dispatch line and waits. ("Auto single-seat when confidence high" is a Phase C option, off by default.)
6. **Never implement in-scope product code in the conductor chat.** No drive-by `{" "}` fixes. If the conductor catches itself editing product source, it must stop, revert its edit, and route. This is the ABarranges rule.
7. **Verify after the expert returns** (see §5, step 7). Allowed: live check, pattern scan, diff read, running existing tests. Forbidden: re-authoring the fix. If verification fails → new packet or bounce back to the same seat with the failure evidence; still no self-fix.
8. **Learning expectation is part of the packet** (§10): if the root class is a reusable platform quirk, the packet requires a learning stub from the expert. Skills remain PR-gated — Conductor never writes `skills/*/SKILL.md`.
9. **Escape hatches:** "fix here"/"quick" → conductor may self-do that item (and should still offer a learning stub); "don't dispatch" → produce packet + GitHub issue only; pure docs/chat scope → self-do allowed without ceremony.

### 2.2 Wave contract

Active for sprints, milestones, multi-surface / multi-PR work, architecture.

Two sub-states (not top-level modes):

| Sub-state | Behavior |
|---|---|
| **wave:planning** (default) | Clarify, advise, decompose. Produce plan artifacts in exact `docs/plan-file-format.md` grammar (`WAVE \| AGENT \| TASK \| BRANCH`), saved under `wave-plans/`. May run `autoplan.sh` / plan-critic review on request. No dispatch. |
| **wave:armed** | Entered only when the human says the plan is final. The agent echoes the exact dispatch command (`./scripts/dispatch.sh <repo> <plan> [--auto --retries N]`) and the plan file path, then waits. Execution happens **only** on an explicit trigger word ("trigger" / "go" / "dispatch it"). Any plan edit drops back to *planning*. |

Hard rules:

1. **No silent multi-agent shipping.** `dispatch.sh` runs only after the armed-state trigger. This is the existing operator habit (plan → "trigger" → dispatch) made contractual.
2. Plans obey plan-format hard rules: no unescaped pipes, producer/critic on same branch → different waves, branch kebab-case.
3. Wave mode may *contain* conductor-shaped single tasks (a 1-line plan is legal), but if the session is really one pin + one role, Auto should have picked Conductor — see thrash rules §4.2.

### 2.3 Auto contract

1. Auto is a **selector**, not a fourth behavior. On each new pin/request it applies the decision table (§4), announces one line, then behaves exactly per the chosen contract:
   `Auto → Conductor: single legal JSX defect → web-frontend seat.`
2. **Lock per pin.** The chosen gear holds until: (a) the human switches, (b) a new distinct pin arrives, or (c) a scope-discovery upgrade (§4.2).
3. Ambiguity costs at most **one question**, then Auto locks on the answer.
4. Auto inherits all human gates: its Conductor still waits for "go"; its Wave still waits for "trigger". Auto never adds autonomy — it only picks which contract applies.

---

## 3. Activation & persistence

### 3.1 Activation syntax

Both forms, recognized as **chat conventions** (no new CLI flags — `/mode` is text the agent interprets, not a product slash command):

- Natural language: `Activate Conductor` / `Activate Wave` / `Activate Auto` / `Back to Auto`
- Slash-like: `/mode conductor` | `/mode wave` | `/mode auto` | `/mode` (report current)

Mid-session switching is always allowed and never requires restarting the chat product. On every activation/switch the agent acknowledges: `Mode: Conductor (was: Auto). Persisted.`

### 3.2 Where state lives

**`logs/session-mode/<product-or-project>.mode`** — chosen because `logs/` already holds per-machine runtime state (`logs/provider-state/`) and is the "not source of truth" zone. Small key-value file the agent writes with existing Bash access:

```
mode: conductor
sub_state: -            # wave:planning | wave:armed | -
locked_pin: abarranges-whitespace
set_by: human           # human | auto
set_at: 2026-07-23T10:12:00Z
product: olympus-platform
```

- Keyed per product/project (matches the `companies/` cwd-context pattern), not per chat tab. Two parallel chats on the same product share a mode — that is a feature (one product, one operating posture), flagged as an open question (§15).
- Add `logs/session-mode/` to `.gitignore` (runtime state, like provider-state). *(Phase B; gitignore edit marked as implementation, not done here.)*

### 3.3 How default + override resolve ("forgot to activate")

Resolution order at session start:

1. Existing `logs/session-mode/<product>.mode` file → resume it, announce it.
2. Product override: `default_session_mode:` frontmatter field in `companies/<name>.md` *(speculative new field — one line per manifest, no script changes needed because the chat agent reads the manifest anyway)*. Example: Soft-live week → `default_session_mode: conductor`.
3. Global default: **Auto** (strawman accepted). Rationale: Auto with human gates is safe-by-construction — the failure cost of a wrong gear pick is one announced line, not an unwanted dispatch.

"Forgot to activate" therefore costs nothing: Auto is the floor, and the first pinned defect gets the announce line, which doubles as a reminder that modes exist.

### 3.4 Multi-vendor inject path

One contract, multi inject (R11: no per-vendor divergence):

- **Contract text:** `docs/session-modes.md` (canonical, Phase A).
- **Inject vehicle:** a new L2 pack `skills/session-modes/SKILL.md` (~40 lines: read the mode file, obey the contract, announce, escape hatches), mapped in `config/role-skills.yaml` to `orchestrator` (and optionally `investigate`). This rides the **existing** `skill-inject.sh` path for all three vendors — Kimi/Grok launchers already inject charter + skills into the prompt, so no launcher changes.
- **Claude co-pilot chat:** `claude --agent orchestrator` loads the charter; the charter gains a short "Session modes" slice pointing at `docs/session-modes.md` (Phase A charter edit, normal PR).
- The pack ships via a normal **human-merged skill PR** — this is a one-time contract inject, not experience auto-promotion; the skills-evolution freeze is respected.

---

## 4. Auto decision table + thrash prevention

### 4.1 Decision table

Applied top-down; first matching row wins. This refines the owner strawman (refinements marked ★).

| # | Signal | Auto picks | Notes |
|---|--------|-----------|-------|
| 1 | Human uses an escape hatch phrase ("fix here", "don't dispatch") | Obey hatch for one turn | ★ Hatches outrank the table; mode unchanged |
| 2 | One surface, concrete defect/repro, one role (e.g. "live page shows ABarranges") | **Conductor** | The motivating case |
| 3 | Bug report but surface/role unclear after light look | **Conductor**, packet routed to `investigate` | ★ `investigate` is the classifier-of-last-resort; routing.yaml already maps `bug:`/`incident` → investigate |
| 4 | ≥2 roles, ≥2 PRs, dependency ordering, milestone/sprint/architecture language | **Wave** | |
| 5 | Pure discussion, legal posture, prioritization, "what should I work on" | **Stay-in-chat** | No fleet, no product code |
| 6 | Work scoped to `dev-agents` itself (docs, config, proposals) | **Stay-in-chat** (self-do) | ★ Meta-repo work is the chat seat's own scope |
| 7 | Ambiguous between rows | **Ask once**, then lock on the answer | One question max |

### 4.2 Thrash prevention (hard rules)

1. **Lock per pin.** Once announced, the gear holds for that pin/task. New distinct pin → new table pass (announced again).
2. **Upgrades only, and at most one.** Discovery may upgrade *stay-in-chat → Conductor* or *Conductor → Wave* (e.g. the "one-line fix" turns out to touch API + frontend). The upgrade is **proposed, not silently taken**: `Conductor found multi-role scope → propose Wave. Confirm?` Downgrades (Wave → Conductor) only by human word.
3. **No mid-task re-evaluation.** Auto does not re-run the table because an expert is slow or a first attempt failed; retries stay inside the current gear.
4. **Announce format is fixed** (one line, `Auto → <gear>: <reason> → <seat/plan>.`), so gear changes are grep-able in transcripts and auditable in retros.

---

## 5. Conductor runtime path

From pin to verified fix, using only existing machinery:

```
Human pins defect ("live legal page renders 'ABarranges'")
        │
        ▼
[1] Light diagnose (read-only: curl live page / grep repo / gh issue view)
        │
        ▼
[2] Classify surface → role  (§7 table; here: Next.js RSC JSX → web-frontend)
        │
        ▼
[3] Write task packet → wave-plans/briefs/<date>-<slug>.md   (template: templates/task-packet.md)
        │
        ▼
[4] Propose assignment + show dispatch line → WAIT for human "go"
        │
        ├─ "don't dispatch" → gh issue create with packet body; stop (issue-only path)
        ├─ "fix here"       → conductor self-does this one; offer learning stub; stop
        ▼  "go"
[5] Single-seat dispatch — one of:
      a) 1-line plan (preferred): write `1 | web-frontend | <packet summary + brief path> | fix/legal-abarranges`
         → ./scripts/dispatch.sh <product-repo> <plan> --retries 2
         (gets seats, failover, rate-cap sentinel, logs, handoffs for free)
      b) Local quick path when dispatch overhead isn't worth it:
         claude --agent <role> "<task>"  for Claude seats, or
         providers/<vendor>/launch.sh <role> "<task>" for non-Claude seats
         (launcher contract exists today: launch.sh <role> <task>, exits 0/1/75/69)
        │
        ▼
[6] Expert implements on branch → PR (+ learning stub if packet required it)
        │
        ▼
[7] Conductor verifies (live check / pattern scan / read diff) — no re-authoring
        │
        ├─ pass → report to human; issue → status:qa per docs/issue-lifecycle.md
        └─ fail → bounce packet back to seat with failure evidence (max 2 bounces, then escalate to human)
```

**Files/scripts touched at runtime:** `wave-plans/briefs/` (new dir for packets), optionally a 1-line plan under `wave-plans/` or `/tmp`, existing `dispatch.sh` / `run-remote.sh` / launchers, `gh` for the issue path. **Nothing new is executable** — Conductor MVP is a discipline plus a template.

**Single-seat vs issue-only:** default is single-seat dispatch after "go"; "don't dispatch" or off-hours → the packet body becomes a GitHub issue (`gh issue create`), labeled per `routing.yaml label_routes` (e.g. `agent:web-frontend`) so later triage routes it identically.

## 6. Wave runtime path

Unchanged mechanics; the mode adds gates and visibility:

```
[wave:planning]
  Clarify → decompose → write plan file (docs/plan-file-format.md grammar)
  Save: wave-plans/<repo>-<date>.plan
  Optional: plan review — dispatch.sh --review / autoplan.sh Pass 4 (grok plan-critic seat)
        │  human: "plan is final"
        ▼
[wave:armed]
  Agent echoes: plan path + exact command:
    /opt/homebrew/bin/bash scripts/dispatch.sh <repo-ssh-url> wave-plans/<plan> --auto --retries 3
  and WAITS. Any plan edit → back to wave:planning.
        │  human: "trigger"
        ▼
[execute]  dispatch.sh runs waves; seats from provider_preferences; failover per provider_failover;
           handoffs land in wave-plans/<wave>/handoffs/; make scorecard afterwards
        │
        ▼
[report]   PR list, CI status, issue label flips (status:in-review → status:qa), retro when milestone-sized
```

Wave mode invents no new dispatch semantics — it forbids exactly one thing (running dispatch without the armed-state trigger) and requires exactly one thing (plan artifacts in the canonical format, not prose-only plans).

## 7. Role routing (surface → role → seat)

**Step 1 — surface → role.** Canonical table in `docs/session-modes.md`, seeded from the orchestrator roster + `routing.yaml`:

| Surface signal | Role |
|---|---|
| Next.js / React / JSX / RSC / styling / rendered copy (the ABarranges class) | `web-frontend` |
| Go handlers / services / middleware | `go-backend` |
| Schema / migrations / SQL | `db-architect` |
| `api.yaml` / contract / generated client | `api-designer` |
| CI/CD / Docker / deploy | `devops` |
| Tests only | `test-engineer` |
| Vulnerability / authz / injection | `security-reviewer` |
| Unclear root cause, flaky, incident | `investigate` |
| Docs / README / changelog | `docs-writer` |

Existing `routing.yaml label_routes` / `title_patterns` are the machine-readable cousins of this table; the issue-only path uses them directly via labels.

**Step 2 — role → seat.** Read-only config lookup, never a human decision at pin time: `config/workers.yaml provider_preferences[role]` → primary vendor; `config/routing.yaml provider_failover[role]` → chain on exit 75/69. The conductor's assignment line says the role and (optionally, for transparency) the resolved seat — but the human **never** has to name a vendor, and the conductor never overrides seats inline. Re-seating is a config PR, not a chat decision.

## 8. Brief / task packet template (shared DNA)

One template, two consumers: Conductor packets (full form) and wave plan task lines (compressed form — `TASK_DESCRIPTION` carries goal + done-when; the packet file can be referenced by path for detail). Proposed location: **`templates/task-packet.md`**; instances in `wave-plans/briefs/<date>-<slug>.md`.

```markdown
# Task packet: <slug>
- **Pin (what was seen):** <symptom, verbatim, with where>
- **Likely root class:** <one line; mark UNCONFIRMED if not verified>
- **Role seat:** <role>          # vendor resolved from config, not named by human
- **Scope:** <files/dirs/surfaces in play>
- **Done-when:** <observable acceptance, testable>
- **Out-of-scope:** <explicitly not this task; adjacent roles if any>
- **Evidence:** <commands/URLs/greps the conductor ran>
- **Learning:** <yes — stub required | no> + <one-line pattern if yes>
- **Branch:** <fix/... or feat/...>
- **Verification plan:** <what the conductor will check on return>
```

### Worked example — ABarranges (the motivating incident)

```markdown
# Task packet: legal-abarranges-whitespace
- **Pin (what was seen):** Live legal page renders "Pelops AI ABarranges" — company name
  and following word fused. Seen on production legal copy page.
- **Likely root class:** Next.js RSC drops inter-node JSX whitespace after `</strong>`;
  missing explicit `{" "}` between inline nodes. UNCONFIRMED until repo grep.
- **Role seat:** web-frontend
- **Scope:** legal copy page component(s) in the product web app; inline JSX around
  `<strong>` company-name spans.
- **Done-when:** Live legal page renders "Pelops AI AB arranges" with correct spacing;
  a repo-wide check finds no other `</strong>`-adjacent fused-text instances on legal pages.
- **Out-of-scope:** Copy rewording (docs-writer if wanted), backend, any non-legal page
  beyond the pattern scan.
- **Evidence:** curl of live page shows fused string; conductor did NOT patch source.
- **Learning:** yes — stub required. Pattern: "RSC/JSX drops whitespace between inline
  elements; use explicit {\" \"} after closing inline tags." Reusable across all
  Next.js surfaces → global learning candidate.
- **Branch:** fix/legal-abarranges-whitespace
- **Verification plan:** curl live page post-deploy for "AB arranges"; grep diff to
  confirm fix is `{" "}`-class, not copy rewrite.
```

Single-seat plan line derived from it (shared DNA in action):

```
1 | web-frontend | fix RSC whitespace fusing "ABarranges" on legal page — see wave-plans/briefs/2026-07-23-legal-abarranges-whitespace.md — done-when live page shows "AB arranges"; add learning stub | fix/legal-abarranges-whitespace
```

Under the old behavior the chat agent self-fixed and no learning was written. Under Conductor: the packet forces routing, the seat map picks the vendor (`web-frontend: kimi`, failover claude), and the learning expectation is contractual.

## 9. Integration with L1/L2/L3

| Layer | What session modes add | What they do NOT add |
|---|---|---|
| **L1 charter** | Short "Session modes" slice in `roles/orchestrator.md` (pointer to `docs/session-modes.md`, the three-contract summary, escape hatches). Orchestrator is already the closest charter — this is an amendment, not a new role. | No new role file; no `conductor.md` charter (Conductor is a *mode of* the orchestrator seat, keeping "one contract, multi inject") |
| **L2 skills** | One new pack `skills/session-modes/` (contract crib: read mode file, obey, announce, gates), mapped to `orchestrator` in `role-skills.yaml`. Rides existing `skill-inject.sh` for all vendors. Ships via normal human-merged PR. | No auto-written skills; freeze intact. Experts (web-frontend etc.) do **not** get the pack — modes govern the chat seat, not workers |
| **L3 case** | The mode file is L3-class **state** (session/case scoped). Phase B: optional `preamble.sh` slice "Session mode: conductor (set 2026-07-23 by human)" so dispatched orchestrator-role tasks see it. Advisory, like all L3. | L3 never carries contract text (that's L2/doc); handoffs still never outrank skills |

**Boundary rule:** *mode = which contract applies now* (state, L3-class); *skill = how any seat honors contracts* (playbook, L2); *charter = who the seat is* (identity, L1). Keeping the mode value out of L2 means switching modes never touches PR-gated files.

## 10. Learnings policy

1. **Conductor packets carry a learning bit** (`Learning: yes/no`). "Yes" when the root class is a reusable platform quirk (RSC whitespace is the canonical example), "no" for one-off typos/content fixes.
2. **The expert writes the stub, not the conductor** — the expert has ground truth. Mechanism exists today: `scripts/learnings.sh add <project> <agent> <type> <summary>` (types: failure/discovery/pattern), or a markdown stub in the product repo's learnings when the JSONL path doesn't fit. The conductor's verification step (§5, step 7) checks the stub exists when the packet required one.
3. **Global vs project:** default project-scoped. The conductor may *flag* "global candidate" in the packet; promotion to a fleet learning or any `skills/*/SKILL.md` change remains a **PR per the skills-evolution freeze** — human merge for global, critic-or-human for project. Modes add zero new write paths to skills.
4. **Chat memory is not a learning.** If a fix's lesson lives only in a chat transcript (the ABarranges failure), the contract counts it as an unfinished task.
5. Retro (`make retro`) remains the aggregation point: mode announce lines + packets + learning stubs give it structured input it currently lacks.

## 11. Phased rollout

| Phase | Timeline | Ships | Gate |
|---|---|---|---|
| **A — docs + discipline (MVP)** | ~1 week | `docs/session-modes.md` (contracts, decision table, routing table); `templates/task-packet.md`; `wave-plans/briefs/` convention; orchestrator charter slice; `skills/session-modes` pack via normal PR; README pointer from the Mode-1/Mode-2 operator section | Human merges; zero script/config-schema changes |
| **B — state + inject** | week 2–3 | `logs/session-mode/` file convention + gitignore line; optional `preamble.sh` mode slice; `default_session_mode:` honored in `companies/*.md`; `role-skills.yaml` mapping live | Only after ≥5 real Conductor packets show the discipline holds in chat alone |
| **C — measurement + optional autonomy** | later | Mode/packet columns in retro + `make scorecard`; owner decision on "auto single-seat when confidence high" (off by default) | Only with Phase B evidence; autonomy needs explicit owner opt-in |

What ships first is deliberately **docs/skill only**: the entire MVP is enforceable by contract + review because every gate is a human gate. Scripts come only where state must survive the chat (Phase B).

## 12. Success metrics

| Metric | Source | Target |
|---|---|---|
| % pinned product defects self-fixed by the chat seat | Retro over transcripts + git blame (chat-seat commits touching product code during conductor sessions) | → ~0 (ABarranges class extinct) |
| Packet completeness (all template fields filled, done-when testable) | Review of `wave-plans/briefs/` | ≥90% complete without human rework |
| Time from pin → expert PR open | Packet timestamp → PR `createdAt` | Median < 1 day; no regression vs self-fix speed beyond ~2× |
| Learning stubs written when packet required one | Conductor verification + `learnings/` | 100% (it's contractual) |
| Auto announce present on every gear pick; gear changes per pin | Transcript grep for the fixed announce format | 100% announced; ≤1 auto change per pin |
| Unauthorized dispatches (no "go"/"trigger" in transcript) | Dispatch logs vs transcripts | 0 |
| Wrong-role assignments (expert bounces with "not my surface") | Handoffs / bounce count | <10% of packets |

Kill-criterion analog (mirroring skills freeze): if after ~15 conductor packets the pin→PR median is >3× the old self-fix time **and** learning capture shows no reuse, drop Conductor ceremony for `quick`-class fixes (widen the escape hatch) rather than abandoning the mode.

## 13. Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| **Kimi unavailable/capped** when packet targets `web-frontend` | Existing machinery: launcher exits 75/69 → cooldown mark in `logs/provider-state/` → `dispatch.sh` walks `provider_failover: web-frontend: [kimi, claude]`. Conductor path (a) inherits this free; path (b) local launcher: on 75/69 the conductor retries via the failover vendor's launcher or falls back to path (a). Never "vendor down → conductor codes it" |
| **Wrong role classified** | Expert bounces with evidence → conductor reclassifies (counts as bounce 1 of 2) → re-route; recurring misroutes feed the routing table in `docs/session-modes.md` via retro |
| **Conductor still codes** (contract violation) | Detection: chat-seat commits on product repo during a conductor session (git author + transcript). Response: revert-or-own rule — either revert and route properly, or the human explicitly retro-blesses it via "fix here"; violation logged as a learning against the chat seat |
| **Auto thrash** | Lock-per-pin + upgrades-only + one-auto-change max + fixed announce format (§4.2); thrash is visible in transcript grep, so it's auditable, not just discouraged |
| **Mode not injected / vendor ignores the pack** | Floor is safe: no mode context ⇒ Auto-by-default with all human gates intact — worst case is old behavior (self-fix risk), not an unwanted dispatch. Cheap probe: ask `/mode`; a seat that can't answer reveals the inject failed. Kimi/Grok co-pilot compliance with the injected contract is **unproven until trialed** (speculation flagged) — Phase A trials it on the Claude seat first |
| **Stale mode file** (yesterday's `wave:armed` still on disk) | `wave:armed` is never resumable across sessions: on session start any armed state degrades to `wave:planning` and the agent announces it. `set_at` older than ~24h ⇒ re-announce and ask to confirm mode |
| **Packet sprawl** (briefs dir becomes a junk drawer) | One packet per pin, date-slug named; retro prunes; issue-only path stores the packet in the GitHub issue instead when the work is deferred |

## 14. Explicit non-goals

- No autonomous spend: no dispatch without "go" (Conductor) / "trigger" (Wave) in MVP; no auto-merge of anything.
- No auto skill promotion from conductor outcomes; no writes to `skills/*/SKILL.md` outside normal PRs (freeze intact).
- No replacement of `dispatch.sh`, plan format, launchers, or the seat/failover config; no new daemon, DB, or vector store.
- No fourth top-level mode; no per-vendor divergent mode systems (one contract doc, one pack, multi inject).
- No `conductor.md` role file / new seat — Conductor is a mode of the chat seat.
- No Paperclip dependency (future consumer only: a Paperclip routine could read mode files someday; explicitly out of MVP).
- No revival of handoff-brain Phases 2–5.

## 15. Open questions for the owner

1. **Mode scope:** per-product mode file (proposed) means two parallel chats on one product share a mode. Acceptable, or do you want per-session files with a session id in the name?
2. **Default confirmation:** global default Auto accepted? And is `default_session_mode:` in `companies/*.md` frontmatter the right override home, or would you rather keep overrides verbal-only until Phase B?
3. **Conductor autonomy line:** is "propose + wait for go" acceptable friction for *every* single-seat dispatch in MVP, or do you want a whitelist (e.g. docs-writer packets auto-go) from day one?
4. **Packet storage:** commit packets to `wave-plans/briefs/` in dev-agents (my proposal — fleet-visible evidence), or keep them in the product repo next to the code they describe?
5. **Verification depth:** may the conductor run the product's test suite as verification (heavier than "pattern scan"), or is that already too close to owning the fix?
6. **`investigate` as ambiguity sink** (table row 3): right call, or should ambiguous bugs stay with the conductor for one more diagnosis pass before dispatch?
7. **Learning stub location for non-JSONL cases:** is a markdown stub in the product repo acceptable when `learnings.sh` project JSONL doesn't fit, or should everything go through `learnings.sh`?
8. **Bounce ceiling:** 2 bounces then human-escalate mirrors the critic 2-loop ceiling — confirm, or set to 1 for MVP?

---

*End of proposal — Claude seat. Grounded in: README.md (operator modes, launcher contract, failover), `config/workers.yaml`, `config/routing.yaml`, `docs/plan-file-format.md`, `roles/orchestrator.md`, `scripts/preamble.sh`, `scripts/learnings.sh`, `skills/*` + `docs/proposals/skills-evolution-SYNTHESIS.md` (freeze), `docs/issue-lifecycle.md`. Speculative items are marked inline (companies frontmatter field, Kimi/Grok pack compliance, Phase B script slices).*
