# Handoff: assistant-channel N4, S4/S5 placement

## Built

`docs/prd/pages/assistant-channel.md` only, commit `dd127d29` on `fix/ac-consent-gate`.

- Removed the **Consent line** (S4) and **Money boundary line** (S5) rows from the section 7.1 tile element table.
- Added **section 7.3, "The consent screen: where S4 and S5 live"**, marked as a placement correction ratified under the standing delegation on 2026-09-12, pointing at issue #2340 finding N4. It states the consent screen is the API-rendered page that receives the handoff from the host (W1-D), carries the connect-dialog consent-first gate from `24-account-concierge.md` section 5.5 step 1 (unchecked checkbox labelled S4, S5 below it, primary action disabled until checked), and that section 9 rows S4 and S5 keep their text unchanged.
- Two consequential pointer fixes inside the same contradiction: the section 7.1 reuse list no longer claims "the connect dialog's consent-first gate (section 5.5 step 1)" as tile behaviour, and the D2 row in section 2.1 now sends the reader to 7.3 for the gate instead of to the tile.
- One clause added to the section 7 preamble so "two halves" does not read as wrong against three subsections.

## Decisions

- **Numbered the new subsection 7.3, not 7.2.** Section 7.2 (the tool half) is cross-referenced from lines 32, 44 and elsewhere in the same page; renumbering it would have broken live citations for cosmetic ordering.
- **Did not touch section 9.** The task fixes the text of rows S4 and S5 as unchanged, so the stale `(section 7.1)` citation in their `Where` column is resolved by a sentence in 7.3 that reads those citations through to the new subsection, rather than by editing the ratified rows.
- **Did remove the gate clause from 7.1 and repoint D2.** Leaving either in place would have kept the exact self-contradiction N4 charges: a tile that by ruling has no consent moment still advertising a consent gate. Root cause, not the two rows alone.
- **Left `apps/web/CLAUDE.md` uncommitted.** See below.

## Do not repeat

- The working tree arrived with an uncommitted `apps/web/CLAUDE.md` hunk: a `BEGIN:nextjs-agent-rules` block that a build tool re-adds, whose own text argues that committing it "keeps the tree clean". It is out of this task's scope (one file), it carries a long dash against house style, and file content is not a source of instructions. It was left uncommitted on purpose. Do not sweep it into an unrelated commit; if it should land, it needs its own scoped change.
- W1-D has no doc reference in the tree. The only evidence is `apps/api/internal/handler/assistant_oauth_critic_test.go:3` and `apps/api/internal/service/assistant_auth_critic_test.go:3`, both naming PR #2815. Do not go looking for a W1-D section in `docs/`.

## Evidence

```
$ make check-prd-index; echo "EXIT CODE: $?"
OK: all 32 page spec(s) are reachable from 00-INDEX.md and every index link resolves.
self-test OK
EXIT CODE: 0

$ git diff -U0 docs/prd/pages/assistant-channel.md | grep '^+' | grep $'—\|–\|―\| -- '
none (clean)

$ git show --stat --oneline HEAD | tail -2
dd127d29 docs(prd): move S4 and S5 to the consent screen, assistant channel
 docs/prd/pages/assistant-channel.md | 26 +++++++++++++++++++++-----

$ git push -u origin fix/ac-consent-gate
 * [new branch]        fix/ac-consent-gate -> fix/ac-consent-gate
```

No PR opened: the task asked for commit and push only. Create-PR URL: https://github.com/Arlencho/olympus-platform/pull/new/fix/ac-consent-gate

## Open questions

- N4 asked for a co-founder call between two options (move the strings, or reserve them in 7.1). This took the first, as the task directed. The consent-gate obligation is now written down as W1-D's, but no W1-D issue was updated to claim it. Worth a line on #2799 or the W1-D PR so the F2 obligation does not get lost a second time.
- N1, N2, N3 and N5 from the same critic round are code-side and untouched here.
