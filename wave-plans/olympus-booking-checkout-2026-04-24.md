# Olympus Wave Plan — Booking/Checkout Demo Blockers — 2026-04-24

Owner: Arlen Rios. Repo: `github.com/Arlencho/olympus-platform` (default branch `main`).
Demo deadline: London, 2026-05-15. Source: QA session 2026-04-23/24 (browser testing of trip booking flow).

## 1. Plan summary

QA driver walked the full "plan a trip to Tokyo" flow end-to-end. Two P0 demo-blockers + three P1/P2 follow-ups surfaced. Root cause of both P0s is the same: `POST /api/v1/bookings` for `flow=trip` does not create a Stripe PaymentIntent, so there is no `client_secret` for the frontend to mount `PaymentElement` against, and the downstream `confirm-trip` panics on the nil `payment_id`.

- **Wave 1** — dispatch all 5 fix agents in parallel. Backend is the critical path; frontend work for #681 proceeds against an agreed response-shape contract. A `devops` log-pull agent pulls Cloud Run stacktrace for #682 to confirm/refute the nil-`payment_id` hypothesis in parallel — result informs #682 scope.
- **Wave 2** — merge in this order: #683 + #684 + #685 (independent, any order); then #681-backend; then #681-frontend; then close #682 either automatically (if healed by #681) or with a follow-up commit.
- **Wave 3** — production verify. QA re-walks the flow; card `4242 4242 4242 4242 / 12/34 / 123 / 10001` reaches Stripe and booking confirms.

Constraint: production deploy happens after Wave 2 merges. Agents do NOT run prod migrations, do NOT flip feature flags in prod. Infra pushes on user's trigger.

## 2. Issues

