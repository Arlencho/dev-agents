# Handoff — fix/2690-mobile-nav comment/docs pass (PR #2719)

## Built

Comment-and-docs-only commit `baf0a1c4` on `fix/2690-mobile-nav`, pushed; PR #2719 updated in place (body edited via `gh pr edit`). No new PR, no merge.

- `docs/prd/02-shells.md` — all three `PROPOSED — pending co-founder sign-off` markers tied to #2690 (lines 3, 39, 131) converted to `APPROVED` with the exact relayed provenance: "Approved by Arlen, 2026-08-19, given in session and relayed by the orchestrator …" including the signed-out-guest help-trigger consequence per the Art. 5 / #1586 contract. Also corrected the same line-131 claim from "four primary destinations unreachable" to three (Plan stayed reachable).
- Three in-tree comments claiming all four primary destinations were unreachable below 720 px corrected to Explore/Stays/Stories-only: `apps/web/components/ra-header.tsx` file docblock (~L29) and `RAHeaderMobileNav` docblock (~L572), `apps/web/app/globals.css` mobile-nav comment (~L909). A fourth instance in the `mobile-nav.spec.ts` header docblock was corrected too (same false claim, same file I was already rewording).
- `apps/web/tests/e2e/critical/mobile-nav.spec.ts` header docblock — the "spec guards the invariant, not the chrome" passage rewritten to state honestly that the spec pins the shipped chrome (toggle, testids, collapsed `.ra-nav`) and a conformant wrap-instead-of-collapse redesign would go 5/5 red and must update the spec.
- PR body: same two overstatements fixed (summary paragraph, test-plan paragraph), and the stale "marked PROPOSED / nothing is stamped accepted" lines updated to APPROVED with the relayed provenance.

## Decisions (+why)

- The task said "three in-tree comments"; there were actually **four** (the spec header docblock repeats the claim). Fixed all four — leaving a known-false claim in the file being edited for that exact correction would have been worse. Still comment-only, so within scope.
- PRD line 131's "four primary destinations unreachable" was fixed alongside the marker conversion — same correction, same sentence, docs file is in scope.
- PR body's "Nothing is stamped accepted" line updated; otherwise the body would contradict the PRD it describes.
- Phrasing in code comments says the CTA "calls the same `onPlanClick` handler" / "dispatch handleNav plan" — verified: logo `onClick={() => handleNav("plan")}` (ra-header.tsx:171), CTA `onClick={onPlanClick}` (:258), and `handleNav("plan")` falls through to `onPlanClick()` when no `onNav` (:152-154). The critic's claim checks out.
- Did NOT touch the assertion message at mobile-nav.spec.ts:63 ("Plan/Explore/Stays/Stories have no entry point") — it is a test assertion string, and this change was comment-only. It is also arguably forward-looking ("without it"), but if the critic wants it aligned, that is a test change for a follow-up.

## Do not repeat

- Don't look for more PROPOSED markers for #2690 — grep confirms only the three existed; none for other issues were present in this file.
- Don't run the full `npm run build` for assurance here — it was skipped deliberately (comment-only diff); `npx tsc --noEmit` exit 0 and eslint exit 0 on the touched files are the evidence.

## Evidence

- `git diff` filtered of comment/blank lines on `apps/web/**` → empty (proof command: `git diff -- apps/web | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]\s*$' | grep -vE '^[+-]\s*(/\*|\*|//|\*/)'` → "NO NON-COMMENT CHANGES in apps/web").
- `npx tsc --noEmit` in `apps/web` → exit 0. `npx eslint` on the three touched files → 0 errors (1 expected "file ignored" warning for globals.css).
- Push: `876e1a0a..baf0a1c4 fix/2690-mobile-nav -> fix/2690-mobile-nav`.
- `gh pr view 2719` confirms head `fix/2690-mobile-nav`; body updated in place.

## Open questions / Next hint

- The critic should focus on: (1) whether the spec:63 assertion message should also be reworded (deferred — it's a test change); (2) whether "APPROVED … relayed by the orchestrator" wording satisfies whatever audit trail issue #2690 expects, given there is no first-party GitHub review from Arlen on the PR; (3) the still-open parts of #2690 (flight-card clipping at 375 px, desktop two-panel split) are untouched, as before.
