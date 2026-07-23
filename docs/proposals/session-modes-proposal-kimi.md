# Proposal: Session modes — Conductor / Wave / Auto (Kimi seat)

**Author:** Kimi seat (independent designer, per `session-modes-BRIEF.md`)
**Date:** 2026-07-23
**Angle:** operator UX — activation friction, day-to-day Conductor flow, seat-unavailable failure modes
**Status:** design proposal only. No scripts, skills, or charter edits are implemented here.

---

## 1. Executive summary

Session modes are a **behavior contract for the co-pilot chat agent**, persisted in one small state file and injected as one L2 skill pack. Three modes only: **Conductor** (pin → classify → brief → assign by role seat → verify; never implements), **Wave** (plan artifacts only; fleet executes solely on explicit human trigger), **Auto** (picks per a documented decision table, announces the pick, locks it per pin).

The design's center of gravity is **operator friction**:

- Activation is three channels deep — natural language, `/mode <name>`, and a state file that survives chat restarts — so "forgot to activate" degrades gracefully instead of silently.
- The contract is visible: every mode-relevant turn carries a one-line status prefix (`Mode: Conductor`), and every assignment speech names the **role and seat** (`web-frontend → kimi seat`), never a vendor the human had to pick.
- Conductor's day-to-day is a strict five-beat loop (pin → brief → propose → go → verify) with a three-word operator grammar: **`go`**, **`issue only`**, **`fix here`**.
- Single-seat dispatch reuses `scripts/dispatch.sh` with a one-line plan — no second orchestration product, no new daemons, no invented flags.

ABarranges (the motivating RSC-whitespace incident) is worked end-to-end in §5 and §8. Default mode is **Auto** (accepting the owner strawman), with per-repo override in the state file. Skills promotion stays PR-gated; modes write learning stubs, never `skills/*/SKILL.md`.

---

## 2. Mode contracts

### 2.1 Conductor — hard rules

When Conductor is active and the human pins a concrete product defect (or asks to fix in-scope product code):

1. **Diagnose lightly.** Read-only inspection (code, logs, live page) sufficient to classify surface and root-cause *class*. Budget: a handful of tool calls, not an implementation session.
2. **Classify** surface → role using `config/routing.yaml` (`label_routes`, `title_patterns`) plus the role roster in `roles/orchestrator.md`.
3. **Write a task packet** from `templates/task-packet.md` (§8) — one screen, pasted in chat.
4. **Propose the assignment** by seat: `Assign → web-frontend (kimi seat per workers.yaml). Say "go" to dispatch, "issue only" to file, "fix here" to override.` The human never names a vendor; the seat comes from `config/workers.yaml` `provider_preferences`.
5. **Never implement** in-scope product code in the conductor chat. Verification (§5 beat 5) is allowed; re-authoring the expert's fix is not.
6. **Wait for the human** before dispatch in MVP (owner strawman accepted: `conductor_wait_for_go: true`).
7. **Escape hatches** (human-initiated only): `fix here` / `quick` → conductor may self-do; `don't dispatch` / `issue only` → brief or GitHub issue, no fleet; pure docs/chat/discussion → not a dispatchable pin at all.

### 2.2 Wave — hard rules and sub-states

Wave has two sub-states, **not** two modes:

- **Planning (default):** clarify, brainstorm, advise; author wave-plan artifacts conforming to `docs/plan-file-format.md` (`WAVE | AGENT | TASK | BRANCH`); present machine assignments and merge order. Output lives in chat and, when the human asks, `wave-plans/<repo>-<date>.plan`.
- **Armed for dispatch:** entered only when the human says the plan is ready. In this sub-state the conductor presents the exact `dispatch.sh` invocation and waits. **The only verb that executes is the human's explicit trigger** (`trigger`, `dispatch`, `go wave 1`). No silent multi-agent shipping, ever.

A Wave session may produce *no* plan (pure brainstorm) — that is a valid outcome.

### 2.3 Auto — hard rules

- Picks Conductor vs Wave vs stay-in-chat per the decision table in §4 — a table, not vibes.
- **Announces every gear choice in one line**, e.g. `Auto → Conductor: single legal-JSX defect → web-frontend seat.`
- **Locks per pin.** Once a gear is chosen for the current pin/task, Auto does not re-evaluate until: the human switches modes, the current pin resolves, or a *new distinct* pin arrives. No mid-task thrash.
- Ambiguity budget: **one** clarifying question, then lock. Never an interro­gation.

