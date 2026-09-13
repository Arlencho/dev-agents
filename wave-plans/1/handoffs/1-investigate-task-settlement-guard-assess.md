# Handoff — issue #2302: settlement guard assessment (READ-ONLY, no code)

## Built

Nothing in product code. One comment posted on issue #2302:
https://github.com/Arlencho/olympus-platform/issues/2302#issuecomment-5382501221

No branch content, no PR, no commits to any app path. Full text preserved at
`/tmp/settlement-assess/comment.md`.

## Decisions

- **Recommended shape 1, narrowed**: server-side refusal at the confirm-time
  choke point, keyed on the *resolved* settlement and the *per-flow* Duffel
  token mode. Change belongs at `apps/api/internal/service/standalone_payment.go:265`.
- **Not the handler.** `handler/booking.go:404-417` only sees `req.Settlement`.
  `resolveBookingSettlement` (`service/standalone_payment.go:426-436`) turns a
  SILENT client into `balance` via `STANDALONE_SETTLEMENT_DEFAULT`
  (`config/config.go:1008-1009`, default `"balance"`). A handler guard on
  "names balance" would miss the silent case entirely.
- **Not `flights_mode` as a global predicate.** `stays_mode` is `sandbox` while
  `flights_mode` is `production` (verified live). Gating hotel-only on the
  flights token would break the sandbox hotel flow for zero safety gain.
  Per-flow: flights checks `FlightsMode()`, hotels checks `StaysMode()`.
- **Confirm-time over create-time.** `authorizeStandalonePayment` is the only
  non-trip Balance spend path (callers: `service/booking.go:2302`,
  `service/stay_booking.go:306`) and it covers rows created before the guard
  ships. Refusing there asks nothing of the provider, so nothing to unwind.
- **Trip is exempt with zero code**: `ConfirmTrip` never calls that function,
  and the `Flow == "trip"` arm returns at `standalone_payment.go:261`, ahead of
  line 265. `FEATURE_TRIP_BALANCE_SETTLEMENT` stays the only trip lever.
- **503, no new copy.** Precedent `ErrTripBalanceSettlementDisabled` →
  `handler/booking.go:519-525`. Client maps any 503 to the flow's ratified line
  before reading the server sentence (`chat-flight-checkout.ts:608→:79`,
  `chat-stay-checkout.ts:454→:68`, `inline-checkout.tsx:212/218`).

## Do not repeat

- **Do not "fix" this by deleting the client `settlement: "balance"` literals.**
  It is a no-op: silence resolves to balance server-side. Posting `"card"`
  instead mints a PaymentIntent nothing can confirm (the card creators
  `createFlightCardBooking` / stay twin have NO non-test call sites) and
  strands a hold. That is the #2291 / #2297 defect.
- **Do not reach for `NEXT_PUBLIC_FEATURE_CHAT_CARD_PAYMENT`.** It is trip-only
  (`lib/chat-card-payment-flag.ts:22-30`); consumers are `chat-v2.tsx:545/568/1186`
  and `draft-progress-agents.ts:439` (gated `intent === "trip"`). Flipping it
  changes nothing for flight-only or hotel-only.
- **Do not put the guard in the handler.** See above.

## Evidence

```
$ curl -s .../api/v1/health | jq '.data.components.providers'
{"flights":"duffel","hotels":"duffel","ai":"live","mock_active":false,
 "stays_mode":"sandbox","flights_mode":"production"}
$ git log --oneline -1   # 3ad20922
```

Key line citations (all on `3ad20922`): `provider/duffel.go:222`,
`provider/duffel_stays.go:325`, `cmd/server/main.go:747` / `:854` / `:1047`,
`service/booking.go:1289` / `:1445-1461` / `:2302`,
`service/standalone_payment.go:87-97` / `:248-262` / `:264-285` / `:418-440`,
`service/stay_booking.go:306`, `handler/booking.go:404-417` / `:519-525` /
`:1195-1202` / `:1230-1244`, `handler/duffel_refusal.go:29`,
`web/lib/chat-flight-checkout.ts:432`, `web/lib/chat-stay-checkout.ts:292`,
`web/components/inline-checkout.tsx:649-659` / `:720` / `:754`.

## Open questions

1. **Product call, not an engineering one:** Balance is the ONLY shipped route
   for flight-only today, so this guard CLOSES production flight-only booking
   (loudly) until the #2302 card surface lands. Needs a deliberate decision.
2. `docs/operations/env-vars-api.md:124` claims #2302 "shipped 2026-08-14" made
   the chat client name `settlement` in both flag positions. True for the TRIP
   cart only; flights/hotels never read the flag. Doc correction, out of scope
   here under scope freeze — worth its own issue.

## Next hint

Implementation PR: one `bool` on `standalonePaymentGuard`
(`standalone_payment.go:87-97`, mirrors the existing `strict bool` set at
`booking.go:694`), set from the provider in `main.go` at `:747` and `:854`; one
sentinel added to `isCardSettlementError` (`handler/booking.go:1195`); the
refusal itself at `standalone_payment.go:265`. Carrying
`errCodeProviderUnavailablePersistent` means updating the enumerated nine-arm
comment in `handler/duffel_refusal.go` in the same PR.
