# Session Modes — Conductor / Wave / Auto (Grok seat proposal)

| Field | Value |
|-------|--------|
| **Status** | Independent design proposal (Grok seat) |
| **Author** | Grok (systems designer seat, multi-vendor fleet) |
| **Date** | 2026-07-23 |
| **Repo** | `dev-agents` |
| **Brief** | `docs/proposals/session-modes-BRIEF.md` |
| **Audience** | Fleet owner + synthesis reviewer (post three-vendor comparison) |
| **Depends on (facts)** | `scripts/dispatch.sh`, `scripts/run-remote.sh`, `scripts/skill-inject.sh`, `scripts/preamble.sh`, `scripts/learnings.sh`, `config/workers.yaml`, `config/routing.yaml`, `config/role-skills.yaml`, `docs/plan-file-format.md`, `roles/orchestrator.md`, `roles/*.md`, Phase-1 handoffs, skills-evolution freeze (`docs/proposals/skills-evolution-SYNTHESIS.md`) |

> **Independence note.** Written without reading Claude or Kimi session-mode proposal files. Divergence is intentional. Optimize for **implementability on bash + git + existing dispatch**, not for a new daemon or per-vendor mode product.

> **Evidence rule.** Paths named below were verified with `test -f` / `ls` / `head` against this repo at proposal time. Speculation is marked **(proposed)** or **(later)**.

---

## 1. Executive summary

Session modes are **behavior contracts for the co-pilot chat agent**, not a second orchestration stack. They sit on top of today's Mode 1 (co-pilot CLI) and Mode 2 (`dispatch.sh` fleet) so the human activates **Conductor**, **Wave**, or **Auto** without naming vendors.

- **Conductor:** pin defect → classify role → write shared task packet → emit a **one-line plan** → wait for human **go** → `dispatch.sh` (single seat, full provider/failover path) → verify; chat **does not** implement product code.
- **Wave:** plan multi-role work into `wave-plans/*.plan` (existing format); **no** multi-agent ship until explicit **trigger**.
- **Auto:** pick Conductor / Wave / stay-in-chat from a fixed decision table, announce one line, lock until pin ends.

**Default when unset: Auto** (accept owner strawman), stored in a small config + machine-local session state file — not chat lore alone.

