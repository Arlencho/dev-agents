# Handoff: assistant-channel PRD ruling (branch feat/ac-w1c-tile, PR 2826)

## Built
`docs/prd/pages/assistant-channel.md` only, recording the co-founder ruling of 2026-09-12 on the Connected assistants tile (critic finding F4 on issue 2340).

- § 7.1 button list: `Connect` and the `Continuing...` loading label removed. List is now `Disconnect`, `Cancel`, `Try again` plus `Disconnecting...`.
- § 7.1 new ruling paragraph, dated 2026-09-12, co-founder named as Arlen: connecting starts inside the host per the § 6 rows, so the tile has no Connect control; the not-connected state is the S1 heading, the S2 sub-line and the new S10 sentence; the S8 toast fires when the traveller lands back on the site after consent, not from a tile action.
- § 7.1 element table: S10 row added under the not-connected row.
- § 7.1 error state: dropped the clause "so Connect stays reachable", which asserted the control the ruling removes.
- § 9: S10 added with the exact ratified text, marked ACCEPTED with co-founder sign-off 2026-09-12. Header count and the voice-and-tone check sentence moved from nine to ten.

## Decisions
- No § 7.0 added and no web route for the consent flow described: per the task the flow stays on the API-rendered pages.
- The error-row clause was edited because leaving it would have contradicted the ruling three paragraphs above it, inside the same section. That is the only edit beyond the literal instruction.
- S10 was checked against `docs/prd/03-voice-and-tone.md` banned phrases before the § 9 "all ten were checked" sentence was updated: no banned phrase, no emoji, no exclamation.

## Do not repeat
- § 7.1 opening paragraph still cites "the connect dialog's consent-first gate (§ 5.5 step 1)" as reused behaviour on this tile. With no Connect control on the tile, that gate now lives on the consent surface, not here. Out of scope for this amendment (it would mean describing the consent flow), so it is left for whoever lands the F1/F2 consent-screen spec.
- Q4 in § 10 still reads "all nine approved". It is a dated record of the 2026-09-12 answer, deliberately not rewritten.

## Evidence
```
make check-prd-index
OK: all 32 page spec(s) are reachable from 00-INDEX.md and every index link resolves.
self-test OK
EXIT=0
```
Dash scan on added lines: clean (no long dash, en dash, horizontal bar).

## Next hint
F1, F2, F3, F5 to F10 from the critic report are untouched. F4 is the only finding this branch commit answers.
