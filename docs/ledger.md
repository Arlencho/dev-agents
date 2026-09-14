# The fleet ledger: what a finished seat actually records

Inventory for fleet optimization W1 (docs/proposals/fleet-optimization.md
section 5). Every line below was read from real log files on this machine on
2026-09-14; the file and field are named for each. No field is assumed. Where
a provider records no cost or no tokens, that is stated plainly.

Data roots on this machine:

- The dispatching checkout: `~/Desktop/dev-projects/AI-Orchestration/dev-agents`
  (holds `logs/dispatch-runs/`, `logs/fleet-events/`, the collected seat logs
  under `logs/`, and `logs/fleet-queue.json`).
- The seat log directory the dispatchers write to: `~/dev/agent-logs/`
  (`<repo>-<branch>-<YYYYMMDD-HHMMSS>.log`, one file per seat run).

## First-party launcher (providers/claude/launch.sh)

A finished seat ends its log with one stream-json line `"type":"result"`.
Real example: `~/dev/agent-logs/dev-agents-feat-detached-dispatch-20260913-103620.log`,
line 786. This seat's dispatch (`20260913-083601-dev-agents`) wrote no run log
under `logs/dispatch-runs/`, and its `seat_log` event names the later critic
seat's file, so the line lives only in the seat's own log; the ledger reads it
from there (the fallback below).

That line records:

| Fact | Field on the result line |
|------|--------------------------|
| Wall duration | `duration_ms` (1551113 in the example) |
| API time | `duration_api_ms` (876451) |
| Turns | `num_turns` (52) |
| Input tokens | `usage.input_tokens` (738) |
| Output tokens | `usage.output_tokens` (76938) |
| Cache tokens | `usage.cache_read_input_tokens` (2793104) and `usage.cache_creation_input_tokens` (183295) |
| Cost | `total_cost_usd` (8.221354) |
| Model | `modelUsage.<id>` per model used, with per-model `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, `costUSD`, `provider:"firstParty"` (example: `claude-fable-5-1` plus a small `claude-haiku-4-5-20251001` share) |
| Outcome | `subtype` (`success`) and `is_error` (false) |

A result line can appear in up to three places: the seat's own file in
`~/dev/agent-logs/`, its copy collected into `logs/` of the dispatching
checkout, and inline in `logs/dispatch-runs/<dispatch id>.log` between the
seat's `Starting claude launcher for agent <role>` line and its
`=== Agent completed on localhost ===` line. The traced example above exists
only in the first of the three. Wherever the line is found, the ledger counts
it once (deduplicated by recorded session).

Where a first-party seat records no cost: a seat that dies mid-stream writes
no result line at all. Verified on dispatch `20260913-184551-dev-agents-57571`
(the 2026-09-13 spend-limit evening): both seat logs
(`dev-agents-feat-floor-v3c-20260913-204608.log` and `-210430.log`) contain
zero result lines, and the dispatch log's copy of the stream is cut off
mid-line. Such a seat has no recorded cost, no tokens, no turns. The ledger
marks it cost unknown; it never invents zero.

During the run the log also carries `rate_limit_event` lines (five-hour and
seven-day utilization), which are seat context, not cost records.

## Kimi launcher (providers/kimi/launch.sh)

`kimi -p <prompt> --output-format text` writes a plain-text log.
Real example: `~/dev/agent-logs/olympus-platform-feat-ac-handover-landing-20260913-142354.log`
(1468 lines).

- First line: `kimi version 0.42.0`.
- Last line: `To resume this session: kimi -r session_<uuid>`.
- In between: the seat's prose and tool narration.

A kimi seat records no cost, no token counts, no turns, no duration and no
model anywhere in its log. Nothing to sum: cost unknown, tokens unknown,
always. Duration and outcome exist only in the event stream
(`seat_dispatch` / `seat_exit`, below). The model named on the
`seat_dispatch` event is the requested fleet pin (for example
`claude-fable-5-1`), which the kimi launcher ignores; the actual model is the
CLI default and is not recorded.

## Grok launcher (providers/grok/launch.sh)

`grok -p <prompt>` writes a plain-text log.
Real example: `~/dev/agent-logs/dev-agents-feat-floor-needs-you-superseded-20260913-222355.log`
(22 lines, a finished critic seat).

- Prose narration plus `Memory flush started` / `Memory flush written:
  /Users/arlenrios/.grok/memory/...` lines.

A grok seat records no cost, no token counts, no turns, no duration and no
model anywhere in its log. Same rule as kimi: cost unknown, tokens unknown,
always; duration and outcome come from the event stream only.

## Dispatch-level records (provider-independent)

Event stream `logs/fleet-events/<dispatch id>.jsonl` (schema
`fleet-events/1`), real example `20260913-122123-dev-agents-87236.jsonl`:

| Event | Fields the ledger reads |
|-------|-------------------------|
| `dispatch_start` | `ts`, `repo`, `plan` (plan basename), `mode` |
| `dispatch_plan` | `waves`, `seats` |
| `wave_start` / `wave_end` | `ts`, `wave` |
| `seat_dispatch` | `ts`, `wave`, `task_id`, `agent` (role), `branch`, `provider`, `model` (requested), `attempt` |
| `seat_exit` | `ts`, `status` (`success`, `failed`, `unavailable`), `exit`, `duration_s`, `attempt` |
| `dispatch_end` | `ts`, `status` (`completed`, `failed`, `aborted`), `duration_s` |

Run log `logs/dispatch-runs/<dispatch id>.log`:

- Header `Detached dispatch <id>: pid <n>, session leader, started <ISO>Z`.
- `Repo: git@github.com:Arlencho/<repo>.git`.
- Per seat: `Starting <vendor> launcher for agent <role> (model: <pin>)...`
  then `Logging to: <absolute seat log path>`, and at the end
  `✓ <role> completed in <n>s` or a failure line.
- `Dispatch Results` table (wave, agent, model, branch, worker, duration,
  status, log) and `Total duration: <n>s`.

Sidecar files: `<id>.pid` (pid, repo slug, plan path, start ISO) and
`<id>.exit` (the run's exit code).

Plan headers `wave-plans/<initiative>/<name>.plan`: the header comments name
the issue as `issue 2340` / `Issue 2800` when there is one (first match
wins), and carry the `DISPATCH:` line. A `TIER:` header does not exist in any
plan on disk yet (that is workstream W2), so tier is `unknown` for every
historical seat. Round is the round of the plan itself: a `FIX-ROUND: n of
<path>` header means round n+1, and a `FIX-ROUND:` header in any other form
means round 2 (real example: `# FIX-ROUND: 2026-09-14-w1-ledger.plan` names a
path, not a count; the leading 2026 is a date, never a round), else the first
`ROUND n` the plan's own header comments declare (real example:
`wave-plans/assistant-channel/2026-09-13-handover-identity-critics2.plan`
declares round 2 in its first line; the "round 3 is SAFE" later in the same
line is about a different seat and is not the plan's round), else the plan
basename (`-fix` means round 2, `-r<n>` means round n), else 1. A round
number mentioned anywhere else in the plan text is never the plan's round.

