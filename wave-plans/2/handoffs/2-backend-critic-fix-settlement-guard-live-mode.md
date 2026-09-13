# Handoff — PR #2730 follow-up: misrouted-trip arm still leaked in live mode

## Built

Two fixes on top of the already-merged-to-branch `c1df4a66` (the #2302
live-mode guard), both in
`apps/api/internal/service/standalone_payment.go` /
`standalone_payment_test.go`:

1. **Closed the leak.** `authorizeStandalonePayment`'s `Flow == "trip"`
   branch had TWO ways out for a PaymentIntent-less row: the intended
   one (misrouted trip row, log alert
   `trip_booking_misrouted_to_standalone_confirm`) returned `(nil, nil)`
   unconditionally, never reading `guard.liveMode` — so a live-mode
   standalone confirm (`POST /bookings/{id}/confirm-duffel` on a row
   whose `Flow` is `"trip"` but that never went through
   `ConfirmDuffelFlightLeg`) booked a real Duffel order from the shared
   Balance with nobody charged. Added the identical `guard.liveMode`
   check the sibling flight/hotel arm already has, returning the same
   `ErrStandaloneLiveBalanceSettlementRefused` sentinel. Handler layer
   needed NO changes — `isCardSettlementError` /
   `writeCardSettlementError` already match on that sentinel by value,
   not by call site, so the existing 503 +
   `provider_unavailable_persistent` mapping now covers this arm for
   free.
2. **Fixed the test that locked the leak open.**
   `TestStandalonePayment_TripBalanceRow_UnaffectedByLiveModeGuard`
   called `ConfirmDuffelWithPayment` (the STANDALONE confirm) with a
   `Flow=="trip"` fixture and asserted `require.NoError` +
   `require.NotNil` on the Duffel order id under live mode — i.e. it
   pinned the defect as an invariant. Renamed to
   `TestConfirmDuffelFlightLeg_TripBalanceRow_UnaffectedByLiveModeGuard`
   and re-pointed it at `ConfirmDuffelFlightLeg` (`tripLeg=true`), the
   entry point `ConfirmTrip` actually uses — that's the claim worth
   protecting: a genuine trip leg skips `authorizeStandalonePayment`
   entirely via `assertNoBypassedCardSettlement`, in both modes.
   Added `TestStandalonePayment_LiveMode_MisroutedTripBalanceRowIsRefused`
   as the direct leak-reproduction test (`live_token_refuses` /
   `sandbox_token_still_books` subtests).

Verified before touching anything, per the task: `ConfirmTrip` →
`ConfirmDuffelFlightLeg` (`booking.go`) / `ConfirmDuffelStayWithAcceptance`
(`stay_booking.go`) are the ONLY two call sites outside the standalone
confirms, and both pass `tripLeg=true` / `settleStandalone=false`,
which skip `authorizeStandalonePayment` entirely (they run
`assertNoBypassedCardSettlement` instead, which never reads
`guard.liveMode`). So a genuine trip cart cannot reach the arm this fix
changes — confirmed by grepping every call site of
`authorizeStandalonePayment` before editing (`booking.go:2320`,
`stay_booking.go:325` — both `tripLeg=false`/`settleStandalone=true`
standalone entry points).

## Decisions

- Reused the existing `ErrStandaloneLiveBalanceSettlementRefused`
  sentinel rather than minting a new one: the handler-side mapping,
  status code, and copy are identical to the sibling arm, and the task
  explicitly required no new status codes outside the refusal.
- Did not touch `duffel_refusal.go`'s "ten arms" comment — it's keyed
  by sentinel, not by internal branch, and this fix adds a second
  `return` site for an *existing* sentinel rather than a new arm.

## Do not repeat

- Don't assume the `Flow == "trip"` branch in `authorizeStandalonePayment`
  is single-exit. It has two `return` statements for the PI-less case
  (the card-settled sibling above it only has one) — always check both
  when auditing this function again.
- Don't re-point the trip-invariant test at `ConfirmTrip` /
  `ConfirmTripWithAcceptance` directly — those need a fully wired
  `TripBookingService` (flight + stay bookers, settler, store) for no
  extra signal; `ConfirmDuffelFlightLeg` on a bare `BookingService` is
  the minimal call that actually exercises the code path this guard
  could reach.

## Evidence

Leak reproduction, parent commit `c1df4a66` (throwaway worktree,
test-file diff applied WITHOUT the implementation fix), exit code
captured directly:

```
$ go test ./internal/service/... -run 'TestStandalonePayment_LiveMode_MisroutedTripBalanceRowIsRefused' -v
--- FAIL: TestStandalonePayment_LiveMode_MisroutedTripBalanceRowIsRefused (0.00s)
    --- FAIL: .../live_token_refuses (0.00s)
        Error: An error is expected but got nil.
    --- PASS: .../sandbox_token_still_books (0.00s)
FAIL
$ echo $?
1
```

Post-fix, same test, same repo:

```
$ go test ./internal/service/... -run 'TestStandalonePayment_LiveMode_MisroutedTripBalanceRowIsRefused' -v
--- PASS: TestStandalonePayment_LiveMode_MisroutedTripBalanceRowIsRefused (0.00s)
    --- PASS: .../live_token_refuses (0.00s)
    --- PASS: .../sandbox_token_still_books (0.00s)
PASS
$ echo $?
0
```

Full verification, all exit codes captured directly (no pipe before
`echo $?` / printed inline):

```
go build ./...                          → BUILD_EXIT:0
go vet ./...                            → VET_EXIT:0
go test ./... -race                     → TEST_RACE_EXIT:0
golangci-lint run ./apps/api/...        → LINT_EXIT:0 (0 issues)
make check-api-spec                     → CHECK_API_SPEC_EXIT:0
```

Existing guarantees re-run and green:
`TestStandalonePayment_LiveMode_FlightOnlyBalanceIsRefused`,
`TestStandalonePayment_LiveMode_HotelOnlyBalanceIsRefused`,
`TestStandalonePayment_SandboxMode_FlightOnlyBalanceStillSucceeds`,
`TestStandalonePayment_SandboxMode_HotelOnlyBalanceStillSucceeds`,
`TestConfirmDuffelFlightLeg_TripBalanceRow_UnaffectedByLiveModeGuard`
(both subtests).

`git diff --stat`: only
`apps/api/internal/service/standalone_payment.go` and
`standalone_payment_test.go` touched — no handler diff, confirming
`isRecoverableUserError`, every non-refusal status code, and the
Stripe void/capture decision are byte-for-byte unchanged.

## Next hint

Pushed to the existing branch `fix/settlement-guard-live-mode`,
updating PR #2730 in place. Not merged, no new PR opened.
