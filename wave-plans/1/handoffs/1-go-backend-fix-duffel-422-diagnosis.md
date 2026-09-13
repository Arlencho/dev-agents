# Handoff — fix/duffel-422-diagnosis (PR #2714), 4th revision

## Built

Comment-only fix on top of the prior (3rd-revision) narrowing. The
executable diff is empty — `git diff` filtered of comment and blank
lines produces zero lines (verified below).

- `apps/api/internal/handler/duffel_refusal.go`: deleted the false
  claim that a 503 from the four named handlers with NO `error_code`
  is "the transient kind that self-clears". That inverse-of-presence
  claim was disproved a second time by `service.ErrPaymentIntentCreateFailed`
  (`booking.go:517`), whose causes include a nil
  `TripPaymentIntentCreator` in strict payment mode
  (`service/booking.go:1344`, `:1558`) — an operator wiring fault, not
  something a retry clears. The comment now states only what PRESENCE
  of `provider_unavailable_persistent` means and makes NO claim about
  absence, in any form. The former "EXCEPT four more arms" enumeration
  is reframed as "known persistent-class arms that do NOT yet carry
  this code" (not exceptions to a rule that no longer exists), folds
  in `ErrPaymentIntentCreateFailed` as a fifth known arm in that same
  reframed list (not as a fifth exception to the deleted rule — the
  distinction the task was explicit about), and cross-references #2723.
- `apps/api/internal/handler/booking_test.go`: three doc-comment fixes,
  no assertion changes:
  - `TestBookingHandler_PersistentUnavailable503s_CarryTheCode`'s intro
    no longer frames "absence means transient, keep retrying" as the
    code's intended value proposition — reworded to state only that
    PRESENCE is the trustworthy signal.
  - `TestBookingHandler_TransientUnavailable503s_StayUncoded`'s intro
    no longer says "or 'absence is meaningful' says nothing" (implying
    a general absence invariant) — reworded to scope the claim to what
    this specific test covers (known-transient causes must never be
    coded persistent).
  - `TestBookingHandler_SettlementUnavailable503s_StayUncoded_PendingFollowUp`'s
    docstring no longer claims to be "the invariant lock so the
    narrowed comment cannot silently drift back into the wider, false
    claim without a test failing here too" — that's false, the test
    asserts response behavior and cannot detect a comment edit. Now
    says explicitly what it locks (status/message/error_code for four
    named error paths) and that it does not guard prose in
    `duffel_refusal.go` or anywhere else.

## Decisions

- **Kept the "presence is meaningful" half, deleted the absence half
  entirely — did not add a fifth named "exception".** The task was
  explicit that adding `ErrPaymentIntentCreateFailed` as a fifth
  exception while keeping the rule is the move that already failed
  twice. So the rule ("absence implies X") is gone, full stop; the
  enumeration of known-uncoded persistent arms is now presented as
  informational tracking (cross-referencing #2723), not as a
  contract's exception list.
- **Also fixed three test-file comments**, not just the one at
  ~1236-1241 named in the task, because a grep for `absence (is|means)`
  and the exact false-claim wording surfaced two more spots
  (`TestBookingHandler_PersistentUnavailable503s_CarryTheCode`'s intro,
  `TestBookingHandler_TransientUnavailable503s_StayUncoded`'s intro)
  that restated the same "absence means transient" framing as design
  intent rather than as corrected history. Left
  `duffel_confirm_...`-adjacent lines that merely *contrast* against
  two known-transient causes (booking_test.go:486-487) — those don't
  assert a general absence claim.
- **Checked the PR body for the same repeat, per the task's explicit
  instruction to check PR-body sentences too.** The existing body
  narrates the absence-claim history correctly (past tense, "was
  wrong"), so no correction was needed there — but per the branch's own
  convention of a "Revised Nth time" blockquote for each review round,
  added a fourth one summarizing this fix and pointing at #2723 and the
  new #2724, via `gh pr edit`. This is metadata on the existing PR, not
  a new PR.
- **Filed exactly one follow-up (#2724)**, not implemented, proposing a
  test that enumerates every 503 in the handler package and asserts
  each is either coded or in an explicit allowlist — the "make the
  claim true by construction" ask from the task. References #2723,
  #2722, and PR #2714.

## Do not repeat

- Don't fold a disproving counter-example into an "exceptions" list
  phrased the same way as before while leaving the "except for these"
  framing — that reproduces the exact contract shape the task said had
  failed twice. Delete the rule; then list known arms as tracking
  information, not exceptions.
- When told to grep a branch for a repeated false claim, grep for the
  *idea* (`absence (is|means)`, `no error_code is therefore`,
  `momentarily unreachable`, `stay-and-retry`) across the whole
  `apps/api` tree, not just the one file named in the task — two of the
  three additional hits were in comments the task did not name.
- `git diff | grep -vE '^[+-]\s*//' | grep -vE '^[+-]\s*$'` (after
  excluding the `+++`/`---` file headers) is a fast, mechanical way to
  prove a "comment-only" mandate before claiming compliance — don't
  just eyeball the diff.

## Evidence

- `git diff --stat`: only `apps/api/internal/handler/duffel_refusal.go`
  and `apps/api/internal/handler/booking_test.go` changed.
- Executable-diff-is-empty proof:
  `git diff -- apps/api/internal/handler/duffel_refusal.go apps/api/internal/handler/booking_test.go | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]\s*//' | grep -vE '^[+-]\s*$'`
  → **zero output**, grep exit code 1 (no match).
- `gofmt -l` on both files → no output (already formatted).
- `go build ./...` → exit 0.
- `go vet ./...` → exit 0.
- `go test ./internal/handler/... -run 'TestBookingHandler_(SettlementUnavailable503s|PersistentUnavailable503s|TransientUnavailable503s|ConfirmDuffel_Duffel422)' -v`
  → all PASS.
- `go test ./...` (full `apps/api` suite) → every package `ok`.
- Follow-up filed: https://github.com/Arlencho/olympus-platform/issues/2724
- PR body updated in place: https://github.com/Arlencho/olympus-platform/pull/2714

## Open questions

- None blocking. #2724 is a new, independent follow-up (test
  tooling), not a prerequisite for this PR.

## Next hint

- Pushed to `fix/duffel-422-diagnosis` (existing PR #2714, updated in
  place — no new PR opened, nothing merged).
