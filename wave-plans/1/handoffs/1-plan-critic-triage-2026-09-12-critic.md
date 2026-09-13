# Handoff: docs/live-booking-docs-sweep (PR 2813)

## Built

Three review fixes from the CRITIC LIVE DOCS SWEEP comment on issue 2340.
Commit `18d2345b`, pushed to `docs/live-booking-docs-sweep`. Not merged.

1. `docs/prd/pages/atlas-chat.md` (balance-variant row, line 3442): the
   2026-09-12 amendment cited PR #2663 alone. Now cites both PRs whose
   commits are dated 2026-08-14: #2663 (`34f380bb`, the checkout libs'
   post-settlement card path) and #2664 (`3b10e08b`, the chat-v2 wiring
   and the CARD row in this table).
2. Same cell: deleted the leftover claim that the two intents have no
   ratified card confirm SURFACE.
3. `docs/operations/duffel-balance-funding.md` (Budgeting, line 52):
   removed the KYC clearance and the funding calendar date. The sentence
   now states only the supported facts.

## Decisions

- Finding 3 sits inside a single sentence that also carries live spec
  content (balance carts name `settlement` explicitly rather than
  leaning on `STANDALONE_SETTLEMENT_DEFAULT`). Deleted the false premise
  and its consequence clause, kept the rule, re-opened the sentence as
  "On the balance variant their carts ask for ...". Deleting the whole
  sentence would have dropped ratified spec for no review reason.
- Cited "commits dated 2026-08-14" rather than a merge date. PR 2663
  merged `2026-08-13T23:56:14Z` in UTC while both commit dates read
  2026-08-14, so a bare merge-date claim would have been the same class
  of unsupported calendar claim as finding 2.
- The Balance sentence cites the booking id and the 201 rather than a
  funding event. No amounts (`16245` stays out), no KYC, no dates other
  than 2026-09-11.
- No `Co-Authored-By` trailer and no vendor name: project CLAUDE.md
  (board directive OLY-4) and the git-ship skill both forbid them, and
  they outrank the session default.

## Do not repeat

- Do not edit this repo from the primary working directory while other
  sessions are live. Mid-task a concurrent process ran
  `git checkout main` in `/Users/arlenrios/dev/olympus-platform`, moving
  HEAD off the branch under an in-flight edit. Nothing was lost (the
  edit script asserts all match counts before it writes any file), but
  the work was redone in a throwaway `git worktree`. Use a worktree.
- Do not trust `sed -n 'A,Bp' | cat -n` for line numbers. It renumbers
  from 1 and the first read of these files reported the wrong offsets.
  `grep -n` on the target string is the reliable locator.
- Issue 2646's 2026-09-11 comment does contain the KYC / funding-date
  claim. It is not an allowed source for this sweep, so it cannot be
  used to reinstate the sentence.

## Evidence

    git log -1 --format='%H %ad' --date=short 34f380bb
    -> 34f380bb... 2026-08-14   (touches chat-flight-checkout.ts,
                                 chat-stay-checkout.ts, lib/types.ts)
    git log -1 --format='%H %ad' --date=short 3b10e08b
    -> 3b10e08b... 2026-08-14   (touches chat-v2.tsx,
                                 use-real-booking-confirm.ts,
                                 docs/prd/pages/atlas-chat.md +2 rows)
    git show 3b10e08b -- docs/prd/pages/atlas-chat.md | grep -c '^+|'
    -> 2                        (the two CARD rows)

    LOG EVIDENCE comment on PR 2812: contains 2026-09-11, booking
    282d1d31-8915-48e9-806c-c2bf8326f16d, Duffel order POST 201 at
    11:28:34. grep -ci 'insufficient_balance|kyc' -> 0.

    make check-prd-index                  -> exit 0 (31 pages, self-test OK)
    banned chars in authored clauses      -> 0
    vendor names in added text            -> 0
    co-authored-by / vendor in commit msg -> 0
    git diff --name-only main...HEAD      -> exit 0, 4 files:
      docs/COST_INVENTORY.md
      docs/compliance/SUBPROCESSORS.md
      docs/operations/duffel-balance-funding.md
      docs/prd/pages/atlas-chat.md
    git diff --stat main...HEAD           -> 5 insertions, 5 deletions
                                            (identical shape to the
                                             critic's recorded diff)
    git push origin docs/live-booking-docs-sweep
                                          -> exit 0, e81ed3bd..18d2345b
    gh pr view 2813                       -> OPEN, draft, head 18d2345b

## Open questions

- `docs/COST_INVENTORY.md` and `docs/compliance/SUBPROCESSORS.md` were
  not touched by this pass. The critic's sentence ledger cleared every
  new clause in both, so they need no further work for this review.
- PR 2813 is still a draft. Findings 1 to 3 are the only BLOCK-FIX items
  raised, so it is ready for a re-review, not for merge by this agent.