| # | Title | Priority | Agent(s) | Branch |
|---|-------|----------|----------|--------|
| [#681](https://github.com/Arlencho/olympus-platform/issues/681) | Trip checkout: no PaymentElement — POST /bookings returns no client_secret | P0 | `go-backend` + `web-frontend` | `fix/trip-payment-intent` (BE), `fix/trip-payment-element` (FE) |
| [#682](https://github.com/Arlencho/olympus-platform/issues/682) | POST /bookings/:id/confirm-trip 500 on valid payload | P0 | `devops` (log) → `go-backend` | `fix/confirm-trip-500` (likely absorbed by #681) |
| [#683](https://github.com/Arlencho/olympus-platform/issues/683) | POST /sessions/draft rejects funnel_history | P1 | `go-backend` | `fix/draft-funnel-history-allowlist` |
| [#684](https://github.com/Arlencho/olympus-platform/issues/684) | POST /sessions/draft returns 'no session' for authenticated browser | P1 | `go-backend` | `fix/draft-session-middleware` |
| [#685](https://github.com/Arlencho/olympus-platform/issues/685) | Flexible-week picker shows 'no flights in window' for all server errors | P2 | `web-frontend` | `fix/flexible-week-error-copy` |

**Not filed** — already tracked:
- `/trip` navigation after passenger-count → **#668** (retire `/flights`/`/hotels`/`/trip`/`/activities` landing pages, Option B). Commented on #668 noting current behavior is already Option-B-compatible.
- Fake card form cleanup → **#423** (blocked on #681 landing). Commented on #423 with cross-link.

## 3. API contract for #681 (agreed shape — backend + frontend agents must match)

```json
// POST /api/v1/bookings  → 201 Created
{ "data": {
    "id": "uuid",
    "user_id": "uuid",
    "flow": "trip",
    "status": "pending",
    "selected_result": { ... },
    "total_price": 2640.5,
    "currency": "EUR",
    "payment_id": "pi_xxx",              // NEW: non-null on success
    "payment": {                         // NEW
      "client_secret": "pi_xxx_secret_xxx",
      "publishable_key": "pk_test_xxx"
    },
    "created_at": "...",
    "updated_at": "..."
} }
```

- `payment_id` is set to the Stripe PaymentIntent id.
- `payment.client_secret` is the one-time-use secret for `stripe.confirmCardPayment`.
- `payment.publishable_key` is the env's Stripe publishable key (pk_test_* in non-prod, pk_live_* in prod). Frontend uses this for `loadStripe()` — avoids requiring a separate env var rollout.
- Idempotency: if PaymentIntent creation fails (Stripe down, invalid key), return 503; do **not** create the booking record (or mark it `payment_pending` and surface the error).

## 4. Wave 1 — dispatch (all agents in parallel)

Each agent works in its own git worktree under `.claude/worktrees/` in the olympus-platform repo, branched from `origin/main`. No two agents touch the same files.

### 4.1 `devops` — Cloud Run log pull for #682 (read-only, concurrent)

See dispatch brief in [#682 body](https://github.com/Arlencho/olympus-platform/issues/682). Output: comment on #682 with the stack trace matching request-id `ba3f169e-f44d-476a-9cff-8fc227a19f4f`.

### 4.2 `go-backend` — #681 backend (PaymentIntent creation)

See dispatch brief in [#681 body](https://github.com/Arlencho/olympus-platform/issues/681). Scope: BE only. FE tracked separately in 4.3. Agent must match the contract in section 3.

### 4.3 `web-frontend` — #681 frontend (PaymentElement mount)

Separate branch `fix/trip-payment-element`. Agent contracts against section 3. Works in parallel with 4.2 — if BE PR is not yet merged when FE PR lands, FE holds in review until BE merges.

### 4.4 `go-backend` — #683 (funnel_history allowlist)

Fully independent. Small PR, should land first.

### 4.5 `go-backend` — #684 (draft session middleware)

Independent of others. Small/medium PR.

### 4.6 `web-frontend` — #685 (error copy)

Trivial one-line fix. Lowest priority but cheap to ship.

## 5. Wave 2 — merge order

1. #683 (draft allowlist — additive, safest) → merge to `main` → deploy.
2. #684 (draft session middleware — touches middleware chain, run full test suite) → merge to `main` → deploy.
3. #685 (error copy — UI only) → merge to `main`.
4. #681-backend (PaymentIntent + response shape) → merge to `main`.
5. #681-frontend (PaymentElement mount against new contract) → merge to `main`.
6. #682 — verify resolved after #681 lands. If `confirm-trip` now 200s with a valid payment_method, close with reference to #681. If still 500s, follow-up commit.

## 6. Wave 3 — production verify

QA path (owner: Arlen):

- Signed-in as real user. Home → "plan a trip to Tokyo" → London → Thu May 21 → Thu May 28 → 1 passenger.
- Top Options renders. Click **Book This Trip**.
- Inline checkout mounts `PaymentElement`. Card `4242 4242 4242 4242 / 12/34 / 123 / 10001`.
- **Confirm booking** succeeds — booking status flips to `confirmed`, Duffel order/Stays reservation reference present.
- Flexible path: Home → Flexible → Next 12 months → cheapest-weeks panel → click **Book this week** on any row → flight-selection panel renders, no "search service unavailable". (Tests #683 fix.)
- Console clean — no `[draft-context] PUT ... failed` warnings. (Tests #684 fix.)
- Flexible-week panel error state — force a failure (e.g., block `/api/v1/search`) and confirm copy now reads "Something went wrong" not "no flights in window". (Tests #685 fix.)

## 7. Merge rules (repeated for agent clarity)

- Branch from `origin/main`, not `rebase-680` or any other long-lived branch.
- `api.yaml` changes land first (contract) — applies to #681 backend.
- Migrations land before code that uses them — none expected this wave.
- Tests merge as part of the same PR as the code they cover — don't split.
- No `--no-verify`, no force-push to `main`, no skipping CI.
- Label discipline: on PR open, flip issue from `status:in-progress` → `status:in-review`. On merge, `status:qa` until prod verify, then close.

## 8. Risks and watch-outs

- **Stripe keys in staging.** Agent 4.2 needs `STRIPE_SECRET_KEY` + `STRIPE_PUBLISHABLE_KEY` in the test env. If missing, fail tests with a clear message; do not skip silently.
- **Concurrent BE / FE PRs.** If the FE PR merges before BE, the checkout is broken in `main` until BE lands. Merge BE first; FE PR must rebase-test against `main` post-BE-merge.
- **Idempotency on PaymentIntent.** If user retries `POST /api/v1/bookings` for the same offer+user+currency+amount, don't create duplicate PaymentIntents. Use the booking.id as the idempotency key to Stripe.
- **#682 might reveal a different root cause.** If the Cloud Run logs show anything other than nil `payment_id` — e.g., a Duffel Stays 403 or a missing Duffel order ref — the fix scope changes. Agent 4.1 posts its findings on #682 within minutes; replan if surprising.
- **`rebase-680` branch has uncommitted mess.** Ignore. Agents work in fresh worktrees.

## 9. Progress log — 2026-04-24

### Wave 1 — dispatch complete
| Issue | PR | Agent | Status |
|---|---|---|---|
| #683 (funnel_history allowlist) | [#686](https://github.com/Arlencho/olympus-platform/pull/686) | go-backend (sonnet) | **merged + deployed** |
| #684 (draft middleware) | [#688](https://github.com/Arlencho/olympus-platform/pull/688) | go-backend (opus) | CI re-running after rebase |
| #685 (flex-week copy) | [#687](https://github.com/Arlencho/olympus-platform/pull/687) | web-frontend (sonnet) | **merged + deployed** |
| #681-BE (Stripe PI) | [#689](https://github.com/Arlencho/olympus-platform/pull/689) | go-backend (opus) | **merged** — API deploy in progress |
| #681-FE (PaymentElement) | [#690](https://github.com/Arlencho/olympus-platform/pull/690) | web-frontend (opus) | **merged + deployed** |
| #682 (devops log) | — | devops (sonnet) | Code-trace complete — **refuted nil-payment-id hypothesis**, real root cause is Duffel 4xx from `payment_type: balance` call |

### Scope expansion from #682 investigation

Devops code-trace on #682 revealed #689's PaymentIntent fix is necessary but not sufficient. The `ConfirmTrip` path does not read `payment_id` at all — the 500 was actually a Duffel `/air/orders` 4xx wrapped as `*StatusError` and unmapped to sentinels. #689 fixed the error classification (so 4xx now surfaces as 402/422/409/503 instead of generic 500). But the underlying `payment_type: balance` call with empty `three_d_secure_session_id` still fails on production Duffel test-mode.

**New issue filed:** [#691](https://github.com/Arlencho/olympus-platform/issues/691) — wire Stripe PaymentIntent → Duffel 3DS session handoff in `ConfirmTrip`. **P0 demo-blocker.** Go-backend agent dispatched (opus tier, background).

### Security review findings (addressed in follow-up commits on same PRs)

- **#688** (auth middleware): HIGH — silent revocation-store error degraded to anonymous. Fixed: `slog.Error` with `alert: revocation_store_unavailable` tag; construction warning mirrors `Auth`.
- **#689** (Stripe PI): **HIGH — money-handling bug**. Client-supplied `total_price` fed straight into Stripe. User could pay $1 for a $2700 trip. **Fixed**: server derives total via `OfferPriceFetcher` + hotel rate, rejects mismatch with 409. Plus MEDIUM fixes: fail-closed in production via `StrictPaymentMode`, PII-adjacent slog cleanup, Duffel 401/403/429 → 503 with alert tags.
- **#690** (frontend PI): no blockers. 2 LOW: pk cache doesn't survive rotation (docs note); unvalidated `?flow` param (allowlist fix tracked as a separate lightweight issue — not demo-blocking).

### Production state

- **Web (Vercel)**: all frontend changes (#685, #690, and #689's generated types) live.
- **API (Cloud Run)**: #686 deployed (funnel_history allowlist). #689 deploy in progress (Stripe PaymentIntent + Duffel error classification + StrictPaymentMode config). Migration step is no-op (no schema changes this wave). #688 awaiting CI + merge.

### Deferred / follow-up

- **#682 → #691** — Duffel card-payment handoff, P0. In flight.
- **#423** — fake card form cleanup. Blocked on #691 verified end-to-end.
- **Follow-up (file separately if hit)**: PaymentIntent cancellation on Duffel 4xx — #689 created the test hook but the cancel-on-fail is stubbed. Real cancellation lives with #691's Duffel-orchestration work.
- **Follow-up**: Redis-backed per-user rate limit on draft-context — current middleware chain doesn't see `user_id` until after `RateLimit`, so per-user cap is effectively an IP cap. Pre-existing, flagged by security review of #688.

### Post-wave (once #691 lands)

- QA end-to-end walkthrough per §6.
- Close #423 after verifying no fake card forms remain.
- Close #682 with a receipt comment pointing at #691's final fix.
- Post-mortem learning: silent-fallback footgun (#107/#120/#147 class) caught here by security reviewer BEFORE merge — add to `docs/qa/` as a positive data point for the review process.
