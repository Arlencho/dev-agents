# Handoff: docs/settlement-check-observed (PR 2812)

## Built

`docs/operations/deployment.md`, section "Establishing what the RUNNING
production build does", commit `7eb3b563`. Five edits, all inside the section:

1. Step-4 table reordered: the modal-open network `POST` row is now first and
   carries the **READ THIS ONE FIRST: it is the discriminator** marker.
2. The CTA sub-line row now reads `Confirm booking`, no sub-line, in BOTH
   columns, labelled "No longer discriminates, do not read it."
3. The `Observed 2026-09-11` line lost the false sub-line claim and keeps only
   the modal-open `POST` to `/api/v1/bookings` carrying `"settlement":"card"`
   and answering `201`.
4. New dated note under the table: the sub-line stopped discriminating on
   2026-09-04 via PR #2778, so an operator working from an older revision of
   the section does not read a missing sub-line as a Balance build.
5. "Why the CTA sub-line and not the card field" became "Why the modal-open
   `POST` and not the card field", with the rationale restated on the request.
   The parenthetical about sub-line suppression became a parenthetical about
   the `POST` firing once at open. The card-field warning is unchanged in
   substance ("The card field is not." became "The card field carries no such
   guarantee." only because its antecedent moved).

Untouched, deliberately: the dated record at `:118` (orchestrator is attaching
log evidence separately), the webhook-rejection note, steps 1, 2, 3, 5, 6, and
everything outside the section.

## Decisions

- **Reordered the table rather than only moving the marker.** A row labelled
  "READ THIS ONE FIRST" that is not first is its own trap. The network row is
  now row 1.
- **Kept the sub-line row instead of deleting it.** Deleting it leaves a reader
  who remembers the old runbook with no correction; an explicit "both columns
  render the same thing" row closes that loop. The dated note under the table
  does the same job for anyone holding a stale copy.
- **Rationale for the `POST` is the phase-1 argument, not a new claim.** Source
  check: `chat-trip-card-confirm.tsx:31-45` states the card path creates the
  booking when the modal opens because Stripe has nothing to mount until a
  PaymentIntent exists. So the request precedes the card leg, and a phase-1
  failure is a non-`201` answer to that same request rather than a missing row.
- **Linked #2778 as `/pull/2778`**, confirmed it is a merged PR, not an issue.

## Do not repeat

- Do not restore the CTA sub-line as a discriminator anywhere. It does not
  exist in the shipped bundle. `payment-confirm-modal.tsx:816` says so, and
  `payment-confirm-modal.test.tsx:641-647` asserts its absence on both variants.
- Do not try to verify the Cloud Run log window from this machine for the
  `:118` record. That is BLOCK 3 on the critic comment and is the
  orchestrator's separate item, not this change.
- Do not touch step 6. Its bytes are load-bearing for the critic's diff check.

## Evidence

```
$ git log -1 --format='%H %ad %s' --date=iso ea4776b9
ea4776b967b3ac2240cdfa9c1f39603492df3c54 2026-09-05 00:11:15 +0200
fix(web): retire the `. no balance` CTA sub-line on both variants (#2778)

$ git branch -a --contains ea4776b9   # includes main

$ gh run list --workflow deploy-web.yml --branch main --limit 12
2026-09-10T19:27:59Z success a7365e7ed    <- last deploy before the walk
2026-09-05T22:06:16Z success 1226e1dfb
2026-09-05T21:54:57Z success 7c762b1e7
2026-09-05T21:45:40Z success 0ecac370d
2026-09-05T21:34:20Z success 68c8967e8
2026-09-05T21:05:30Z success d8d773e50
2026-09-04T22:39:54Z success cc90e7be5
2026-09-04T22:11:18Z success ea4776b96    <- sub-line removal shipped
```

Six successful production web deploys sit between the removal and the
2026-09-11 walk, so the sub-line was absent on both builds that day.

```
$ sed -n '104,200p' docs/operations/deployment.md | grep -n 'sub-line\|no balance'
48: | Primary CTA sub-line. **No longer discriminates**, do not read it. ...
53: > **The CTA sub-line stopped discriminating on 2026-09-04.** ...
```

Both surviving mentions assert the opposite of "it discriminates".

```
$ git diff --stat origin/main
 docs/operations/deployment.md | 18 ++++++++++++------

$ git diff origin/main -- docs/operations/deployment.md | grep -E '^[+-]\*\*6\.'
(no output: step 6 untouched)

$ make check-prd-index >/dev/null 2>&1; echo $?
0

$ git diff -- docs/operations/deployment.md | grep '^+' | grep -P '[\x{2014}\x{2013}\x{2015}]| -- '
(no output)
```

Pushed `23359249..7eb3b563` to `origin/docs/settlement-check-observed`.
Not merged.

## Open questions

- The critic's lower-severity point stands untouched: `:118` asserts the
  observed position "matches the environment value of `1` read in step 1",
  but the step-1 baseline at `:134` is dated 2026-08-31, eleven days before
  the walk. Either re-run step 1 and re-date `:134`, or state the baseline's
  date inline at `:118`. Out of scope for this fix, by instruction.
- Same for the "Three log lines" count at `:118` against four cited
  timestamps.
