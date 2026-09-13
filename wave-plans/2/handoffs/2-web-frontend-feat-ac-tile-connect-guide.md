# Handoff: tile connect guide block-fix (#2340)

## Built

Branch `feat/ac-tile-connect-guide`, PR #2839 (kept a draft per task).

- **Block 1** `apps/web/components/concierge/concierge-section.tsx`: the bindings envelope is re-read when the traveller returns to the tab (`visibilitychange` to `visible` and `window.focus`), throttled to at most once per 4 s (`RETURN_REFETCH_MIN_MS`). Refetch runs with `{ background: true }` so `loading` is not flipped and the rows never re-skeleton. The S8 toast needs no new code: the background refetch updates `bindings`, and the existing effect in `connected-assistants-section.tsx` fires on the unseen binding id. Added the critic's `return-refetch.test.tsx` byte for byte; it passes (was RED on the old head).
- **Fix 3** `assistant-connect-guide.tsx` `renderStep`: text after a copyable-value token now has a leading `. ` stripped (`replace(/^\.\s*/, "")`), so S14's second line reads `Leave the secret empty.` instead of `. Leave the secret empty.`. New assertion in `connected-assistants-section.test.tsx`: a TreeWalker over every `assistant-guide-step-claude-*` asserts no text node starts with a period.
- **Fix 4** `copy-value-field.tsx`: the read-only value input now carries `min-h-11 md:min-h-0`, matching the Copy button; 44 px at 375 px wide.

## Decisions (+why)

- **Throttle window of 4 s, first event fires immediately** (`lastReturnRefetchAt` starts at 0). The critic's test dispatches hidden -> visible -> focus within milliseconds and expects exactly one extra fetch, so the debounce must coalesce, not delay; a leading-edge throttle does that without timers.
- **Dropped the punctuation rather than rendering the field inline.** The critic offered either; stripping `. ` is the smaller change and keeps the block-level layout the Copy control's full-width row already implies.
- **Block 2 (docs walk of host B's screens) not touched.** The task scoped block 1, fix 3, fix 4 only; block 2 needs a human to walk the host's UI and record labels in `docs/operations/assistant-hosts.md`.

## Do not repeat

- This worktree had no `node_modules`; `npm ci --workspace apps/web --include-workspace-root` at the repo root is what made the gates runnable (the critic used a /tmp mirror with linked deps instead).
- macOS `grep` has no `-P`; use `grep -e "$(printf '\u2014')"` for the long-dash scan.

## Evidence

- `npx vitest run components/concierge` (apps/web): 4 files, 35 passed (was 3 / 33).
- `npm run test` (apps/web): 333 files, 4679 passed, exit 0.
- `npx tsc --noEmit`: exit 0. `npm run lint`: exit 0.
- `VOICE_LINT_FILES=/tmp/voice-files.txt bash scripts/voice-lint.sh` on the five changed files: passed, exit 0.
- Long-dash scan (U+2014/U+2013/U+2015 and spaced `--`) of added diff lines and the new test file: 0 hits.
- `npm run build` (apps/web): exit 0.

## Open questions / Next hint

- The critic's round-two batch should re-run `return-refetch.test.tsx` and the new TreeWalker assertion; both are the acceptance bars it named.
- Block 2 remains open and is docs-only: someone must walk host B's add-connector screen, record the labels with a date in `docs/operations/assistant-hosts.md`, and make PRD `:409` cite that record. Until then the critic said the tile must not go to a pilot tester as self-sufficient.
- Pilot precondition still stands: the running API revision's `ASSISTANT_RESOURCE_URI` must end in `/mcp` before a tester sees step 2.
