# Session Modes — Conductor / Wave / Auto

**Phase 0 contract** for co-pilot chat (any subscription CLI seat).  
**Freeze:** [`docs/proposals/session-modes-SYNTHESIS.md`](proposals/session-modes-SYNTHESIS.md)

Modes change **how the chat agent behaves**. They do **not** replace `dispatch.sh`, seats, or critics.

> **Naming:** Session **Auto** ≠ `dispatch.sh --auto` (that flag only auto-continues waves after human-triggered dispatch).

---

## Activation

Natural language or slash-like (chat conventions — not a new CLI product):

- `Activate Conductor` / `Activate Wave` / `Activate Auto`
- `/mode conductor` | `/mode wave` | `/mode auto` | `/mode` (report)

Escape hatches (one turn, do not require mode switch):

- `fix here` / `quick` — co-pilot may self-do that item  
- `don't dispatch` — packet or issue only  
- `switch to Wave` / `switch to Conductor` — persisted intent for the session  

**Default when skill is loaded:** Auto.

---

## Conductor (task-by-task)

**When:** One surface, clear bug/feature, one primary role.

### Hard rules

1. Diagnose lightly (read-only; minutes, not an implementation session).  
2. Classify surface → **role** from fleet seats (`workers.yaml` / routing).  
3. Write a **task packet** ([`templates/task-packet.md`](../templates/task-packet.md)).  
4. Compress to a **one-line plan** under `wave-plans/conductor/` using [`plan-file-format.md`](plan-file-format.md).  
5. **Propose, then wait for human "go"** before running `dispatch.sh`.  
6. **Never implement in-scope product code** in the conductor chat (ABarranges rule).  
7. After expert returns: verify (tests, live check, diff) — do not re-author the fix.  
8. If novel platform quirk: require expert **learning stub** in packet (skills still PR-gated).

### Worked example — ABarranges

**Pin:** Live legal copy shows `Pelops AI ABarranges` (missing space after `</strong>`).

| Field | Value |
|-------|--------|
| Symptom | RSC/JSX whitespace dropped between bold entity name and “arranges” |
| Role | `web-frontend` |
| Done-when | Visible space in prod; unit/regression if cheap |
| Out of scope | Backend, legal rewrite, multi-page redesign |
| Learning | If reusable, stub under product or global `learnings/` |

Plan line:

```
1 | web-frontend | Fix missing space after Pelops AI AB bold (ABarranges class); keep legal copy | feat/fix-abarranges-space
```

Human: **go** → `./scripts/dispatch.sh <repo> wave-plans/conductor/<name>.plan`

---

## Wave (multi-agent)

**When:** Multi-role, multi-PR, milestone, architecture, sprint planning.

| Sub-state | Behavior |
|-----------|----------|
| **planning** | Clarify, decompose, write `wave-plans/*.plan`. May run `autoplan.sh`. **No dispatch.** |
| **armed** | Human says plan is final. Agent echoes exact `dispatch.sh` command and waits. |

**Execute only on explicit trigger:** `trigger` / `go` / `dispatch it`.  
Any plan edit → back to *planning*.

Autoplan is fail-closed (Ground Truth): fix plan and re-run; optional `--allow-revise`.

---

## Auto (selector only)

| Signal | Pick |
|--------|------|
| One surface, clear bug, one role | **Conductor** |
| Multi-role, multi-PR, milestone, sprint | **Wave** |
| Pure question / docs / no product pin | **Stay in chat** |
| Ambiguous | One question, then lock |

On each choice, announce one line:

```text
Auto → Conductor: single legal JSX defect → web-frontend seat.
```

**Lock per pin** until human switches or a new distinct pin arrives.  
Auto inherits Conductor/Wave human gates (still waits for go/trigger).

---

## Runtime path (no new binaries)

```
Co-pilot chat (mode contract)
    → task packet / wave plan
    → human go | trigger
    → scripts/dispatch.sh   (existing multi-vendor fleet)
    → seats + critics + human merge
```

---

## Related

- Operator ops: [`operator-guide.md`](operator-guide.md)  
- Plan grammar: [`plan-file-format.md`](plan-file-format.md)  
- Evidence: `make evidence`  
- Skill: `skills/session-modes/SKILL.md`  
