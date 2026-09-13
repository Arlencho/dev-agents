# Handoff: PR 2802 review fixes, branch docs/prd-assistant-channel-w0

## Built
- `docs/prd/pages/assistant-channel.md` only, commit `93cafc6e` (17 insertions, 14 deletions), pushed to the same branch so PR 2802 updated in place. Not merged, no new PR.
- F1: raw `brief` handling rule at § 3.3.1 (normalised in memory, then dropped: never persisted, logged or returned); § 3.1 date-of-birth row rewritten so the prohibition is on our retention, citing `01-conventions.md` § 13 and `docs/compliance/RETENTION.md`.
- F2: § 3.3.7 refusal now logs the refusal, tool name and offending field name, never the value.
- F3: § 3.2 `web_url` row constrained, no checkout/payment/pay-link URL in any Wave 2 output.
- F4: `summary` enumerated as an explicit allowlist at § 3.3.1, and § 3.3.4 defines the full fact set as that list and nothing else.
- F5: `note` kept, given the F1 treatment (scanned on write, refused with `invalid_input`, field name logged, stored only when clean); Q5 closed in the page, still PROPOSED.
- #2798: two host name slots filled in § 6; authorization-flow and consequential-action columns left as unread placeholders verbatim.
- #2799: one invite-gate sentence added to the identity section (§ 2.1, on D2).
- One comment posted on PR 2802 listing changes per finding and naming both decisions.

## Decisions
- Also corrected § 2.1 D4 and § 10 Q2, which asserted the hosts were unnamed and would have contradicted the § 6 fill after the #2798 decision. Flagged explicitly in the PR comment.
- PR body left unedited: no user-facing string changed, and the task scoped body edits to string changes. The body's now-stale host-name rows are called out in the PR comment instead.
- Host names appear inside the page only, as product substance. Commit message and PR comment carry no vendor name and no long dash.

## Do not repeat
- Do not fill the two documentation columns in § 6 from memory. They are read from each host's current published documentation in W1 and cited with a URL and a date.
- Do not restructure the page. The review raised five findings; everything else stays as written.

## Evidence
- `make check-prd-index` then `echo $?` gives `EXIT_CODE_check_prd_index=0` (32 pages reachable, 18-case self-test OK), exit code captured directly, not after a pipe.
- `git diff --name-only` before commit: `docs/prd/pages/assistant-channel.md` and nothing else.
- Added-line long-dash grep exits 1 (no match).
- `gh pr view 2802 --json headRefOid` returns `93cafc6e3c737d56e9e888124dd7fcb403c81012`, equal to local HEAD and to `origin/docs/prd-assistant-channel-w0`.

## Open questions
- Q1 (eight tools or nine), Q3 (service name) and Q4 (the nine strings) remain open for sign-off. Q2 is half closed: names taken, documentation reading still owed before W1.
