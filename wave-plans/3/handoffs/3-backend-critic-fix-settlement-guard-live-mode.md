# Handoff — issue #2302 settlement guard, implemented (fix/settlement-guard-live-mode)

## Built

Implemented the confirm-time guard recommended by the SETTLEMENT GUARD
ASSESSMENT comment on #2302 (posted by Arlencho), at exactly the call
site it named: `apps/api/internal/service/standalone_payment.go`,
inside `authorizeStandalonePayment`'s `paymentIntentID == ""` (Balance)
arm, ahead of the existing `slog.Warn` + `return nil, nil`.

- `standalonePaymentGuard.liveMode bool` — new field, zero value `false`
  (sandbox posture, unchanged behaviour).
- `ErrStandaloneLiveBalanceSettlementRefused` — new sentinel, returned
  instead of `(nil, nil)` when `guard.liveMode` is true and the booking
  resolved to Balance. Nothing is asked of the provider before this
  point, so refusing costs nothing to unwind.
- `BookingService.WithLiveMode(bool)` / `StayBookingService.WithLiveMode(bool)`
  — new setters, wired in `cmd/server/main.go` from
  `duffelProvider.FlightsMode() == "production"` (flights service) and
  `duffelStaysProvider.StaysMode() == "production"` (stays service) —
  per-flow, per the assessment's Hole B: the two Duffel tokens are
  separate secrets and can be in different modes.
- Handler: `isCardSettlementError` now also matches the new sentinel;
  `writeCardSettlementError` gained a new case returning 503 with the
  SAME copy the two neighbouring arms already use
  (`"payment provider is temporarily unavailable — give it a moment
  and retry"`), but — unlike those two — carrying
  `error_code: "provider_unavailable_persistent"`, per the assessment's
  status-code recommendation (precedent:
  `ErrTripBalanceSettlementDisabled` → 503, `handler/booking.go:519-525`).
- `duffel_refusal.go`'s "nine arms" comment updated to ten, naming the
  new arm explicitly and explaining why it's not the same edit as the
  four uncoded settlement sentinels the comment already tracks as a
  deliberate follow-up.

No PRD change, no new copy: the traveller never sees the server
sentence above. Both flows already have ratified 503 lines
(`Flight booking is temporarily unavailable — give it a few minutes,
then retry.` / the hotel twin) in `docs/prd/pages/atlas-chat.md` § 10
and `07-checkout.md`, verified by reading those sections before
concluding no PRD update was needed.

Trip flow untouched: `ConfirmTrip` never calls
`authorizeStandalonePayment`, and the `booking.Flow == "trip"` branch
inside it returns before the Balance arm the guard lives in. No trip
code touched, `FEATURE_TRIP_BALANCE_SETTLEMENT` remains the only trip
lever. `isRecoverableUserError` and the Stripe void/capture decision
are untouched.

## Decisions

- Agreed with and implemented the assessment's Shape 1 (narrowed)
  exactly: confirm-time, per-flow token predicate, no client/flag
  involvement. Did not implement anything else — no disagreement to
  record.
- Reused the exact server sentence + status the two existing 503 arms
  in `writeCardSettlementError` already emit, per the assessment's "zero
  new copy" finding — verified against `docs/prd/pages/atlas-chat.md`
  and `07-checkout.md` before trusting the claim.

## Do not repeat

- Don't gate hotel-only on `FlightsMode()` — the two Duffel tokens are
  separate secrets (verified live: flights production, stays sandbox
  at time of writing) and can diverge.
- Don't put this guard in the handler — it only sees `req.Settlement`,
  not the *resolved* settlement, and a silent client resolves to
  Balance via `STANDALONE_SETTLEMENT_DEFAULT`.
- Don't recode `ErrCardSettlementBypassed` / `ErrTripPaymentNotConfigured`
  / `ErrTripBalanceSettlementDisabled` to carry
  `errCodeProviderUnavailablePersistent` as part of this change — that's
  a different, already-tracked follow-up (#2723) and is pinned by
  `TestBookingHandler_SettlementUnavailable503s_StayUncoded_PendingFollowUp`,
  which this PR does not touch.

## Evidence

Parent-commit proof (throwaway worktree at `3ad20922`, test file diff
applied WITHOUT the implementation):

```
$ go test ./internal/service/... -run 'TestStandalonePayment_LiveMode_FlightOnlyBalanceIsRefused' -v
...
FAIL	.../internal/service [build failed]
EXIT_FLIGHT_REFUSAL_TEST:1

$ go test ./internal/service/... -run 'TestStandalonePayment_LiveMode_HotelOnlyBalanceIsRefused' -v
...
FAIL	.../internal/service [build failed]
EXIT_HOTEL_REFUSAL_TEST:1
```

Post-fix, same repo:

```
go build ./...                          → BUILD_EXIT:0
go vet ./...                            → VET_EXIT:0
go test ./... -race                     → TEST_RACE_EXIT:0
golangci-lint run ./apps/api/...        → LINT_EXIT:0 (0 issues)
make check-api-spec                     → CHECK_API_SPEC_EXIT:0
```

New tests, both green:

- `internal/service/standalone_payment_test.go`:
  `LiveMode_FlightOnlyBalanceIsRefused`,
  `LiveMode_HotelOnlyBalanceIsRefused`,
  `SandboxMode_FlightOnlyBalanceStillSucceeds`,
  `SandboxMode_HotelOnlyBalanceStillSucceeds`,
  `TripBalanceRow_UnaffectedByLiveModeGuard` (live + sandbox subtests).
- `internal/handler/standalone_payment_test.go`:
  `ConfirmDuffel_LiveModeBalanceSettlementRefused_503`,
  `ConfirmDuffelStay_LiveModeBalanceSettlementRefused_503`,
  `ConfirmDuffel_SandboxModeBalanceSettlementStillConfirms`.

## Next hint

Branch `fix/settlement-guard-live-mode` pushed. PR opened referencing
#2302 and #2646 with `Refs`, not closing keywords, per instruction. Not
merged.
