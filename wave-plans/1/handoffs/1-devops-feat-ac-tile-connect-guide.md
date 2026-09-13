# Handoff: feat/ac-tile-connect-guide, docs-only follow-up (2026-09-13)

## Built

- `docs/operations/assistant-hosts.md`
  - Host B section: new "Walk record, host B, observed 2026-09-13" (nine numbered items, labels quoted as seen by the operator on the desktop app, 10:47 to 12:00 local), plus a "not walked, so not recorded" line. Tester steps rewritten to follow the record; each step names the record item and the contract string (S12 to S15) it matches. Step 6 records the `Tool permissions` groups and their `Needs approval` default and marks in-conversation prompt behaviour as not walked.
  - Preflight item 1: precondition met. #2837 (merged 09:39 UTC) is serving on API and Iris; both carry the Iris MCP URL as `ASSISTANT_RESOURCE_URI`, the API carries `ASSISTANT_ISSUER`. The cut-over ordering is kept as a general rule for the next URL-contract change.
  - Item 2 live results and item 5 fix status updated to the post-deploy state.
  - Page-scope notes (line 5, Sources, "What the cited pages do not contain") now say the host B click sequence comes from the walk record, not from the cited pages; host A remains unwalked.
- `docs/prd/pages/assistant-channel.md`: S12 note cites the dated walk record (item 1) instead of the cited pages. S14 and S15 notes name which of their words are host labels and point at the record items.

## Decisions

- The walk record is written as an observation with a date, explicitly not a citation, so a page re-read can never "confirm" it; only another walk can.
- The page's rule "no host names outside URLs" gets one stated exception: host screen labels inside the walk record are quoted verbatim (one label contains the host name). The task's house style allows the host name the contract already uses.
- Tester step 6 no longer asserts "reads run without a prompt". The observed `Needs approval` default on both groups contradicts the inference from the checklist, and the conversation behaviour was not walked, so the step now says to expect a prompt until a session shows otherwise.
- S14 and S15 got a one-clause pointer each (not asked for, but they quote host labels the record now backs; cheap and keeps the PRD from drifting).

## Do not repeat

- Do not re-add "the running build derives the authorization server from the resource origin" as current state; that was the pre-#2837 build and is now history in item 5.
- Do not cite the host B authentication page for any menu or button name; it does not carry them.

## Evidence

- `gh pr view 2837`: MERGED 2026-09-13T09:39:39Z, merge commit 067e3efb.
- Live, 2026-09-13 after the deploy: both discovery documents `200` in 0.06s; `resource` = `https://olympus-iris-964499096147.europe-north1.run.app/mcp` (`resource ok`); `issuer` = `https://olympus-api-964499096147.europe-north1.run.app` (`issuer ok`); `S256`, `token_endpoint_auth_methods_supported: ["none"]`.
- `make deployed-version`: serving 78fb6a9c = newest apps/api = origin/main (MATCH).
- `make check-prd-index`: exit 0 (32 pages indexed, self-test OK).
- Dash scan (U+2014, U+2013, U+2015, ` -- `) over both files: 0.
- Commit `1af91fc5`, pushed to `origin/feat/ac-tile-connect-guide`. No Co-Authored-By trailer.

## Open questions

- Which two other options sit under `Authentication` on the host B dialog (not recorded on the walk).
- What the host shows in conversation before a tool call under the `Needs approval` default; first pilot session should record it and step 6 gets updated from that.
