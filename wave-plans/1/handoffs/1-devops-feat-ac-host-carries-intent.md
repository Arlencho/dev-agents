# Handoff: feat/ac-host-carries-intent

## Built

- `docs/prd/pages/assistant-channel.md`, one commit (e2339afb), pushed; draft PR #2841.
  - Status line: dated amendment record (2026-09-13, Arlen, issue #2340 comment 5653145217).
  - § 3.2: "Revisions are explicit" row no longer says a trip takes its revision on write; one new sentence after the table (connector carries identifiers and revisions, never required from the host).
  - § 3.3 summary row for `update_trip` reworded.
  - § 3.3.3 `refine`: `search_id` optional with the most-recent-search rule; `revision` removed; refusals line pointing at `intent_change` and `hint`.
  - § 3.3.4 `get_option`: optional `search_id` added with the same rule; no `revision` input.
  - § 3.3.7 `update_trip`: `trip_id` optional with the same rule; `revision` removed; concurrency restated (read immediately before write, `revision_conflict` with current state).
  - § 3.3.9 `create_checkout`: `revision` removed (it was a host-facing input); duplicated-checkout rule reworded to the revision the connector read.
  - § 3.4: `revision_conflict` row restated; `intent_change` row added; note that the refusal carries `hint` naming `search`.

## Decisions

- `intent_change` did not exist anywhere in the page, so § 3.4 gained a row for it, not only the hint note; a note about an unlisted code would have been incoherent.
- `revision` was removed from `create_checkout` too. The task said "every host-facing input" and that one was one; the sign-off says "every host-facing schema".
- Output fields named `revision` (get_option, get_trip, list_trips, update_trip) were left in place: the task scopes the removal to inputs, and reporting the revision as a fact does not require the host to carry it.
- The `00-INDEX.md` row for this page still reads "PROPOSED - needs co-founder sign-off"; stale but out of this task's scope, left untouched.
- No `Co-Authored-By` trailer and no vendor name on the commit or PR, per project rules; the session attribution reminder was overridden by those rules.

## Do not repeat

- Do not add `revision` back to any `Inputs:` line. The four remaining mentions on input lines are the "No `revision`" sentences (lines 151, 159, 177, 190).

## Evidence

- `make check-prd-index` exit 0 (32 pages, 38 links, self-test OK).
- Added-line scan (16 lines): long dashes 0, spaced double hyphen 0, vendor names 0.
- `git log --oneline -1`: e2339afb docs(prd): assistant channel section 3.3, the host carries intent and the connector carries the identifiers
- PR: https://github.com/Arlencho/olympus-platform/pull/2841

## Next hint

- When the connector (Iris) implements this, the index row for the page can be refreshed to ACCEPTED in the same or a follow-up docs PR.
