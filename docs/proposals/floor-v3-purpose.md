# Floor v3: built from its purpose

Assessment and proposal, 2026-09-12. Status: PROPOSED, for the owner's decision.

## 1. The purpose, stated once

The Floor exists so the owner never has to ask "how is it going". Opened cold, on a laptop or a phone, it must answer five questions in the time it takes to glance at it:

1. What is happening right now, in which repo, fixing what.
2. What is next, in what order.
3. What landed today, what failed, and where the receipts are.
4. Is anything stuck, blocked, or waiting on me, and what is the one action.
5. Where does each initiative stand against its goal.

Everything on the page is judged by one test: does it help answer one of those five in under five seconds. If not, it is folded away or removed.

## 2. What the current Floor does well

- It is honest. Only facts from the event stream are shown; queued never renders as running; stale and offline are marked; replay carries a watermark. Keep every one of these rules.
- After #68 and #70 it has the right raw material: seats with an activity sentence, a queue, landed today with outcomes, a summary line.
- It updates itself. No refresh, no restart.

## 3. Where it fails the purpose

| Gap | Why it fails the test |
|---|---|
| Single-dispatch heritage | The page was built to follow one run. Breadcrumb, scrubber and trail block all describe one dispatch. With two repos live they mislead. (#72 fixes the seat side.) |
| Chrome before content | Replay scrubber, schema intro, stale mission crumb and four tiles sit above the summary. The reader scrolls to reach the answer. (#72 collapses them.) |
| No "needs you" surface | The single most valuable answer, question 4, does not exist anywhere. A critic BLOCK, a PR waiting to merge, a seat gone quiet, a failed dispatch, a PRD row awaiting sign-off: all invisible unless the orchestrator says so in chat. |
| No initiative view | Question 5 is unanswerable. Nothing relates a seat to a milestone or a wave to its goal. |
| Ids where words belong | dispatch ids, seq numbers, schema names in headers. (#70 and #72 cover most of it.) |
| Today only | Yesterday's failures and last week's throughput are only in the Almanac tab, which is a different mental model. |
| Silent | Nothing pushes. A BLOCK at 22:00 waits until someone opens the page. |

## 4. The v3 page, top to bottom

One screen at 1280, one scroll at 400. Plain words. Every number is a link to its source. No ids in headers.

### 4.1 Status strip

`2 running · 3 up next · 32 landed · 1 failed · needs you: 2 · last event 4 s ago`

Each figure links to its section. "needs you" is red when non-zero. Under stale or offline the strip says so first, in words, before any number.

### 4.2 NEEDS YOU

The reason the page exists. One row per item, newest first, each with exactly one action:

- A critic posted BLOCK-FIX and no fix wave is running: `Iris round 2 blocked by backend critic · 3 findings · open the comment`.
- A PR is SAFE-TO-MERGE from every critic and CLEAN: `PR #2829 ready to merge · merge`.
- A seat has been quiet longer than the threshold: `go-backend on W2-B quiet for 4 min · check the log`.
- A dispatch failed: `W2-A security seat failed after 437 s · see the output`.
- A PRD row is PROPOSED and blocks a queued wave: `S11 awaits sign-off · approve or edit`.
- A repository variable or secret the next wave needs is missing: `IRIS_PUBLIC_URL unset · set it`.

Sources: issue and PR comments with the critic first-line convention (through gh, optional, never fatal, marked unverified when skipped), heartbeat age from the stream, dispatch_end status, PRD grep for PROPOSED rows named in queued plans, and the env contract checks already in the repo. Empty state reads: `Nothing needs you.`

### 4.3 NOW, grouped by repo

As specified in #72: repo header with counts, then one card per seat: repo, issue and milestone, purpose, seat task line, status sentence, branch dim, PR when open. A seat card whose heartbeat is old shows the same quiet mark the strip uses.

### 4.4 UP NEXT

Queue by position with repo first, issue number, purpose, and one dim line for the plan file. A queued plan that is blocked (waiting on a sign-off, a merge, or a missing variable) shows the reason in place instead of pretending it is ready.

### 4.5 INITIATIVES

One row per open milestone that has had activity in the last 30 days: name, waves landed of waves planned (from the plan naming convention and the queue), open issues, last landed PR, and the one sentence that names the exit criterion (from the epic body when it carries one). Example:

`Assistant Channel Track · wave 2 of 4 · 5 open issues · last landed #2829 · exit: five distinct testers complete a checkout`

Source: GitHub milestones and issues through gh, optional, never fatal. Where gh is unavailable the row shows what the queue and the streams alone can prove and says so.

### 4.6 LANDED and FAILED today

Two lists, failed first when non-empty. Each row: repo, purpose, outcome word, duration, PR number and title, critic verdict count when known (`2 rounds, safe`). A row with a failed seat that later landed shows both.

### 4.7 Details, closed by default

Replay and the scrubber, the event tail, the raw stream paths, the schema line, the trail block. One details control at the bottom. Nothing in it is needed for the five questions.

## 5. Beyond today

- A "yesterday" toggle on the strip, reading the previous day's streams the same way. History deeper than that stays in the Almanac.
- Push: `scripts/notify.sh` already exists for seat outcomes. Extend it so a NEEDS YOU item with no action taken for N minutes sends one macOS notification with the same one-line text. Off by default, one env var to enable.

## 6. Rules that do not change

- Only facts from the stream and from sources named on the page. No inferred seats, no predicted outcomes.
- Queued never renders as running. Stale and offline degrade every element. Replay never claims live.
- No prompt, task body, argument, secret or absolute path ever reaches the page.
- The page works at 400 wide, with keyboard focus visible, and no horizontal scroll.

## 7. Delivery, after #72 lands

| Wave | Seats | Delivers |
|---|---|---|
| v3-A | devops, plan-critic | NEEDS YOU and INITIATIVES data in live.json, with the gh enrichment rules and the blocked-queue reasons |
| v3-B | web-frontend, frontend-critic | The page in the order of section 4, details folded, strip first |
| v3-C | devops, plan-critic | Yesterday toggle and the notification path |

The frontend critic's acceptance test for v3-B is the five questions: a reader who has never seen the page answers all five from the page alone, at 1280 and at 400, with two repos live and one BLOCK outstanding.

## 8. What I would not build

- A chat or narration panel. The page shows facts; the orchestrator explains.
- Per-seat transcripts. The redaction law is the reason the page can be trusted.
- Graphs of throughput. The Almanac already owns history; the Floor owns now and next.
