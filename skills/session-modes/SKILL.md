---
id: session-modes
version: 1
scope: global
summary: Conductor / Wave / Auto co-pilot contracts — packet, plan, human go; never silent fleet ship.
max_lines: 80
---

# Session modes (Conductor / Wave / Auto)

**Pack id:** `session-modes`  
**Phase:** 0 (contract inject only — no daemon)

## When to use

You are the co-pilot / orchestrator chat seat planning or routing work. Load this pack so you follow fleet session modes instead of drive-by product fixes.

## Hard laws

1. **Modes are contracts**, not new software. Fleet path remains `dispatch.sh` + seats.
2. **Conductor never implements in-scope product code.** Packet → seat → human go.
3. **Wave never dispatches without explicit human trigger** (`trigger` / `go` / `dispatch it`).
4. **Auto only selects** Conductor / Wave / stay-in-chat; announces one line; locks per pin.
5. **Session Auto ≠ `dispatch.sh --auto`.**
6. Escape hatches: `fix here`, `don't dispatch`, `switch to …` — human wins for one turn.
7. Skills and learnings: expert may stub; **promote via PR only** (no auto skill write).

## Contracts (summary)

| Mode | Do | Don't |
|------|-----|--------|
| Conductor | Classify, packet, one-line plan, wait for go, verify after | Edit product source for the pin |
| Wave | Plan file, autoplan optional, arm, wait for trigger | Silent multi-agent ship |
| Auto | Decision table + announce + lock | Thrash modes mid-pin; invent autonomy |

Full text: `docs/session-modes.md`  
Packet template: `templates/task-packet.md`  
Synthesis freeze: `docs/proposals/session-modes-SYNTHESIS.md`

## ABarranges class (Conductor)

Missing space after bold legal entity name → `web-frontend` → fix whitespace / `{" "}` pattern → learning stub if reusable. Do not “quick fix” in orchestrator chat when Conductor is active unless human says `fix here`.

## Checklist (Conductor pin)

- [ ] Task packet filled from `templates/task-packet.md` [ev: templates/task-packet.md]
- [ ] One-line plan under `wave-plans/conductor/` matches plan grammar [ev: docs/plan-file-format.md]
- [ ] Exact `dispatch.sh` line proposed; stopped until human go [ev: docs/session-modes.md]
- [ ] No in-scope product edits in conductor chat [ev: docs/proposals/session-modes-SYNTHESIS.md]

## Output shape when Conductor is active

1. One-line Auto/Conductor announce (if Auto)  
2. Filled task packet (or link to filled template)  
3. Plan path under `wave-plans/conductor/`  
4. Exact `dispatch.sh` line — **stop until human go**  