## Running it

- `make ledger` rebuilds `logs/fleet-ledger.jsonl` from the logs (idempotent:
  a rebuild never duplicates a record), prints the per-round, per-PR,
  per-initiative and per-day rollups, and writes `logs/ledger.json`, which
  the Floor reads to put one ledger line on each INITIATIVES row (cost,
  elapsed, work share; cost unknown where it is). The per-day and per-PR
  rollups print seat hours (per-seat elapsed, summed) and wall hours (first
  start to last end) as separate columns; work share is active time over
  seat time, seat by seat, so parallel seats add seat hours, never share,
  and the figure cannot pass 100%. A rollup whose seats are all cost unknown
  prints cost unknown, never a zero; a mixed rollup prints the known sum
  plus the count unknown.
- `make ledger-orchestrator DATE=2026-09-14 USD=41.20 NOTE="provider usage
  page"` appends a manual orchestrator reading marked `source: manual`.
  It survives rebuilds, appears in the rollup as its own line, and nothing
  uses it to cap, warn or throttle (owner decision 2026-09-14).
- `LEDGER_FLAGS=--no-gh` skips the PR lookup; skipped lookups are marked
  unverified in the ledger.

## What this means for the ledger

- Seat identity, times, waves, role, provider, requested model and outcome:
  the event stream, backstopped by the dispatch run log.
- Cost and tokens: the first-party result line only. In a dispatch run log a
  result line is read only inside a first-party (`claude`) seat section; a
  kimi or grok seat that quotes a result line is narrating, not recording,
  and such a line is never read as a cost. Fallback when the run log is
  missing or names the wrong file: every seat log filed under the seat's
  repo and branch, both the collected copies in `logs/` and the seat log
  directory (`--seat-logs-dir`, default `~/dev/agent-logs`). One result line
  across all candidates is used directly; with several, the line whose
  `duration_ms` matches the seat's recorded `duration_s` wins; anything
  ambiguous stays cost unknown. Kimi and grok seats, and first-party seats
  that died mid-stream, are marked cost unknown and never counted as zero.
- PR: resolved from the branch with `gh` when available; skipped lookups are
  marked unverified, never guessed.
