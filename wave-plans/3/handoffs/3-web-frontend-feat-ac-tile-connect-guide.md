# Handoff: per-host How to connect disclosure (feat/ac-tile-connect-guide)

## Built

Draft PR #2839 (branch `feat/ac-tile-connect-guide`, commit 30adff9f) implements
`docs/prd/pages/assistant-channel.md` section 7.1 as amended on the Connected
assistants tile:

- `apps/web/components/concierge/assistant-connect-guide.tsx` (new): per-host
  disclosure on the not-connected row only. Host B (Claude) gets a native
  `<details>` (closed by default, S19 summary) with steps S12-S15 verbatim as an
  `<ol>`, `{mcp_url}`/`{client_id}` substituted by copyable fields, then the S17
  line. Host A (ChatGPT) gets the section 15 Coming soon treatment: S16 note,
  `aria-disabled` button, standard tooltip, click does nothing.
- `apps/web/components/concierge/copy-value-field.tsx` (new): the ratified Copy
  control (read-only input, click-selects-all, `Copy <field name>` aria-label,
  `Copied!` for 2 s on an `aria-live` button, ratified inline failure line).
- `connected-assistants-section.tsx`: new required prop `assistantHosts`, S18
  hint on the connected row, guide placed under the S10 sentence.
- `concierge-section.tsx`: fetches the full bindings envelope, lifts
  `assistantHosts` state, passes it down.
- `apps/web/lib/api-client.ts`: new `listConciergeBindingsEnvelope()` plus
  `AssistantHost` / `ConciergeBindingsData` types; `listConciergeBindings()`
  now delegates, signature unchanged (connect-telegram-dialog untouched).
- Tests: 8 new cases in `connected-assistants-section.test.tsx`;
  `concierge-section.test.tsx` mock split (envelope mock for the section,
  bindings-only mock kept for the dialog poller).

## Decisions (+why)

- Disclosure omission rules follow the PRD literally: `assistant_hosts === []`
  (auth server off) or `null` (loading/error) omits it on every row; host A
  Coming soon renders whenever the array is non-empty, whether or not slot A is
  registered; host B renders only when a slot with `name === "Claude"` is
  present (matching by name, per the PRD, not by slot letter).
- Real `<details>`/`<summary>` instead of button + aria-expanded: keyboard
  reachability and open-state semantics come free, and the test pins the `open`
  attribute. Marker hidden via `[&::-webkit-details-marker]:hidden` + lucide
  chevron with `group-open:rotate-90` (Tailwind v4 supports it).
- Steps S13/S14 keep their templates verbatim with the placeholder; the
  component splits around the token and drops the field in, so no string is
  paraphrased. The field renders as a block inside the sentence; the S14
  trailing ". Leave the secret empty." is preserved exactly.
- Copy control was extracted as its own component rather than reusing
  share-modal markup: the modal's control is modal-scoped; section 7.1 needs it
  inline in a list item.

## Do not repeat

- Running vitest before `npm install` in a fresh worktree fails with
  "Cannot find module 'vitest/config'" because npx fetches an unrelated vitest.
  Install workspace deps first (root `npm install`, npm workspaces).
- `git diff --name-only` misses untracked files for `VOICE_LINT_FILES`; the two
  new components had to be linted separately.
- In `concierge-section.test.tsx`, do not point the dialog poller's
  `listConciergeBindings` mock at envelope-shaped values; the dialog expects a
  bare array. Two mocks are required.

## Evidence

- `npm run lint` (apps/web): exit 0
- `npx tsc --noEmit` (apps/web): exit 0
- `npx vitest run` (apps/web): exit 0, 332 files / 4677 tests passed
- `npm run build` (apps/web): exit 0
- `VOICE_LINT_FILES=... bash scripts/voice-lint.sh`: exit 0 (modified and new files)
- House-style scan: no long dash / vendor names in the diff (grep exit 1, no matches)
- PR: https://github.com/Arlencho/olympus-platform/pull/2839 (draft)

## Open questions

- Issue lifecycle labels: the task said "Refs 2800 and 2340" on a draft PR, so
  I did not add `status:in-review` to either issue (both span multiple waves
  and other PRs). The orchestrator may want to label them.
- The `Copied!` button label carries an exclamation; it is the ratified string
  from `09-bookings-detail.md` section 6.9/10, and voice lint passes (only `!!`
  is banned). Critic should confirm this reading.

## Next hint

For the critic: check the two judgment calls first: (1) host A Coming soon
rendering whenever `assistant_hosts` is non-empty even if slot A is absent, and
(2) the copyable field rendered as a block inside steps S13/S14 versus truly
inline. Both are defensible from the PRD text but are the likeliest review
targets. Also verify 375 px rendering of the long MCP URL in the read-only
input (it scrolls inside the input, same as the share modal).
