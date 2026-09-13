# Handoff - feat/ac-handover-landing (issue #2842)

## Built

Amended PRD 06 § 4 / § 6.6.5 behaviour for the `/r/{id}` trip page (wave 1 PRD text already on this branch as 060e4f34).

- `apps/web/lib/chat-step-machine/project-snapshot.ts` - `buildRehydratedResultsSnapshot` no longer returns null when the walk stops at an unanswered `budget`. A new `skipUnansweredBudgetLanding` rewrites that landing into the natural all-answered `confirmSearch` landing: the budget ask leaves the thread, `history` gains `who` (budget's predecessor, mirroring what the natural landing holds), and the pending confirmSearch ask is appended so the existing template-summary patch fills it. Location gate and hotel checkout reroute untouched - they run on the confirm→searching→picker submits exactly as before.
- `apps/web/app/r/[id]/atlas-result-session-page.tsx` - `useAgentSources` now also returns the record's `selected_offer_id` (omitted on § 13.4 snapshot projections). New `applyRecordSelectedOffer` injects `pick.flight` into the rehydrated landing snapshot when the id matches a flight in `result_snapshot.flights`; a non-matching id lands with no selection. Flight landings only (`snapshot.step === "flight"`).
- `apps/web/components/chat/chat-step-renderer-helpers.ts` - new exported `flightPickPayload(flight, cabin)`: the exact `FlightSelection` body FlightStep's `onPickResult` used to build inline, so the record-carried pick freezes the same booking facts from the mapped result.
- `apps/web/components/chat/result-picker-steps.tsx` - `onPickResult` now calls `flightPickPayload(flight, cabin)`; FlightWidget gets `selectedId={ctx.pick.flight?.id}`.
- `apps/web/components/widgets/flight-widget.tsx` - new `selectedId` prop; the matching card root gets `aria-current="true"`, `data-offer-id`, an indigo highlight, and a one-shot `scrollIntoView({ block: "center" })` on first paint.
- Tests: `project-snapshot.test.ts` (budget-less landing, budget-bearing regression guard, null now keyed on missing dates instead of missing budget); `atlas-result-session-page.test.tsx` (new #2842 describe: 40 offers + no budget lands on the flight step with no budget ask; matching `selected_offer_id` renders exactly one `aria-current="true"` card and the aside summary shows it; absent/unknown ids render none).

## Decisions (+why)

- The budget skip lives inside `buildRehydratedResultsSnapshot`, not in `createInitialState`: the old "missing budget → null" contract stays true for every other caller, and the amend rule ("committed results supersede an unanswered optional step") is a property of the committed-results landing, not of funnel init.
- History appends `"who"` to mirror the natural confirmSearch landing byte-for-byte (`plan.skipped.slice(0, -1)`); reaching `budget` implies intro/where_from/when/who are all answered, so `who` is always the right entry.
- No query parameter: `selected_offer_id` comes from the record only, per the task and PRD § 6.6.5's third trigger.
- The payload `cabin` is derived from the offer's own stated cabin (`statedOfferCabin`), because under strict per-cabin lists (#2515) the active chip at pick time IS the offer's cabin; an offer stating no cabin defaults to economy, the tab it renders under.
- Selection highlight is driven by `ctx.pick.flight?.id`, not a one-off flag: a traveller who picked in-page and revisits the flight step sees the same selected card - same § 6.6.5 state, one mechanism.

## Do not repeat

- The widget's own `FlightCard` (in `components/widgets/flight-widget.tsx`) is NOT `components/flight-card.tsx` - the latter already had `aria-current` for the /trip surface; the chat widget had no selection support at all. Don't look for existing highlight wiring on this surface; there was none.
- Budget has no skip/sentinel path in the step machine: "I'm flexible" submits a real number and would have created a budget pill. That is why the fix rewrites the landing state instead of dispatching a submit.
- `npx vitest` before `npm install` pulls an npx-cached vitest that fails to load `vitest.config.ts` ("Cannot find module 'vitest/config'"). Run `npm install` at the repo root first.

## Evidence

- `cd apps/web && npx vitest run lib/chat-step-machine/project-snapshot.test.ts` → 28 passed (exit 0)
- `cd apps/web && npx vitest run "app/r/[id]/atlas-result-session-page.test.tsx"` → 14 passed (exit 0)
- `cd apps/web && npx vitest run components/chat/result-picker-steps.test.tsx components/widgets/flight-widget.test.tsx components/widgets/flight-widget-see-more.test.tsx components/chat/chat-step-renderer.test.tsx components/chat/context-aside-v2.test.tsx` → 178 passed (exit 0)
- `cd apps/web && npm run typecheck` → exit 0
- `npx eslint` on all seven touched files → exit 0
- `make test-web` full-suite result: see PR body (run at ship time)

## Open questions

- If a record-carried offer sits beyond the picker's initial "See more" window, no card renders for it and nothing is highlighted - accepted per task scope (the id-matches-nothing rule covers render absence). A future slice could auto-reveal the list to the selected offer.
- A non-economy record-carried offer renders selected only when its cabin tab is the one on screen; the landing shows the featured cabin. Same family as the row above.

## Next hint

Critic: focus on `skipUnansweredBudgetLanding`'s fidelity to the natural confirmSearch landing (thread/history/messageIdCounter), and on whether `aria-current` + scroll behave on a revisit (cached-snapshot path also passes `selectedId` now - pick.flight persists there).