**Implementability spine (this seat's bias):**

1. Reuse `dispatch.sh` for every fleet execution (including single-seat Conductor). Do not invent a parallel runner.
2. Persist mode with grep-friendly files under `config/` + `logs/session-mode/` **(proposed)**.
3. Ship the contract first as an L2 skill pack + template + operator docs; add a thin `session-mode.sh` helper only after the docs path works.
4. Human never names Kimi/Claude/Grok; seat comes from `config/workers.yaml` `provider_preferences` (and failover from `config/routing.yaml`).

**Motivating fix path:** ABarranges whitespace defect routes to `web-frontend` seat via Conductor; expert owns `{" "}` fix + optional learning stub; chat verifies only.

---

## 2. Mode contracts

### 2.1 Shared rules (all modes)

| Rule | Detail |
|------|--------|
| Mode is behavior | Not a new role. Chat still uses existing seats via role map. |
| Vendor opacity | Assignment names **role** (`web-frontend`), never CLI brand, in human-facing speech and plan lines. |
| Git/fleet discipline | Unchanged: task branches, Conventional Commits, no force-push main, no vendor branding on PR face (`git-ship` / guardrails). |
| Untrusted prior | Expert handoffs remain claims; Conductor verifies against git/live, not prose. |
| Escape hatches | Human one-turn overrides always win: `fix here`, `don't dispatch`, `switch to Wave`, `stay in chat`. |
| Visibility | On activate and on Auto gear choice, agent states mode in one short line. |

### 2.2 Conductor (hard rules)

When Conductor is active and the human **pins a concrete product defect** (or asks to fix in-scope product code):

1. **Diagnose lightly** — enough to classify surface → role and write a brief. Not a full root-cause essay, not a PR.
2. **Classify** → one primary **role** (and optional critic role for post-fix if warranted).
3. **Write task packet** using the shared template (§8): user-visible symptom, likely root class, scope, done-when, out-of-scope, learning expectation.
4. **Assign by seat map** — read `provider_preferences` for the role; do not ask the human which vendor.
5. **Do not implement** product code in the Conductor chat (no drive-by expert job).
6. **Propose, then wait** for human **go** / **trigger** before fleet dispatch (MVP; see strawman). Optional later: auto single-seat when confidence high **(later)**.
7. **Dispatch path** — one-line plan + `scripts/dispatch.sh` (§5). Prefer this over raw `run-remote.sh` so failover/retries/logs match fleet.
8. **Verify** after expert returns (live page, `rg` pattern, `git show` on branch). Verification OK; re-authoring the fix is not.
9. **Escapes:** `fix here` / `quick` / pure docs-or-chat → self-do allowed; `don't dispatch` → packet/issue only.

**Out of Conductor force-path:** pure discussion, legal posture, prioritization without a pin → stay advisory even in Conductor mode.

### 2.3 Wave (hard rules + sub-states)

Wave is for multi-role / multi-PR / sprint / architecture work.

| Sub-state | Agent may | Agent must not |
|-----------|-----------|----------------|
| **planning** | Clarify, advise, draft/edit plan files under `wave-plans/`, open design issues | Call `dispatch.sh` / `run-remote.sh` for multi-agent ship |
| **armed** | Hold a named plan path ready; show exact dispatch command | Still not run until human **trigger** |
| **executing** | Only after explicit trigger; monitor logs / wave results | Silently re-dispatch failed waves without human notice on irreversible work |

Sub-states are **not** top-level modes. Persist sub-state next to session mode (§3). Transition:

- planning → armed: plan file exists and agent announces “ready for trigger: `…`”
- armed → executing: human says **trigger** / **go** / **dispatch** (existing operator habit)
- executing → planning: wave complete or human aborts

### 2.4 Auto (hard rules)

- Classify each new pin/request with the decision table (§4).
- **Announce** every gear choice: `Auto → Conductor: …` / `Auto → Wave: …` / `Auto → stay-in-chat: …`
- **Lock** choice for the current pin/task id until: pin resolved, human switches mode, or a **distinct new pin** arrives.
- Ambiguous → **ask once**, then lock.
- Auto never invents a fourth top-level mode.

---

## 3. Activation & persistence

### 3.1 Activation phrases (MVP)

Natural language (case-insensitive intent):

- `Activate Conductor` / `Activate Wave` / `Activate Auto`
- `Switch to Conductor` / `Switch to Wave` / `Switch to Auto`

Slash-like convention (chat text; **not** a new CLI flag on `dispatch.sh`):

- `/mode conductor`
- `/mode wave`
- `/mode auto`
- `/mode` → show current mode + sub-state + lock

Mid-session switch is allowed without restarting the chat product. Agent must acknowledge:

```text
Mode: Conductor (session). I will classify, brief, assign by seat map, and not implement product fixes unless you say "fix here".
```

### 3.2 Where default lives

| Layer | Path (proposed) | Purpose |
|-------|-----------------|---------|
| Fleet default | `config/session-modes.yaml` | `default_mode: auto` + product override table |
| Project override | `<product-repo>/.dev-agents/session-mode` (single line: `conductor` \| `wave` \| `auto`) | Soft-live week → Conductor without human remembering |
| Live session state | `logs/session-mode/<repo-slug>.state` (machine-local under `dev-agents`) | Mode + Wave sub-state + Auto lock id + timestamps |
| Not enough alone | Chat memory | Lost across sessions/vendors |

**Proposed** `config/session-modes.yaml` (grep-friendly, same style as `config/preamble.yaml` / `config/learnings.yaml`):

```yaml
# Proposed — does not exist yet
default_mode: auto          # auto | conductor | wave
# Optional product-repo basename overrides (basename of clone)
project_defaults:
  # olympus-platform: conductor
persist_dir: logs/session-mode
conductor_wait_for_go: true # MVP: always propose then wait
```

**Forgot to activate:** if no session state file and no project override → treat as **Auto** (global default). Agent should not refuse work waiting for an explicit mode ritual.

### 3.3 State file shape **(proposed)**

`logs/session-mode/<repo-slug>.state` — shell-sourceable or line-oriented key=value:

```text
mode=conductor
wave_substate=               # empty | planning | armed | executing
lock_id=                     # Auto lock: hash/slug of current pin
lock_mode=                   # conductor|wave|stay-in-chat when Auto locked
updated_at=2026-07-23T12:00:00Z
plan_path=                   # last drafted plan for Wave/Conductor
```

Session-scoped means **per product repo on this machine**, not per chat vendor. Switching Claude → Kimi co-pilot on the same repo should read the same state file (behavior continuity).

### 3.4 Multi-vendor inject path

Two audiences:

| Audience | Needs mode contract? | Inject mechanism |
|----------|----------------------|------------------|
| **Co-pilot chat** (Mode 1; primary for Conductor) | Yes | L2 skill pack `session-modes` + read live state file; charter slice on `orchestrator` |
| **Fleet workers** (Mode 2 producers/critics) | No (they already have a task line) | Do **not** inject session mode into every producer prompt |

**Do not fold mode into `scripts/preamble.sh` for fleet workers.** Skills-evolution freeze already keeps L2 out of L3; mode is co-pilot policy, not case file noise for every seat.

**Co-pilot inject (MVP, no new vendor APIs):**

1. Map pack `session-modes` onto `orchestrator` in `config/role-skills.yaml` **(proposed change, after skill body lands)**.
2. Document Path B: human opens co-pilot as orchestrator / tech-lead chat and either:
   - pastes output of `scripts/session-mode.sh show` **(proposed)**, or
   - relies on project `CLAUDE.md` one-liner: “Session modes: read `dev-agents` skill `session-modes` + `logs/session-mode/<repo>.state`.”
3. **(later)** optional vendor hooks if a co-pilot product gains them; not MVP and not claimed to exist.

**Fleet path for Conductor execution:** unchanged assembly in `run-remote.sh`: L1 charter → L2 skills via `skill-inject.sh` → L3 preamble → task. Conductor only authors the **task line** and plan file; expert gets normal inject.

### 3.5 Activation syntax vs `dispatch.sh` flags

Verified `dispatch.sh` flags today: `--auto`, `--retries N`, `--review`, `--retry-on-different-worker`.  
**Do not** overload `--auto` (wave continue) with session Auto mode. Session mode is chat contract; `--auto` remains “no press Enter between waves.”

---

## 4. Decision table (Auto)

### 4.1 Full table

| # | Signal (observable) | Auto picks | Lock key |
|---|---------------------|------------|----------|
| A | One surface, clear bug/fix, one role, single PR expected | **Conductor** | pin id |
| B | Multi-role, multi-PR, milestone, sprint planning, architecture | **Wave** (sub-state planning) | milestone / plan slug |
| C | Pure discussion / policy / prioritization / legal posture, no product fix pin | **Stay-in-chat** | topic slug |
| D | “Build the whole X” without decomposition | **Wave** + force clarify | plan slug |
| E | Incident / flaky / “something is broken” with unclear surface | **Stay-in-chat** once to narrow, **or** route `investigate` via Conductor if pin becomes concrete | pin id after clarify |
| F | Docs-only / proposal markdown in `dev-agents` with no product code | **Stay-in-chat** or Conductor→`docs-writer` if human wants a PR | pin id |
| G | Ambiguous between A and B | **Ask once**, then lock | answer |
| H | Human names vendor (“use Kimi”) | **Ignore vendor name**; map role only; remind seats are config | pin id |
| I | Human says `fix here` / `quick` | Stay on current mode but **escape** self-do for this turn | turn |
| J | Human says `trigger` while Wave armed | Execute via `dispatch.sh`; do not re-classify to Conductor mid-wave | plan path |

### 4.2 Announce line format (required)

```text
Auto → Conductor: single legal JSX whitespace defect → role web-frontend (seat from workers.yaml).
Auto → Wave: Soft-live multi-surface sprint → planning plan_path=wave-plans/….
Auto → stay-in-chat: prioritization only; no fleet.
```

### 4.3 Thrash prevention

1. On first classification for a pin, write `lock_id` + `lock_mode` to state file.
2. While `lock_id` matches the active pin, **do not** re-run the table on every message.
3. Clear lock when: human changes mode; expert PR verified done; human says “new pin”; or Auto stay-in-chat topic ends explicitly.
4. Mid-task mode thrash by Auto is a **failure mode** (§13); human override always allowed.

### 4.4 Strawman refinements (marked)

| Topic | Strawman | This proposal |
|-------|----------|---------------|
| Default mode | Auto | **Accept** |
| Conductor dispatch | Propose + wait for go | **Accept for MVP**; later optional high-confidence auto-go **(later)** |
| Wave execute | Always wait for trigger | **Accept** |
| Mode persistence | Session file or preamble inject | **Session state file + config default**; not preamble for workers |
| Activation | NL + `/mode` | **Accept** |
| Learning | Expert stub if novel; skill via promote | **Accept** (skills freeze) |

---

## 5. Conductor runtime path

### 5.1 End-to-end (pin → verify)

```text
Human pins defect in co-pilot chat (Conductor or Auto→Conductor)
        │
        ▼
[1] Light diagnose (read file / live URL / error text) — classify only
        │
        ▼
[2] Role = surface map (§7)  e.g. Next.js JSX whitespace → web-frontend
        │
        ▼
[3] Write task packet → templates/task-packet.md shape
        save optional copy: wave-plans/conductor/<repo>-<slug>.md  (proposed dir)
        │
        ▼
[4] Emit one-line plan (plan-file-format.md):
        1 | web-frontend | <compressed packet> | fix/<slug>
        path: wave-plans/conductor/<repo>-<date>-<slug>.plan  (proposed)
        │
        ▼
[5] Show human:
        Role: web-frontend
        Seat: (from provider_preferences — name role, not vendor, unless human asks)
        Plan: <path>
        Command: /opt/homebrew/bin/bash scripts/dispatch.sh <repo-ssh-url> <plan> --auto --retries 3
        Reply "go" to dispatch, "don't dispatch" for packet-only, "fix here" to escape.
        │
        ▼
[6] Human: go / trigger
        │
        ▼
[7] Conductor (or human shell) runs existing dispatch.sh
        → get_provider / failover / run-remote / skill-inject / preamble / launcher
        │
        ▼
[8] Expert returns (branch + handoff + optional learning stub)
        │
        ▼
[9] Conductor verifies (git + live/pattern). Does not rewrite fix.
        │
        ▼
[10] Clear Auto lock if any; optional learning reminder if stub missing when required
```

### 5.2 Single-seat vs issue-only

| Path | When | Artifacts |
|------|------|-----------|
| **Single-seat dispatch** | Default for in-scope product fix with human go | task packet + 1-line `.plan` + `dispatch.sh` |
| **Issue-only** | `don't dispatch`, offline workers, or human wants board first | task packet + `gh issue create` body from packet (no plan required) |
| **Escape self-do** | `fix here` / `quick` | chat implements; still may append learning if novel |

### 5.3 Why `dispatch.sh` not raw `run-remote.sh`

Verified facts:

- `dispatch.sh` already resolves `provider_preferences`, walks `provider_failover`, sets `AGENT_PROVIDER` / `AGENT_MODEL` / `AGENT_WAVE`, logs under `logs/`, copies plan state under `wave-plans/`.
- `run-remote.sh` is the worker invoke primitive; one-off works but skips wave bookkeeping and failover loop unless the caller reimplements them.

**One-line plans are already legal** (`docs/plan-file-format.md`: wave 1 single task; legacy 3-field lines treat as wave 1). Conductor is a **UX + policy** layer that authors those lines, not a new executor.

### 5.4 Files/scripts touched (by phase)

| Phase | Create/change | Notes |
|-------|---------------|-------|
| 0 (docs) | This proposal; later `docs/session-modes.md`; `templates/task-packet.md` | No runtime |
| 1 (thin helper) | `scripts/session-mode.sh` **(proposed)**; `config/session-modes.yaml` **(proposed)**; `logs/session-mode/` dir | get/set/show + `oneshot` print plan line |
| 1 | `skills/session-modes/SKILL.md` **(proposed)**; map on `orchestrator` in `role-skills.yaml` | Contract inject for co-pilot |
| 2 (optional) | `session-mode.sh dispatch` wrapper that shells to `dispatch.sh` with repo URL | Still no second orchestrator |
| Never (MVP) | Replace `dispatch.sh`, new daemon, Paperclip requirement | Forbidden by brief |

**Proposed** `session-mode.sh` surface (implement later; flags not claimed to exist today):

```text
session-mode.sh show [<repo-slug>]
session-mode.sh set <conductor|wave|auto> [<repo-slug>]
session-mode.sh lock <lock_id> <conductor|wave|stay-in-chat>
session-mode.sh clear-lock
session-mode.sh oneshot --role web-frontend --branch fix/foo --task "..." 
  # prints one plan line + suggested dispatch command; does not run it
```

### 5.5 Worked example — ABarranges (Conductor)

**Pin (human):**  
Live legal copy shows `Pelops AI ABarranges` (missing space after bold “AB”). Next.js RSC / JSX whitespace suspected.

**[1–2] Light diagnose + classify**

- Surface: product web, legal copy JSX, visual whitespace.
- Role: `web-frontend` (orchestrator roster: UI / Next.js → `web-frontend`).
- Not: `go-backend`, `docs-writer`, `investigate` (unless fix fails twice).

**[3] Task packet (filled)** — see §8.2.

**[4] Plan line**

```text
1 | web-frontend | Fix legal copy whitespace: after </strong> AB brand, RSC drops inter-node space so "AB" joins next word (e.g. ABarranges). Insert explicit {" "} (or equivalent) so rendered text has a space. Done when live legal copy shows correct spacing; do not change copy meaning. Learning stub if RSC whitespace class is novel. Out of scope: redesign, i18n, backend. | fix/legal-ab-whitespace
```

**[5] Human-facing assign (no vendor name)**

```text
Mode: Conductor
Role: web-frontend
Plan: wave-plans/conductor/olympus-platform-legal-ab-whitespace.plan
Awaiting: go | don't dispatch | fix here
```

(If human asks “which CLI?”: read `provider_preferences.web-frontend` → currently `kimi` in `config/workers.yaml`; failover `[kimi, claude]` in `config/routing.yaml`. Prefer not to lead with vendor.)

**[6–8]** On `go`, run `dispatch.sh` with that plan. Expert implements `{" "}`, commits, handoff, optional `learnings.sh add` / learning stub file.

**[9] Verify (Conductor)**

- `git show` / diff on branch: space fix only.
- Live or local render: no `ABarranges` glue.
- Confirm learning stub if packet required it.
- Do **not** re-edit JSX in chat.

**Failure this design prevents:** chat self-fixes, no expert PR, no learning, pattern dies in one vendor’s session memory.

---

## 6. Wave runtime path

### 6.1 Authoring

1. Clarify goal, surfaces, constraints.
2. Draft plan file compatible with `docs/plan-file-format.md`:

   ```text
   WAVE | AGENT | TASK_DESCRIPTION | BRANCH_NAME
   ```

3. Enforce hard rules already documented: no same-wave file conflicts; producer then critic on same branch in **different waves**; no raw `|` in descriptions; branch `feat/…` or `fix/…`.
4. Save under `wave-plans/<repo>-<date-or-slug>.plan` (matches existing convention; `dispatch.sh` also auto-saves state copies).
5. Set Wave sub-state **planning** → when plan is complete, **armed** and print:

   ```text
   Wave armed.
   Plan: wave-plans/soft-live-2026-07.plan
   Trigger command:
   /opt/homebrew/bin/bash scripts/dispatch.sh git@github.com:<org>/<repo>.git wave-plans/soft-live-2026-07.plan --auto --retries 3
   Say "trigger" to run (or run the command yourself).
   ```

### 6.2 Human trigger → dispatch

- Explicit phrases: `trigger`, `go`, `dispatch it`, `run the plan`.
- Agent (or human) executes **existing** `scripts/dispatch.sh` with verified flags only (`--auto`, `--retries`, `--review`, …).
- No silent multi-agent shipping while sub-state is planning.
- After trigger, sub-state **executing**; on completion, summarize wave log path under `wave-plans/` / `logs/`.

### 6.3 Conductor vs Wave boundary

| Use Wave | Use Conductor |
|----------|---------------|
| ≥2 roles or ≥2 PRs | One role, one PR |
| Needs wave ordering / parallel fan-out | Single-seat one-liner enough |
| Milestone / Soft-live pack | Pin-point defect |

Auto table encodes this; human can force either mode.

### 6.4 Plan-critic (optional, reuse)

For large plans, Wave planning may include a **plan-critic** seat (primary `grok` per `workers.yaml`) as a **separate** plan line or pre-dispatch review (`dispatch.sh --review` exists). Session modes do not replace plan-critic; they decide whether you are in planning or single-seat land.

---

## 7. Role routing

### 7.1 Surface → role (classification)

Order of signals (Conductor light-diagnose):

1. **Path / stack** (from pin + repo layout): e.g. `apps/web/`, Next.js pages → `web-frontend`; `db/migrations` → `db-architect`; Go handlers → `go-backend`. Align with table in `roles/orchestrator.md`.
2. **Issue labels** if present: `config/routing.yaml` `label_routes` (e.g. `agent:web-frontend` → `web-frontend`, `documentation` → `docs-writer`).
3. **Title patterns** if issue-shaped: `config/routing.yaml` `title_patterns` (advisory; first match wins there).
4. **Symptom class:** pure UI render/JSX/CSS → frontend; API contract → `api-designer` first; authz/secrets → involve `security-reviewer` after producer; unclear production bug → consider `investigate` only when pin stays fuzzy after one clarify.

**ABarranges:** legal JSX whitespace on Next page → path/stack wins → `web-frontend`. No label required.

### 7.2 Role → seat (vendor)

- Read `config/workers.yaml` → `provider_preferences[<role>]` (PRIMARY).
- Failover chain: `config/routing.yaml` → `provider_failover[<role>]` (e.g. `web-frontend: [kimi, claude]`).
- Model tier: `config/routing.yaml` → `model_routing` (Claude tiers; Kimi/Grok launchers ignore opus/sonnet/haiku aliases per file comments).

**Human never required to name vendor.** Conductor speech:

- Preferred: “Assigning **web-frontend** seat.”
- On request: “Primary provider for that seat is configured as kimi in workers.yaml.”

### 7.3 Critic pairing (when)

Conductor MVP: **one producer seat** for the fix. Add critic wave only when:

- human asks for review, or
- change is high-risk (auth, payments, migrations), or
- Wave mode already multi-step.

Pairing matrix remains fleet law (producer → critic on same branch, later wave) — session modes do not invent a new matrix.

---

## 8. Brief / task packet template

### 8.1 Shared DNA with plan lines

One template for Conductor packets and Wave task descriptions. Plan line is a **compressed** packet (must stay pipe-safe: no raw `|`).

**Proposed path:** `templates/task-packet.md`

| Field | Required | Plan-line compression |
|-------|----------|------------------------|
| `title` | yes | start of description |
| `pin` / user-visible symptom | yes | yes |
| `likely_root_class` | yes | short clause |
| `role` | yes | AGENT column |
| `branch` | yes | BRANCH column |
| `scope` | yes | yes |
| `done_when` | yes | yes |
| `out_of_scope` | yes | yes |
| `evidence_paths` | recommended | optional |
| `learning_expected` | yes (`yes`/`no` + stub path hint) | yes if yes |
| `escape_notes` | optional | no |

### 8.2 Template body **(proposed)**

```markdown
# Task packet — <title>

| Field | Value |
|-------|--------|
| Role | <role> |
| Branch | <feat/… or fix/…> |
| Mode source | Conductor | Auto→Conductor |
| Learning expected | yes/no |

## Pin (what user saw)
…

## Likely root class
… (class, not full patch)

## Scope
…

## Done when
…

## Out of scope
…

## Evidence / pointers
- paths, URLs, screenshots refs (no invented auth paths)

## Learning
- If yes: add project or global learning stub under learnings/; do NOT edit skills/*/SKILL.md
```

### 8.3 ABarranges filled packet

```markdown
# Task packet — Legal copy AB whitespace (ABarranges)

| Field | Value |
|-------|--------|
| Role | web-frontend |
| Branch | fix/legal-ab-whitespace |
| Mode source | Conductor |
| Learning expected | yes |

## Pin (what user saw)
Live legal copy rendered “Pelops AI ABarranges” (missing space after bold AB / brand fragment).

## Likely root class
Next.js RSC / JSX inter-node whitespace collapse after </strong> (or adjacent JSX text nodes). Fix class: explicit space in JSX, e.g. {" "}, not copy rewrite.

## Scope
Front-end only. Insert explicit whitespace so rendered HTML/text has a normal space between AB emphasis and the following word. Minimal diff.

## Done when
- Live (or local production build) legal copy shows correct spacing (no “ABarranges” glue).
- Meaning of legal text unchanged.
- Handoff includes evidence (rg/screenshot/command).

## Out of scope
Copy rewrite, i18n, backend, design system churn, drive-by refactors.

## Evidence / pointers
- Component/file that renders the legal line (locate via rg for brand/legal string).
- Do not invent credential or auth file paths.

## Learning
yes — if this is a reusable RSC/JSX whitespace pattern, append a learning stub
(project learnings or dev-agents learnings via learnings.sh). Skill pack updates
only via promotion PR (skills-evolution freeze). Never auto-write skills/*/SKILL.md.
```

### 8.4 Plan-line encoding note

Task descriptions **must not** contain unescaped `|` (`docs/plan-file-format.md` hard rule). Packets living in markdown files may use tables; the one-line plan uses commas / semicolons / slashes for alternatives.

---

## 9. Integration with L1 / L2 / L3

| Layer | Role in session modes |
|-------|------------------------|
| **L1 charter** | `roles/orchestrator.md` gains a **short hard-law slice** (later PR): Conductor does not implement product fixes; Wave waits for trigger; Auto uses table. Other roles unchanged. |
| **L2 skill pack** | New global pack `session-modes` **(proposed)** `skills/session-modes/SKILL.md`: activation, contracts, decision table summary, oneshot plan recipe, escape hatches. Map primarily to `orchestrator` in `config/role-skills.yaml`. |
| **L3 preamble** | **No** mode injection into fleet worker preambles. Case file stays git/learnings/handoffs. |
| **Task line** | Still highest operational acceptance criteria for the expert. |
| **Mode vs skill** | **Mode** = session behavior contract for the co-pilot. **Skill** = how to execute that contract. Mode state is not a skill body. |

Authority order unchanged (skills-evolution freeze): charter hard laws > project skill > global skill > L3 case > task text. Session mode hard laws belong in charter slice + skill pack; state file is operational, not policy outranking charter.

**Paperclip:** optional future consumer of the same plan lines / packets. **Not** an MVP dependency.

---

## 10. Learnings policy

| Outcome | Action |
|---------|--------|
| Novel platform quirk (RSC whitespace class) | Conductor packet sets `learning_expected: yes`; expert adds stub via `scripts/learnings.sh add <project> <agent> pattern|discovery|failure "…"` and/or a short note under `learnings/` as today |
| Routine one-off typo | `learning_expected: no` |
| Skill pack update | **Never** from Conductor auto-path. Promotion PR only (`skills-evolution-SYNTHESIS.md`) |
| Chat-only fix with escape hatch | Conductor/human should still file a learning if pattern is reusable; otherwise the ABarranges failure repeats |

Session chat memory alone is **insufficient** for fleet-wide lessons (brief R9). Modes make the learning **checkbox** visible in the packet; they do not auto-promote skills.

---

## 11. Phased rollout

### Phase 0 — Docs + contract only (~2–4 days)

Ship:

- Synthesis later picks design; this proposal is input.
- After owner synthesis: `docs/session-modes.md` operator page (link from README Mode 1/2 section).
- `templates/task-packet.md`
- `skills/session-modes/SKILL.md` + `role-skills.yaml` map for `orchestrator`
- Short orchestrator charter patch (hard laws only)

**No** new scripts required for Phase 0. Human activates by phrase; agent follows skill if loaded; dispatch remains manual command copy-paste.

**Success gate:** Conductor used once on a real pin without chat self-fix.

### Phase 1 — Thin helper + state (~3–5 days)

Ship:

- `config/session-modes.yaml`
- `scripts/session-mode.sh` (show/set/lock/oneshot)
- `logs/session-mode/` gitignored if needed (check repo ignore rules at implement time)
- `wave-plans/conductor/` convention for oneshot plans
- Operator cookbook examples in `docs/operator-guide.md`

Still: human **go** before `dispatch.sh`. Helper **prints** dispatch command; optional `dispatch` subcommand is a thin exec wrapper only.

### Phase 2 — Polish **(later)**

- Project override file `.dev-agents/session-mode`
- Optional high-confidence Conductor auto-go (config flag; default false)
- Metrics hooks (§12)
- Co-pilot vendor hook integration **if** products expose them (not invented here)

### Explicitly not in 1–2 week MVP

- Autonomous CEO / spend without human go for waves
- Auto-merge skills
- Replacing `dispatch.sh`
- Handoff-brain Phases 2–5 revival
- Per-vendor proprietary mode systems

---

## 12. Success metrics

| Metric | Direction | How to observe (lightweight) |
|--------|-----------|------------------------------|
| % of pin-point product defects **self-fixed in Conductor chat** | **Down** | Spot-check sessions; owner tally weekly |
| % of pins that produce a task packet + role | **Up** | Files under `wave-plans/conductor/` or handoff notes |
| Time pin → expert PR opened | **Down or stable with higher quality** | `gh` timestamps vs pin time |
| Brief quality | Packet fields complete; pipe-safe plan lines parse | `dispatch.sh` parse failures = 0 on oneshots |
| Learning stubs on novel quirks | **Up** when `learning_expected: yes` | `learnings.sh query` / `learnings/` notes |
| Auto thrash events (mode flip mid-pin without human) | **Near zero** | State file lock violations / owner reports |
| Human still names vendors to route work | **Down** | Anecdote + chat review |

No new metrics daemon in MVP. CSV or owner notes sufficient (pattern already seen with `wave-plans/*.csv` style artifacts).

---

## 13. Failure modes

| Failure | Cause | Mitigation |
|---------|--------|------------|
| Primary seat unavailable / rate-capped | e.g. kimi exit 75 | `dispatch.sh` failover already; Conductor does not hardcode vendor |
| Wrong role | Misclassify surface | Light path/label check; human override; one reassign with new oneshot plan |
| Conductor still codes | Skill/charter not loaded; habit | Phase 0 skill + charter hard law; verify metric; escape hatch explicit only |
| Auto thrash | No lock | State file `lock_id`; announce; refuse silent reclass mid-pin |
| Mode not injected | Co-pilot without skill/charter | Default Auto still documented in `docs/session-modes.md`; `session-mode.sh show` paste path; project CLAUDE.md pointer |
| Human uses `--auto` thinking it means session Auto | Flag collision | Docs: `dispatch.sh --auto` ≠ session Auto |
| Plan parse break | `|` in task description | Template + skill anti-pattern; same hard rule as plan-file-format |
| Expert skips learning when required | Packet ignored | Conductor verify step checks learning expectation |
| Silent multi-agent ship | Wave skips trigger | Sub-state armed≠executing; skill hard rule |
| State file races (two co-pilots) | Two chats same repo | Last writer wins; announce mode on each activate; acceptable MVP |
| Invented paths/flags | Model hallucination | evidence-first skill; only document verified `dispatch.sh` flags |

---

## 14. Explicit non-goals (MVP)

1. Full autonomous CEO agent that spends money / ships waves without human go.
2. Auto-merge of skills from Conductor outcomes (promotion PR only).
3. Replacing or forking `dispatch.sh` as a second orchestration product.
4. Killing multi-vendor orchestration or hardcoding one vendor into Conductor speech.
5. Deep revival of handoff-brain Phases 2–5.
6. Per-vendor proprietary mode systems that diverge forever.
7. Paperclip as required runtime for modes.
8. Injecting session mode into every fleet producer preamble.
9. New top-level modes beyond Conductor / Wave / Auto.
10. Claiming session modes already ship in this repo (they do not).

---

## 15. Open questions for the owner

1. **Project override path:** Is `<product>/.dev-agents/session-mode` acceptable, or prefer a key in existing product `CLAUDE.md` only?
2. **Conductor auto-go:** Keep `conductor_wait_for_go: true` until Soft-live week ends, or allow an early opt-in for high-confidence single-seat?
3. **Issue creation:** Should Conductor always open a GitHub issue before dispatch for product repos (orchestrator charter already pushes issue discipline for PR-bound work), or only when human asks?
4. **Critic by default:** For frontend pin-points, is producer-only enough in MVP, or always schedule `frontend-critic` wave 2 on the same branch?
5. **State file location:** Prefer `dev-agents/logs/session-mode/` (fleet machine) vs product-local `.dev-agents/session-mode.state` (travels with repo, risk of commit)?
6. **Co-pilot boot:** Is paste-from-`session-mode.sh show` enough for Phase 0, or should product repos get a mandatory CLAUDE.md blurb in Soft-live?
7. **Naming collision:** Confirm never aliasing session Auto to `dispatch.sh --auto` in docs/UI copy.
8. **ABarranges learning home:** project `learnings/` vs `dev-agents/learnings/` for RSC whitespace class (global pattern vs product-only)?

---

## Appendix A — Verified anchors (no invention)

| Item | Verified path / fact |
|------|----------------------|
| Dispatch | `scripts/dispatch.sh` — flags `--auto`, `--retries`, `--review`, `--retry-on-different-worker` |
| Remote run | `scripts/run-remote.sh` |
| Skill inject | `scripts/skill-inject.sh` + `config/role-skills.yaml` |
| Preamble L3 | `scripts/preamble.sh` + `config/preamble.yaml` |
| Learnings CLI | `scripts/learnings.sh` — `add` / `query` / `prune` / `stats` |
| Seats | `config/workers.yaml` `provider_preferences` (e.g. `web-frontend: kimi`, `plan-critic: grok`, `orchestrator: claude`) |
| Failover | `config/routing.yaml` `provider_failover` |
| Plan format | `docs/plan-file-format.md` — `WAVE \| AGENT \| TASK \| BRANCH` |
| Plans live | `wave-plans/` |
| Orchestrator charter | `roles/orchestrator.md` |
| Skills freeze | `docs/proposals/skills-evolution-SYNTHESIS.md` |
| README modes today | Mode 1 co-pilot vs Mode 2 fleet — session modes **extend**, not replace |

## Appendix B — Implementability checklist (for synthesis → build)

- [ ] One contract, three modes only  
- [ ] Default Auto in `config/session-modes.yaml`  
- [ ] State under `logs/session-mode/` (or owner-chosen alternative)  
- [ ] Conductor oneshot = **1-line plan + existing dispatch.sh**  
- [ ] Wave = plan file + human trigger + existing dispatch.sh  
- [ ] L2 pack `session-modes` on orchestrator; no L3 mode spam to workers  
- [ ] Shared `templates/task-packet.md`  
- [ ] Learning stub allowed; skill auto-promote forbidden  
- [ ] ABarranges path works without naming Kimi in the assign line  
- [ ] Phase 0 docs/skill before scripts  

---

*End of Grok seat proposal. Not an implementation. Not a claim that session modes ship today.*
