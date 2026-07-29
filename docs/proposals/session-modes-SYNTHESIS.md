# Session Modes — Owner Synthesis (Phase 0 freeze)

**Status:** FREEZE — Phase 0 ship surface  
**Date:** 2026-07-29  
**Sources:** `session-modes-BRIEF.md` + three independent seat proposals (A/B/C)  
**Implementation:** Phase 0 = docs + skill + template only (this freeze). No daemon.

---

## 1. Decision

Ship **three session modes** as **co-pilot behavior contracts** on top of existing fleet:

| Mode | Job |
|------|-----|
| **Conductor** | Pin → classify → task packet → role seat → human **go** → `dispatch.sh` (or issue-only). Chat **does not** implement in-scope product code. |
| **Wave** | Plan multi-role work → `wave-plans/*.plan` → human **trigger** → `dispatch.sh`. Sub-states: *planning* / *armed*. |
| **Auto** | Pick Conductor / Wave / stay-in-chat via decision table; announce; lock per pin. **Does not** add autonomy — only selects which contract applies. |

**Default:** Auto (when skill/docs are loaded).

**Not the same as:** `dispatch.sh --auto` (wave continuation flag). Session Auto never means auto-merge or silent fleet ship.

---

## 2. Hybrid taken from seats

| From | Keep |
|------|------|
| Brief + Claude | Human gates MVP; Conductor never codes product; ABarranges as worked example |
| Grok | Implement on bash+git+dispatch; no new daemon; task packet → one-line plan |
| Kimi | Evidence/scorecard stays separate (already step 2); don't block Phase 0 on measurement |

---

## 3. Phase 0 ship list (this PR / wave)

- [x] This synthesis  
- [x] `docs/session-modes.md` (operator contract)  
- [x] `templates/task-packet.md`  
- [x] `skills/session-modes/SKILL.md` + map on `orchestrator`  
- [x] Hard laws on `roles/orchestrator.md`  
- [x] `wave-plans/conductor/` convention (README)  
- [x] Links from README + operator-guide  

## 4. Explicitly later (not Phase 0)

- `session-mode.sh` / persisted mode files / thrash locks  
- Silent Wave execute or Conductor auto-go  
- Butler / always-on presence product  
- Auto-promote skills from conductor outcomes  

## 5. Success (Phase 0)

1. Docs + skill pass `skills-lint` / human review  
2. Operator can run Conductor grammar from docs without new binaries  
3. One real pin can produce packet + one-line plan under `wave-plans/conductor/` that `dispatch.sh` parses  

## 6. Owner open (optional later)

- Product override of default mode (e.g. Soft-live week → Conductor) via `companies/*.md` frontmatter — not required for Phase 0  