### 2.4 Stay-in-chat (not a mode — a non-dispatch outcome)

Discussion, legal posture, prioritization, architecture talk: no fleet, no product code unless the human overrides with `fix here`. Any mode can yield stay-in-chat for a given message.

---

## 3. Activation & persistence

### 3.1 Activation channels (priority order)

1. **Slash-like convention:** `/mode conductor`, `/mode wave`, `/mode auto`, `/mode off`. This is a *chat convention*, not a CLI flag — any co-pilot vendor can honor it because the skill pack defines the words.
2. **Natural language:** `Activate Conductor`, `switch to Wave`, `go Auto`. Same effect.
3. **State file (durable):** the agent reads it at session start and offers to write it on activation, so a mode survives a chat restart.

Mid-session switching is always allowed without restarting the chat product — it is just a new activation.

### 3.2 Where state lives

| Layer | Path | Contents | Git-tracked? |
|-------|------|----------|--------------|
| Live state (per machine, per repo) | `logs/session-mode/<repo-slug>.state` | `mode`, `set_at`, `set_by` (which channel), `pinned_task` (optional) | No — add `logs/session-mode/` to `.gitignore` (same treatment as existing `logs/provider-state/`) |
| Fleet default + policy | `config/session-modes.yaml` (new) | `default_mode: auto`, `conductor_wait_for_go: true`, `auto_announce: true`, `decision_table` pointer | Yes |
| Product override | state file, set once from the product repo (`cd <product> && <dev-agents>/scripts/session-mode.sh set conductor`) | e.g. Soft-live week → Conductor for that repo only | No |

Precedence: **live state file > fleet default**. A product-specific override is just a state file that was set once and left in place — no second config mechanism to keep in sync.

### 3.3 The helper (Phase 1, proposed — not built here)

`scripts/session-mode.sh` — thin bash over the state file, modeled on the grep-based config readers already in `scripts/skill-inject.sh` and `scripts/preamble.sh`:

```bash
scripts/session-mode.sh get [<repo-path>]          # prints mode + provenance, exit 0 if unset
scripts/session-mode.sh set conductor|wave|auto [<repo-path>]
scripts/session-mode.sh clear [<repo-path>]
```

Subcommands only; no flag invention. Chat agents may also read/write the file directly — the script exists so the *human* has a muscle-memory command and so session start has one canonical read path.

### 3.4 Multi-vendor inject path

The contract text lives in **one** place: a new L2 pack `skills/session-modes/SKILL.md` (proposed; creation is a normal skill PR, not auto-promotion). `config/role-skills.yaml` maps it onto `orchestrator` and `default` so any co-pilot session bootstrapped through the existing L1→L2→L3 pipeline carries it. Because the pack is plain markdown with exact phrases and the announce format, Claude / Kimi / Grok chats behave identically — one contract, multi inject (R10).

### 3.5 "Forgot to activate" handling

Session start, per the pack: run `session-mode.sh get` (or read the state file). Then:

- Set → announce: `Mode: Conductor (set 2026-07-23 14:02 via /mode, repo olympus).`
- Unset → apply fleet default and announce: `Mode: Auto (fleet default). Say "/mode conductor" to change.`

Either way the human sees the active gear within the first two turns. Silence = bug, and it is detectable precisely because the announce is mandatory (§12 metric).

---

## 4. Decision table (Auto)

Strawman accepted, extended with the signals that actually separate the gears in day-to-day operation:

