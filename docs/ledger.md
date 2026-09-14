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
line 786 (also embedded in `logs/dispatch-runs/20260913-132942-dev-agents-32845.log`).

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

The same result line appears in three places: the seat's own file in
`~/dev/agent-logs/`, its copy collected into `logs/` of the dispatching
checkout, and inline in `logs/dispatch-runs/<dispatch id>.log` between the
seat's `Starting claude launcher for agent <role>` line and its
`=== Agent completed on localhost ===` line. The ledger counts it once.

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
historical seat. Round is taken from a `FIX-ROUND:` header when present,
else from a `ROUND n` mention in the plan, else from the plan basename
(`-fix` means round 2, `-r<n>` means round n), else 1.

## Running it

- `make ledger` rebuilds `logs/fleet-ledger.jsonl` from the logs (idempotent:
  a rebuild never duplicates a record), prints the per-round, per-PR,
  per-initiative and per-day rollups, and writes `logs/ledger.json`, which
  the Floor reads to put one ledger line on each INITIATIVES row (cost,
  elapsed, work share; cost unknown where it is).
- `make ledger-orchestrator DATE=2026-09-14 USD=41.20 NOTE="provider usage
  page"` appends a manual orchestrator reading marked `source: manual`.
  It survives rebuilds, appears in the rollup as its own line, and nothing
  uses it to cap, warn or throttle (owner decision 2026-09-14).
- `LEDGER_FLAGS=--no-gh` skips the PR lookup; skipped lookups are marked
  unverified in the ledger.

## What this means for the ledger

- Seat identity, times, waves, role, provider, requested model and outcome:
  the event stream, backstopped by the dispatch run log.
- Cost and tokens: the first-party result line only, parsed from the seat's
  section of the dispatch run log (fallback: the seat's own log file when it
  holds exactly one result line). Kimi and grok seats, and first-party seats
  that died mid-stream, are marked cost unknown and never counted as zero.
- PR: resolved from the branch with `gh` when available; skipped lookups are
  marked unverified, never guessed.
