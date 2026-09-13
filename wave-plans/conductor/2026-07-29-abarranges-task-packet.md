# Task packet (Conductor)

## Pin / symptom

Historical / drill pin: live legal copy once rendered **Pelops AI ABarranges** (missing space after bold entity name).

## Light diagnosis (read-only, 2026-07-29)

| Check | Result |
|-------|--------|
| Source | `olympus-platform/apps/web/app/legal/package-info/page.tsx` L88–90 already uses `{" "}` between `</strong>` and `arranges` |
| Repo scan | 0 remaining `</strong>`→word fuse patterns under `apps/web/**/*.tsx` |
| Live | `https://app.olympus-ai.tech/legal/package-info` HTML shows space / comment nodes between bold name and `arranges` (not `ABarranges`) |
| Learning | No `ABarranges` / RSC-whitespace learning under olympus or fleet `learnings/` |

**Primary product defect: already fixed.** Conductor will not re-author the JSX fix.

## Likely root class

Next.js / RSC / JSX: whitespace between element nodes can collapse; explicit `{" "}` (or equivalent) required after `</strong>` before a following word.

## Role seat

`web-frontend`

## Scope

- In:
  - Learning stub under product or fleet `learnings/` documenting the class + fix pattern
  - Cheap regression if cheap (component unit test or lint/grep guard for `</strong>\n` + word without `{" "}`)
- Out:
  - Rewriting legal copy
  - Backend / KYB / Soft-live policy
  - Re-implementing the already-fixed package-info space

## Done-when

1. Learning stub exists with root class + `{" "}` pattern + pointer to package-info fix.
2. Optional: one automated check that would fail if someone removes the explicit space on that line or reintroduces fuse pattern on legal pages.
3. No live `ABarranges` on `/legal/package-info` (already true at smoke time).

## Evidence / pointers

- `apps/web/app/legal/package-info/page.tsx` (fix present)
- Live: `https://app.olympus-ai.tech/legal/package-info`
- Contract: `dev-agents/docs/session-modes.md` § ABarranges
- Repo: `Arlencho/olympus-platform`

## Learning expectation

- [x] Expert should add learning stub if novel (path: `learnings/` in olympus-platform or fleet, owner choice)

## One-line plan (for dispatch.sh)

```
1 | web-frontend | ABarranges class: product JSX already fixed; add learning stub + cheap regression for RSC whitespace after bold entity; do not rewrite legal copy | feat/learn-abarranges-rsc
```

## Dispatch (after human "go")

```bash
cd /Users/arlenrios/Desktop/dev-projects/AI-Orchestration/dev-agents
./scripts/dispatch.sh git@github.com:Arlencho/olympus-platform.git wave-plans/conductor/2026-07-29-abarranges-learn.plan
```
