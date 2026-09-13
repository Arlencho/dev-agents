# Handoff: docs/live-booking-docs-sweep (PR 2813, draft)

## Built

Four docs corrected where the first live production booking (2026-09-11)
made them false. 5 changed lines, 4 files, nothing else touched.

- `docs/compliance/SUBPROCESSORS.md` line 25 (Duffel row): label
  "planned, not yet active" to "active since 2026-09-11 for flights";
  "Will be activated when #301 lands" to a flights-live / Stays-pending
  #2039 sentence; "DPA required before going live" to a dated record of
  the co-founder decision of 2026-09-12. DPA status cell left at
  "Not started" as instructed.
- `docs/COST_INVENTORY.md` lines 340 and 342: Flights and Payment bullets
  rewritten to the observed money model. Hotels and streaming bullets
  untouched.
- `docs/prd/pages/atlas-chat.md` line 3442: the "CARD journey is UNBUILT"
  sentence replaced with a dated amendment. No other cell touched.
- `docs/operations/duffel-balance-funding.md` line 52: stale pre-funding
  sentence replaced with one dated sentence, no amounts.

## Decisions

- Left every pre-existing long dash in the untouched parts of the lines I
  edited (for example "UK jurisdiction ... no SCCs needed" in the Duffel
  row). The brief said change nothing else in these files, so rewriting
  neighbouring prose for style would have exceeded scope. Only text I
  authored is dash-free.
- In `atlas-chat.md` I used the italic parenthetical "Amended <date>"
  form, which that same row already uses twice, rather than the bold
  "Corrected <date> (#issue)" form also present, because the replaced
  sentence sits mid-paragraph where the italic form reads correctly.
- Cited PR 2663 in the atlas-chat amendment without a ship date. The
  brief said 2026-08-14; `gh pr view 2663` reports merged
  2026-08-13T23:56:14Z. Rather than assert either, the sentence carries
  only the amendment date the brief required (2026-09-12).
- No `Co-Authored-By` trailer and no vendor or tool name in commit or PR
  text: board directive OLY-4 plus the brief. This overrides the generic
  attribution default.
- Opened as a DRAFT PR. The brief said do not merge.

## Do not repeat

- Do NOT `git add -A` / `git commit -a` in this worktree. It carries
  unrelated pre-existing modifications (`apps/api/internal/...` assistant
  OAuth work: 9 modified files plus 4 untracked) that are not part of
  this task and were present before it started. The commit here used
  explicit paths only.
- Do not "fix" `stays_mode: sandbox` on production health. It is correct
  and deliberate, pending #2039. It is a token readout, not a config
  echo.
- `providers.flights: "duffel"` on `/health` does not tell you whether
  the live token is in use. Only `flights_mode` does.

## Evidence

```
$ curl -s .../api/v1/health   # olympus-api, europe-north1
"mock_active": false, "stays_mode": "sandbox", "flights_mode": "production"

$ make check-prd-index
OK: all 31 page spec(s) are reachable from 00-INDEX.md ... self-test OK
exit 0

$ git diff --stat HEAD~1
 docs/COST_INVENTORY.md                    | 4 ++--
 docs/compliance/SUBPROCESSORS.md          | 2 +-
 docs/operations/duffel-balance-funding.md | 2 +-
 docs/prd/pages/atlas-chat.md              | 2 +-
 4 files changed, 5 insertions(+), 5 deletions(-)
exit 0

$ git diff -U0 -- docs/ | grep '^+' | grep <long dashes>
exit 1   (no long dash in any added line)
```

Commit: e81ed3bd on `docs/live-booking-docs-sweep`.
PR: https://github.com/Arlencho/olympus-platform/pull/2813 (draft, not merged).

Source verification done before writing:
- `apps/api/internal/provider/duffel.go` `FlightsMode()`, `duffel_stays.go`
  `StaysMode()`: both test their own token for `_test_`.
- PR 2812 comment "LOG EVIDENCE 2026-09-11": booking
  282d1d31-8915-48e9-806c-c2bf8326f16d, EUR 16245 cents, flow flights,
  settlement card, order POST 201 at 11:28:34 then capture at 11:28:35.
- `apps/web/lib/chat-flight-checkout.ts` `createChatFlightCardBooking`
  and `chat-stay-checkout.ts` `createChatStayCardBooking`: both post
  `settlement: "card"` (PR 2663).

## Open questions

- The `atlas-chat.md` balance-variant row still says `flights` and
  `hotels` intent mount the balance variant in BOTH flag positions,
  while the CARD rows below describe those same intents settling by
  card behind `NEXT_PUBLIC_FEATURE_CHAT_CARD_PAYMENT`. The brief scoped
  me to the one sentence, so the variant-selection sentence is
  untouched. If it is also stale, it needs its own issue.
- `SUBPROCESSORS.md` line 3 still reads "Status: Draft, pending DPA
  signatures", and the checklist near line 61 has no Duffel DPA line.
  Out of scope here ("add nothing else about the DPA"), but the Duffel
  DPA is now an open compliance item with nothing tracking it.
