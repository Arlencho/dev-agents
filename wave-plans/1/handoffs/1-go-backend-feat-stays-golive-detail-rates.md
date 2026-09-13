# Handoff — #2061 stay detail + rates (backend mapping)

Branch `feat/stays-golive-detail-rates` · draft PR **#2067** · commit `a32930f9`

## Built

`apps/api/` only (model + provider + tests). Maps real Duffel Stays fields
into the `Stay*` contract PR #2067 already added to `api.yaml`.

- `internal/model/result.go`: added `StayAddress`, `StayLocation`,
  `StayCheckInInformation`, `StayKeyCollection`, `StayAmenity`, `StayBed`,
  `StayRateCondition`, `StayPriceBreakdown`, `StayRate`, `StayRoom`,
  `StayDetail` — mirror api.yaml exactly (pointer fields for every nullable
  property, plain arrays for required-but-possibly-empty lists).
  `HotelResult` gained `CancellationTimeline` + `StayDetail`.
  `StayCancellationTimelineEntry` gained `RefundAmount`/`Currency` pointers.
  `StayBookingConfirmation` gained `ConfirmedAt`/`Nights`/`Rooms`/
  `GuestCount`/`Price`/`Location`/`CheckInInformation`/`KeyCollection`
  (all additive+optional; `Price`/`Location`/`CheckInInformation`/
  `KeyCollection` deliberately stay nil today — see Decisions #3).
- `internal/provider/duffel_stays.go`: extended the Duffel wire structs
  (`duffelStaysAccommodation`, `duffelStaysRoom`, `duffelStaysRate`,
  `duffelStaysSearchResult`, `duffelStaysBooking`) with the fields Duffel
  actually returns, and added the mapping layer
  (`buildStayDetail`/`buildStayLocation`/`buildStayRooms`/`buildStayRates`/
  `buildPriceBreakdown`/`mapCancellationTimeline`/`derivePenalty`/
  `nonEmptyPtr`/etc.) that turns them into the model.Stay* structs.
  `SearchStays` now attaches `StayDetail` (+ `CancellationTimeline` on the
  bookable-rate path) to every Duffel-sourced `HotelResult` where
  `fetch_all_rates` succeeded, even when no bookable rate came back
  (property displayable, not bookable — matches api.yaml doc).
- Fixed the cancellation-timeline penalty bug the #2067 handoff flagged:
  `duffelStaysCancellationTimeline` now decodes `refund_amount`+`currency`
  (Duffel's real fields) instead of a `penalty` key Duffel never sends.
  `Penalty` on the wire-facing model is now DERIVED
  (`"<refund_amount> <currency>"`) per api.yaml's literal formula.
- Fixed a semantic bug this surfaced: the old "free cancellation" summary
  heuristic checked for a `"0.00"`-prefixed penalty, which is backwards
  under `refund_amount` semantics (`refund_amount: "0.00"` means **no**
  refund, not a free one). `summariseCancellationTimeline` now compares
  the earliest timeline entry's `refund_amount` against the booking total
  for an exact match.

## Decisions

1. **`StayDetail` built only when `fetch_all_rates` succeeded.** The
   fetch-failed fallback path (search-level cheapest price only) does not
   get a `StayDetail` — we genuinely don't have the accommodation payload
   there. No fabrication.
2. **`StayDetail.CheckInDate`/`CheckOutDate`/`Rooms`/`Guests` are echoed
   from our own request**, not re-parsed from Duffel's search-result
   `rooms`/`guests` echo (I do capture those fields on the wire struct too,
   for `ExpiresAt`, but didn't need them for the others — what we sent is
   what Duffel searched, by construction).
3. **`StayBookingConfirmation.Price`/`Location`/`CheckInInformation`/
   `KeyCollection` stay nil.** `duffelStaysBookingAccommodation` deliberately
   retains only `name`+`address` per the pre-existing #547/#561 retention
   limit on Duffel descriptive content at booking-response time. Populating
   the new optional fields would require widening that retained surface —
   flagging as a follow-up rather than doing it silently in this PR.
   `ConfirmedAt`/`Nights`/`Rooms`(count)/`GuestCount` ARE populated — none
   of those are the restricted descriptive content.
4. **Fixed a duplicate-field compile error mid-edit**: the pre-existing Go
   `StayBookingConfirmation.Reference` field already carried Duffel's
   `reference` (its doc comment claiming "legacy alias for
   ConfirmationCode" was stale/wrong — the code was already right). Did not
   add a second field; corrected the comment instead.

## Do not repeat

- Don't assume `duffelStaysAccommodation.Address` (flat string, pre-existing)
  and the new `Location.Address` (structured) are redundant — the flat one
  feeds `HotelResult.Address` (required non-nullable string on the existing
  contract) and predates this task; left untouched.
- No real Duffel Stays fixture JSON exists in-repo (confirmed again this
  session). All new wire-struct field names trace to api.yaml's own field
  descriptions (`accommodation.location.address`, `check_in_information`,
  `key_collection`, `chain.name`, `brand.name`, `rate.conditions`,
  `rate.payment_type`, `cancellation_timeline[].refund_amount`/`.currency`)
  since those were the best available ground truth per the #2067 handoff.
  If/when a real sandbox capture becomes available, diff it against these
  struct tags before trusting them blind.

## Evidence

```
cd apps/api && go build ./... && go vet ./...          → clean
cd apps/api && go test ./...                            → all packages ok
golangci-lint run ./apps/api/internal/model/... ./apps/api/internal/provider/...  → 0 issues
gofmt -l internal/model/result.go internal/model/result_test.go \
  internal/provider/duffel_stays.go internal/provider/duffel_stays_test.go → clean
python3 scripts/check-openapi-routes.py                 → OK: 80 Go routes ↔ 83 OpenAPI paths (unaffected, api.yaml untouched)
git push origin feat/stays-golive-detail-rates           → a32930f9
```

New/updated tests: `TestDuffelStaysSearchStays_TestHotelStayDetail` (full
#2056 Duffel Test Hotel fixture — structured address, check-in info, key
collection, chain/brand, "Successful Booking by Balance" room/rate,
itemised tax/fee/due-at-accommodation, conditions, quantity_available,
cancellation timeline), `TestStayDetail_HonestNulls` +
`TestStayCancellationTimelineEntry_DerivedPenalty` (model package),
plus fixed the 4 pre-existing tests that constructed the old `Penalty`
field literal.

## Open questions / blocking

Unchanged from the #2067 handoff: **no PRD page exists for a stay detail
screen** (`docs/prd/pages/stays.md` is the `/stays` discovery page, not a
property detail view). web-frontend is blocked on the UI half of #2061
until that spec is written and signed off. This PR only makes the data
available on the wire (`HotelResult.stay_detail`); no new endpoint, no UI.

## Next hint

web-frontend (once the PRD page lands): `HotelResult.stay_detail` is
populated on every Duffel-sourced hotel search result today (via the
existing `/search` / trip flows) — no new API call needed to fetch it.
