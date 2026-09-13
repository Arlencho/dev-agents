# Handoff — #2061 stay detail + rates (test-engineer pass)

Branch `feat/stays-golive-detail-rates` · draft PR **#2067** · commit `668c21ff`
on top of `5d3d7ab5` (web UI), `a32930f9` / `d99d9321` / `fdc0a85b` (API) —
all verified present via `git log --oneline`.

**Test-only. No production code touched.** Scope check clean
(`scripts/hooks/scope-check.sh` test-engineer allowlist = `apps/api/ apps/web/
apps/mobile/ docs/qa/`).

## Built

| File | Δ | Focus |
|---|---|---|
| `apps/api/internal/provider/duffel_stays_detail_test.go` | **new**, 21 tests / 39 sub-cases | Mapping honesty + provider-level StayDetail presence |
| `apps/web/components/hotel-card.test.tsx` | +5 | "Details & rates" affordance on the results card |
| `apps/web/components/stay-detail-modal.test.tsx` | +24 | Per-field presence sweep, both directions |
| `apps/web/components/widgets/stay-widget.test.tsx` | +3 | Chat stay-card affordance + behaviour split |
| `docs/qa/2061-stay-detail-rates-test-report.md` | **new** | QA report + the PRD gap flag |

Highlights:

- `summariseCancellationTimeline` had **zero direct coverage**. It is the
  highest-stakes honesty function on this path: under Duffel's `refund_amount`
  semantics a `"0.00"` first entry means *no refund*, and the pre-#2061 shape
  (a `penalty` field Duffel never sends) made that read as free cancellation —
  exactly backwards. Now pinned across full / partial / zero / missing refund
  and unknown-total cases.
- Provider-level StayDetail presence matrix is now complete: rate found →
  populated; rates fetched but sold out → populated with `room_types: []` and
  `expires_at` falling back to the `/stays/search` value; `fetch_all_rates`
  failed → **nil** (nothing honest to put in it, and no synthesised
  `cancellation_timeline`); mock inventory → omitted from the wire.
- UI presence is asserted in *both* directions for every optional field, so a
  future regression that swaps a null for a fabricated `0` / `"0.00"` / `""`
  fails a test rather than shipping.

## Decisions

- **New Go file rather than extending `duffel_stays_test.go`.** That file is
  1839 lines and already carries branch edits; a separate
  `duffel_stays_detail_test.go` keeps the #2061 surface reviewable and avoids
  rebase conflicts. Same package, so it reuses `intPtr` and the unexported
  helpers directly.
- **Asserted on shipped copy verbatim** (`Full address not provided by the
  property.`, `Details & rates`, …) even though it is not in the PRD — see the
  open item below. Locking the strings makes the eventual PRD ratification a
  visible two-file change instead of silent drift.
- **`check_in_information` / `key_collection` fixtures use `undefined`, not
  `null`.** The Go structs carry `omitempty` on those pointers, so they are
  *omitted* from the wire, and the generated TS type is `T | undefined` (not
  nullable). `null` fails `tsc`. Nullable-and-required components
  (`tax_amount`, `city_name`, …) do use `null` — that distinction is itself
  asserted in `TestStayPriceBreakdown_NullsAreExplicitOnTheWire`.
- Did **not** file a bug report: no production defect surfaced. Everything the
  mapping layer does on the paths exercised is honest.

## Do not repeat

- `gofmt -l internal/provider/ internal/model/` reports four **pre-existing**
  unformatted files (`airport_country_table.go`, `duffel.go`, `maps/maps.go`,
  `model/user.go`). Not from this pass — do not "fix" them here, that is
  production scope.
- The chat `StayWidget` Details button reuses the `.ra-compare-toggle` class.
  Do not select compare toggles by class index in new tests when a fixture has
  `stayDetail` — use `[data-qa-element="compare-<id>"]`. There is now a
  regression test for the behaviour split.
- `stay-detail-modal.test.tsx` and `hotel-card.test.tsx` each stub
  `ResizeObserver` (Radix Dialog touches it under jsdom). `stay-widget.test.tsx`
  passes without one — do not add a redundant stub there.

## Evidence

```
$ cd apps/api && go test ./internal/...
(all packages ok; no failures)

$ cd apps/api && go vet ./internal/provider/ ./internal/model/
(clean)

$ cd apps/api && golangci-lint run ./internal/provider/...
0 issues.

$ cd apps/web && npx vitest run
Test Files  223 passed (223)
     Tests  2799 passed (2799)

$ cd apps/web && npx tsc --noEmit
(clean)

$ cd apps/web && npx eslint components/hotel-card.test.tsx \
    components/stay-detail-modal.test.tsx components/widgets/stay-widget.test.tsx
(clean)

$ cd apps/web && npx vitest run components/hotel-card.test.tsx \
    components/stay-detail-modal.test.tsx components/widgets/stay-widget.test.tsx
Test Files  3 passed (3)
     Tests  72 passed (72)     # was 40 before this pass
```

## Open questions

**Blocking per CLAUDE.md PRD rule 4:** `StayDetailModal` is a new user-facing
surface whose copy is **not in `docs/prd/`**. Grep confirms these strings appear
nowhere under `docs/prd/`:

`Details & rates` · `Rooms & rates` · `Due at the property` ·
`Full address not provided by the property.` ·
`Check-in information not provided by the property.` ·
`Rates are not available for this property right now — try searching again.` ·
`No bookable rates returned for this room.` ·
`Cancellation terms vary by provider — check the full policy before booking.`
(last one exists in `pages/07-checkout.md`, but not for this surface)

`docs/prd/pages/stays.md` covers the editorial `/stays` discovery page only —
no accommodation-detail section. `pages/atlas-chat.md` describes the stay card
without a details affordance.

`docs/prd/` is outside test-engineer scope. **Handing this to the
web-frontend / devops owner of PR #2067**: suggested home is a new
"Accommodation detail + rates" section on `pages/atlas-chat.md`, with the
empty-state copy registered in `01-conventions.md` § 3.3. Detail in
`docs/qa/2061-stay-detail-rates-test-report.md` § 4.

## Next hint

If the ratified PRD copy differs from what shipped, the assertions to update
live in `stay-detail-modal.test.tsx` (empty-state strings),
`hotel-card.test.tsx` + `stay-widget.test.tsx` (the `Details & rates` label).
Nothing in the Go tests depends on UI copy.