| # | Signal (in priority order) | Auto picks |
|---|---------------------------|------------|
| 1 | Human gave an escape hatch this turn (`fix here`, `don't dispatch`, `trigger`) | Obey the hatch; it beats the table |
| 2 | Multi-role, multi-PR, milestone, sprint, "Soft-live week", architecture, brainstorm | **Wave** (planning sub-state) |
| 3 | One surface, clear defect, one owning role, in-scope product code | **Conductor** |
| 4 | Defect but owner role unclear, or crosses a surface boundary | **Ask once**, then Conductor with the answered role |
| 5 | Pure discussion / policy / legal posture / prioritization / "what do you think" | **Stay-in-chat** |
| 6 | Docs-only or repo-meta change (this repo's own docs) | Stay-in-chat; conductor may self-do if trivial and human nods |
| 7 | Genuinely ambiguous after one question | **Stay-in-chat** + say why; never guess into a dispatch |

**Announce format (mandatory, one line):**
`Auto → Conductor: single legal JSX defect → web-frontend seat.`
`Auto → Wave: Soft-live spans web+api+db; drafting plan, no dispatch without trigger.`
`Auto → stay-in-chat: prioritization discussion, no fleet.`

**Thrash prevention:**

- Lock per pin (§2.3). The lock is recorded in the state file's `pinned_task` so a chat restart doesn't reset the gear mid-task.
- A "new distinct pin" means a different defect/goal, not a follow-up sentence about the same one. Follow-ups inherit the lock.
- Re-evaluation is allowed *between* pins, and forced when the human activates a mode explicitly (explicit beats Auto).
- Max one clarifying question per pin (row 4). If the answer still doesn't resolve it, row 7: stay-in-chat. Auto never loops.

---

## 5. Conductor runtime path — day-to-day flow

Five beats. Beats 1–3 happen in-chat; beat 4 touches the fleet; beat 5 closes the loop.

**Beat 1 — Pin.** Human: *"Live legal page shows 'Pelops AI ABarranges'."* Conductor acknowledges with the status prefix: `Mode: Conductor — pin accepted.`

**Beat 2 — Light diagnosis + classify.** Read-only look (the rendered page, the JSX file). Concludes: RSC dropped inter-node whitespace after `</strong>`; surface = Next.js page; role = `web-frontend`. Uses `routing.yaml` patterns as a hint, roster table for scope; does **not** fix.

**Beat 3 — Task packet.** Fills `templates/task-packet.md` (§8), pastes one screen in chat. Includes the learning expectation because RSC-whitespace is a reusable platform quirk.

**Beat 4 — Propose, then one of three exits:**

```
Assign → web-frontend (kimi seat per workers.yaml; failover claude per routing.yaml).
Say "go" to dispatch · "issue only" to file · "fix here" to override.
```

- **`go` → single-seat dispatch.** Conductor writes a one-line plan and runs the existing dispatcher:

  ```bash
  printf '1 | web-frontend | %s | fix/legal-rsc-whitespace\n' "<packet summary, no unescaped pipes>" > /tmp/conductor-legal-rsc.plan
  ./scripts/dispatch.sh git@github.com:Arlencho/olympus-platform.git /tmp/conductor-legal-rsc.plan
  ```

  One-line plans are already legal (`docs/plan-file-format.md`, legacy format). `dispatch.sh` already resolves the seat from `workers.yaml`, walks `provider_failover` on exit 75/69, retries, and logs to `wave-plans/`. **No new orchestration path.** (Local single-machine fallback: the same one-liner via `run-remote.sh` against `localhost`, exactly as `roles/orchestrator.md` documents today.)
- **`issue only` →** `gh issue create -R <product-repo>` with the packet as body and the routing label (`agent:web-frontend`); label `status:in-progress` per `docs/issue-lifecycle.md`. No fleet.
- **`fix here` →** escape hatch; conductor self-does, and says it stepped out of contract for this turn.

**Beat 5 — Verify, don't re-author.** When the expert's PR lands: check the branch/PR diff touches only the packet's scope, run the cheap verification the packet names (here: grep the built page / component for `{" "}` after `</strong>`, and confirm no `ABarranges` pattern can render), confirm the learning stub exists if required. Report: `Verified: fix on fix/legal-rsc-whitespace, learning stub present. QA label set.` If verification fails, the packet goes *back to the same seat* with the failing evidence attached — the conductor still does not author the fix.

### Worked example — ABarranges (the motivating incident)

Under this contract, the incident replays as:

1. `Mode: Conductor — pin accepted: legal copy renders "Pelops AI ABarranges".`
2. Light read of the legal page component → root class: RSC inter-node whitespace collapse after `</strong>`.
3. Packet §8.1 pasted (filled example below).
4. `Assign → web-frontend (kimi seat). Say "go"…` → human: `go`.
5. One-line plan → `dispatch.sh` → `web-frontend` seat fixes with `{" "}` + writes `learnings/rsc-jsx-whitespace-<date>.md` stub (packet required it).
6. Conductor verifies the PR diff scope + the stub + the pattern scan. Done. **The chat never contained the fix.**

What happened in reality — self-fix in chat, no learning — is exactly what rule 5 (§2.1) and the packet's learning field are designed to make impossible-by-default.

---

## 6. Wave runtime path

1. **Planning sub-state (default).** Human brings multi-surface work ("Soft-live F&F week"). Wave clarifies goals, then produces the orchestrator-format output already specified in `roles/orchestrator.md`: assessment, waves with machine assignments, a fenced ```plan block conforming to `docs/plan-file-format.md` (wave ordering, no same-wave file conflicts, producer/critic in different waves, no unescaped pipes), merge order, "don't forget" critics.
2. **Persist on request.** Human: `save the plan` → write `wave-plans/<repo>-<date>.plan` (the path `dispatch.sh` itself uses for auto-saves).
3. **Arm.** Human: `looks right` / `arm it` → sub-state flips; Wave prints the exact command, e.g. `./scripts/dispatch.sh git@github.com:Arlencho/olympus-platform.git wave-plans/olympus-2026-07-24.plan --retries 3`, and waits.
4. **Trigger.** Only the human's explicit `trigger` (or running the command themselves) executes. After each wave, Wave reports from `wave-plans/*.log` and `gh pr list`, then waits for the next trigger — `--auto` (existing dispatch flag, unrelated to Auto *mode*; the naming collision is called out in §13) is offered, never assumed.

Wave never dispatches mid-brainstorm, never dispatches "partially," and treats a plan edit as disarming (back to planning sub-state).

---

## 7. Role routing

- **Surface → role:** first, `config/routing.yaml` `label_routes` / `title_patterns` where a GitHub issue exists; otherwise the scope table in `roles/orchestrator.md` (`apps/web/` or Next.js → `web-frontend`, `apps/api/` → `go-backend`, etc.). Conductor states the mapping in the proposal line so the human learns the pattern — a teaching moment, not just a lookup.
- **Role → seat:** `config/workers.yaml` `provider_preferences` (`web-frontend: kimi`, `plan-critic: grok`, `docs-writer: claude` …). The human **never names a vendor**; the conductor speaks roles and seats. If a seat's primary provider is down, §13.1 — the failover chain in `routing.yaml` (`web-frontend: [kimi, claude]`) is walked by `dispatch.sh`, which already exists.
- **Model tier:** untouched — `routing.yaml` `model_routing` keeps doing its job (`AGENT_MODEL` through the launcher). Session modes add nothing here.
- **Overrides:** the human may always say `route to db-architect instead` — role names are fair game; vendor names are never required.

---

## 8. Brief / task packet template

New file (Phase 0): `templates/task-packet.md`. Shared DNA with wave plan task lines — every packet field except evidence/learning compresses losslessly into the `TASK_DESCRIPTION` field (respecting the no-unescaped-pipes rule), so a packet *is* a single-line plan with a human face.

```markdown
# Task packet — <short slug>
- **What the user saw:** <symptom, verbatim where possible>
- **Likely root class:** <class, not the fix — e.g. "RSC inter-node whitespace collapse">
- **Surface → role:** <surface> → <role>   (seat resolves from workers.yaml)
- **Scope:** <files/areas in scope>
- **Done-when:** <verifiable condition — the check Conductor will run in beat 5>
- **Out of scope:** <explicit non-goals for the expert>
- **Evidence to attach:** <logs, screenshots, grep results, links>
- **Learning stub required:** yes <pattern name> | no
- **Branch:** fix/<slug> | feat/<slug>
- **Plan line:** <WAVE | AGENT | TASK | BRANCH — pipe-safe>
```

### 8.1 Filled example — ABarranges

```markdown
# Task packet — legal-rsc-whitespace
- **What the user saw:** live legal page renders "Pelops AI ABarranges" (missing space after bold)
- **Likely root class:** Next.js RSC drops inter-node JSX whitespace after </strong>
- **Surface → role:** apps/web legal page → web-frontend
- **Scope:** legal page component only
- **Done-when:** rendered page shows "Pelops AI AB arranges"; component keeps explicit {" "}
  after </strong>; no other copy changed
- **Out of scope:** other pages, styling, legal text edits
- **Evidence to attach:** screenshot of live page; grep showing missing {" "} in component
- **Learning stub required:** yes — rsc-jsx-whitespace (reusable platform quirk)
- **Branch:** fix/legal-rsc-whitespace
- **Plan line:** 1 | web-frontend | legal page RSC whitespace — add explicit space after strong, see packet | fix/legal-rsc-whitespace
```

---

## 9. Integration with L1 / L2 / L3

| Layer | What changes (all via normal PRs, nothing in this task) | Why |
|-------|----------------------------------------------------------|-----|
| L1 charter | One new section in `roles/orchestrator.md`: "Session modes — read `session-mode.sh get` at session start, honor the active contract, announce on activation." Producer/critic charters: **untouched.** | The charter is the pointer; the contract text must not be duplicated into N role files. |
| L2 skill pack | New `skills/session-modes/SKILL.md` holding the full contracts, decision table, announce formats, packet pointer, failure-mode behaviors. Mapped in `config/role-skills.yaml` on `orchestrator` and `default`. Respects `max_total_lines` budget by referencing (not inlining) `templates/task-packet.md` and the plan-format doc. | Mode = behavior policy → exactly what L2 packs are for; project overrides global by id if a product needs a variant. |
| L3 preamble | **No change.** Fleet workers get a task line + packet through the existing dispatch path; session mode is co-pilot policy and must not be spammed into every worker preamble (same reasoning as the skills-evolution freeze keeping L2 out of L3). | Workers don't choose gears; polluting L3 dilutes the budgeted preamble. |

**What is mode vs skill:** the *mode* says which contract governs this session; the *skill pack* is the delivery mechanism for the contract text. A product that wants a stricter Conductor ships `skills/session-modes/SKILL.md` in its own repo (project-overrides-global, per `role-skills.yaml` header) — no fork of the fleet.

---

## 10. Learnings policy

- Conductor packets carry **learning-stub-required: yes/no**. `yes` when the root class is a reusable platform quirk (RSC whitespace), a fleet-process gap, or a wrong-role lesson.
- The expert writes the stub to the product's `learnings/` (or global `learnings/` in dev-agents when the lesson is fleet-wide) as part of the same PR — done-when includes it, and beat-5 verification checks for it.
- **Skill promotion is unchanged and PR-gated** (skills-evolution freeze): stubs are candidates; a human opens a promotion PR; modes never write `skills/*/SKILL.md`.
- Chat memory is explicitly not a learning store: anything worth keeping leaves the chat in the packet, the stub, or the issue.

---

## 11. Phased rollout

**Phase 0 — docs + template + pack (week 1, no behavior risk):**

1. `templates/task-packet.md` (§8).
2. `docs/session-modes.md` — operator-facing contract + cheat-sheet, linked from README's Mode 1 / Mode 2 section so the two existing operator stories gain a third entry, not a replacement.
3. `skills/session-modes/SKILL.md` + `role-skills.yaml` mapping (normal PR).
4. `config/session-modes.yaml` with strawman defaults.
5. Pilot: human runs co-pilot sessions with the pack for a week; collect §12 metrics by hand.

**Phase 1 — thin mechanics (week 2, only if Phase 0 feels right):**

6. `scripts/session-mode.sh` (§3.3) + `.gitignore` entry for `logs/session-mode/`.
7. L1 pointer section in `roles/orchestrator.md`.
8. Optional `Makefile` conveniences (`make mode MODE=conductor`) — sugar only.

**Later (explicitly not MVP):** confidence-gated auto single-seat dispatch (flip `conductor_wait_for_go` per repo after metrics justify it); Paperclip as a consumer of the state file; per-vendor telemetry on announce compliance.

**What ships first:** docs/skill/template only. Scripts come after the contract survives contact with the operator.

---

## 12. Success metrics

| Metric | Baseline (today) | Target | How measured |
|--------|------------------|--------|--------------|
| % of pinned product defects self-fixed by the chat agent under Conductor | ABarranges = 1/1 | → 0, escape hatches excluded and counted separately | tally in weekly retro (`make retro` exists) |
| Pins dispatched with a complete packet (all template fields) | n/a | ≥ 90% | spot-check packets in chat logs |
| Time pin → expert PR opened | unknown | trending down; first dispatch < 5 min from pin | dispatch logs vs chat timestamps |
| Wrong-role assignments per week | unknown | ≤ 1 and falling | §13.2 reassignments counted |
| Learning stubs landed for `required: yes` packets | 0 (ABarranges left none) | 100% | beat-5 verification |
| Mode announce present at session start | n/a | 100% — silence is a bug the human can report | manual + later scripted check |
| Auto thrash events (gear change within one pin) | n/a | 0 | announce-line audit |

---

## 13. Failure modes

### 13.1 Seat unavailable (the requested deep-dive)

Conductor proposes `web-frontend` and the human says `go` — but the `kimi` CLI is down or rate-capped:

1. `dispatch.sh` already walks `provider_failover` (`web-frontend: [kimi, claude]`) on exit 69 (unavailable) / 75 (rate-capped, with the `rate_caps.cooldown_minutes: 60` sentinel skipping a cooling vendor). The conductor **does not invent a fallback path** — it reports what the fleet did: `kimi seat rate-capped; failover to claude per routing.yaml.`
2. **All providers in the chain fail:** conductor stops, keeps the packet, and offers the two non-fleet exits: `issue only` (file it with the packet, label `status:blocked` reason) or wait for cooldown (state file notes the pending pin so a later session can resume it). It never silently self-fixes because the fleet is down — unavailability is not an escape hatch.
3. **Seat available but worker machine down:** same exits, plus the local `run-remote.sh … localhost` path the orchestrator charter already documents. Mode adds no new machinery here.

### 13.2 Wrong role classified

Cheap by construction: the packet is portable. Conductor re-issues it to the right role (`Assign → db-architect instead`), notes the misclassification as a learning stub if the confusion is reusable, and §12 counts it. The cost is one message, not a wrong PR — because dispatch waited for `go`.

### 13.3 Conductor still codes

Contract breach, treated as a process bug not a style issue: the pack's self-check line (`Before editing product code: am I the conductor and is this an escape hatch? If not — packet.`), the §12 self-fix metric trending to zero, and the human's standing override `route it`. Repeated breaches → tighten the pack via normal skill PR.

### 13.4 Auto thrash

Prevented by the per-pin lock + state-file `pinned_task` (§4). Detected via announce-line audit (two different gears for one pin = violation, countable).

### 13.5 Mode not injected / not visible

Session-start announce is mandatory (§3.5); its absence is human-detectable in one turn. Root causes: pack not mapped for the role, state file unreadable, product chat bootstrapped outside the L1→L2 pipeline. Mitigation is procedural — re-activate verbally; the contract words work even from chat memory because the pack is short and phrase-exact.

### 13.6 Naming collision: Auto mode vs `dispatch.sh --auto`

They are unrelated (one chooses gears in chat; the other skips inter-wave prompts in the dispatcher). The pack and docs always write the flag as `--auto` and the mode as **Auto mode**; Wave's armed message prints the literal command so no ambiguity reaches the shell.

---

## 14. Explicit non-goals (MVP)

- Autonomous CEO behavior: no money-spending or wave execution without human trigger.
- Auto-merge or auto-promotion of skills from conductor outcomes (freeze stands).
- Replacing or wrapping `dispatch.sh` into a new orchestration product; killing multi-vendor.
- Reviving handoff-brain Phases 2–5.
- Per-vendor proprietary mode dialects — one contract, multi inject.
- Requiring Paperclip.
- Product UI of any kind; this proposal touches no app code.

---

## 15. Open questions for the owner

1. **Auto-go graduation:** after what metric evidence (e.g. 20 consecutive clean single-seat dispatches?) may a repo flip `conductor_wait_for_go: false`?
2. **State file scope:** per repo (proposed) vs per directory-tree — mono-repos with multiple products in one checkout would share one state file under the proposed scheme. Acceptable?
3. **Issue-always:** should Conductor *always* `gh issue create` for board visibility (per the orchestrator charter's top-of-chain rule) even when dispatching, with the PR closing it — or only on `issue only`?
4. **Critic-by-default:** should every conductor single-seat dispatch auto-append a critic wave (`web-frontend` then `frontend-critic` as wave 2), or stay one seat unless asked?
5. **Learning home for fleet-wide quirks:** RSC-whitespace is a Next.js/platform lesson — product `learnings/` or dev-agents global `learnings/`? Proposed rule: platform → global, product-behavior → product. Confirm.
6. **`/mode off`:** keep as a fourth value (bare co-pilot, no contract) or fold into Auto? Proposed: keep — an explicit off is clearer than "Auto that happens to stay in chat."
7. **Announce verbosity:** one line per gear choice (proposed) or one line per turn while a pin is open? Owner preference on chat noise.

---

*End of proposal — Kimi seat.*
