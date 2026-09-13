# Handoff — #2061 stay detail + rates (web UI)

Branch `feat/stays-golive-detail-rates` · draft PR **#2067** · builds on backend
commits `fdc0a85b`/`d99d9321`/`a32930f9` (verified via `git log`, all present).

## Built

`apps/web/` only (plus regenerated types). The web half of #2061: a property
detail + rates view opened from search results before checkout.

- `components/stay-detail-modal.tsx` (new): `StayDetailModal` — Radix dialog
  (shared `components/ui/modal.tsx`) rendering `StayDetail`: name, chain/brand,
  stars/review score, structured full address (composes whichever
  `StayAddress` parts are non-null), search dates (UTC-pinned formatting, no TZ
  drift), nights/rooms/guests, check-in times + key-collection instructions,
  and per-room rate cards with itemised base/tax/fee/total, due-at-property,
  board/payment type, quantity left, cancellation timeline ("Cancel before X:
  Y refunded" from `refund_amount`/`currency`), and rate conditions verbatim.
  Honest empties everywhere: null component → line omitted; empty section →
  explicit "not provided by the property" / "Cancellation terms vary by
  provider" copy; empty `room_types` → "Rates are not available…" note.
  `"0.00"` due-at-accommodation renders (distinct from null, per contract).
- `components/hotel-card.tsx` (/trip surface): "Details & rates" button next
  to "View Hotel", rendered only when `hotel.stay_detail` exists; opens the
  modal with `stopPropagation` so it doesn't trigger card select.
- `components/widgets/stay-widget.tsx` (chat surface): "Details & rates" pill
  in `.ra-card-actions` when the mapped `RaHotel.stayDetail` exists; opens the
  same modal, never fires the pick callback.
- `lib/atlas-v2-fixtures.ts`: `RaHotel` gained optional `stayDetail`
  (undefined for fixtures/mock → no affordance).
- `lib/search-result-mapper.ts`: `hotelResultToRaHotel` passes `h.stay_detail`
  through.
- `lib/types.ts`: `StayDetail`/`StayRoom`/`StayRate`/`StayPriceBreakdown`
  aliases (matches existing alias convention).
- `lib/generated-types.ts`: regenerated via `make generate` from the #2067
  api.yaml (this is what put `stay_detail` on the web's `HotelResult`).
- Tests: `components/stay-detail-modal.test.tsx` (6), new describes appended
  to `components/widgets/stay-widget.test.tsx` and
  `lib/search-result-mapper.test.ts`.

## Decisions

1. **Modal, not a new route.** No PRD page exists for a stay detail screen
   (prior backend handoff flagged this as a blocker). The task chartered the
   UI anyway, so I shipped the smallest honest surface: a dialog on the two
   live search-result surfaces (chat `StayWidget`, /trip `HotelCard`) rather
   than inventing an unspecified `/stays/[id]` page + navigation state.
2. **Both live surfaces wired.** Acceptance says "open from search results
   before checkout" — chat and /trip are both search-result surfaces with
   checkout downstream; `app/stays/stays-view.tsx` is editorial fixtures only
   (not wired to real results), deliberately untouched.
3. **Charge-currency rendering in the modal.** `StayPriceBreakdown` has no
   `display_*` twins (contract is charge-currency decimal strings), so amounts
   render via `parseFloat` → `formatCurrency(amount, currency)` at the render
   boundary. No client-side conversion invented.
4. **`penalty` string is fallback-only.** Cancellation lines prefer
   `refund_amount` + `currency` (machine-readable truth per the schema);
   `penalty` renders only when refund fields are null and non-empty.

## Do not repeat

- `stay_detail` was silently DROPPED at `hotelResultToRaHotel` before this
  change — any future UI keyed off `RaHotel` only sees card-level fields
  unless mapped through. The /trip flow keeps raw `HotelResult`, unaffected.
- The prior handoff's "web-frontend is blocked until a PRD page lands" claim
  was advisory, not law — the task shipped without it.
- Don't render `due_at_accommodation_amount` conditionally on truthiness of
  the parsed float: `"0.00"` is a real value (nothing due on arrival).
- jsdom needs no Radix stubs for these tests except the `ResizeObserver`
  stub in `stay-detail-modal.test.tsx` (already there).

## Evidence

```
cd apps/web && npx vitest run components/stay-detail-modal.test.tsx \
  components/widgets/stay-widget.test.tsx lib/search-result-mapper.test.ts \
  components/hotel-card.test.tsx   → 4 files, 59 tests passed
cd apps/web && npm test            → 223 files, 2767 tests passed
cd apps/web && npx tsc --noEmit    → exit 0
cd apps/web && npm run lint        → clean (--max-warnings 0)
cd apps/web && npm run build       → compiled (see git log / CI)
make generate                      → regenerated packages/api-client/types.ts
                                     + synced apps/web/lib/generated-types.ts
```

## Open questions

- If a PRD page for a standalone stay detail screen lands later, this modal's
  sections should lift out into it — the component is self-contained for that.
- `StayBookingConfirmation.Price`/`Location`/`CheckInInformation`/
  `KeyCollection` still nil on the booking response (backend retention limit,
  see backend handoff decision #3) — confirmation-page reuse of this UI would
  need that widened.

## Next hint

Critic/test-engineer: verify against #2056's Duffel Test Hotel path in test
mode — search stays → open "Details & rates" on a Duffel-sourced card →
confirm full address, check-in info, itemised tax/fee, and cancellation
timeline all render from live test data, and that a mock-inventory card shows
no Details button. Contract tests for `stay_detail` live in apps/api
(`TestDuffelStaysSearchStays_TestHotelStayDetail`).
