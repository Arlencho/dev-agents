# Live seat activity on the Ops Floor

Branch `feat/floor-queue`, two commits: `d21a76f` (feature), `c8ce2a6` (replay cut).
PR #68 (same branch), evidence pasted as a PR comment.

## Built

1. **`providers/claude/launch.sh`**: print mode with streamed JSON output
   (`-p --output-format stream-json --verbose`), so the stream arrives line by
   line instead of one block at the end. `exec 0</dev/null` detaches stdin: the
   worker shell is still reading the dispatch script from the same descriptor,
   and print mode takes the prompt from argv.
2. **`providers/lib.sh`** `run_and_classify`: optional pass-through filter
   between the CLI and the same `tee`:
   `"$@" 2>&1 | "${reader[@]}" | tee "$tmp"`. `AGENT_STREAM_READER` selects it;
   no reader, no `python3`, or an unreadable path degrade to `cat`.
   `cmd_exit="${PIPESTATUS[0]}"` is unchanged, so the exit code and the
   rate-cap / auth classification below it are untouched.
3. **`scripts/seat-progress.py`** (new, stdlib only): writes every byte of the
   stream back to stdout, folds tool calls into four counts, and emits
   `seat_progress` through `scripts/fleet-events.sh emit` on every tool call
   plus at most once per 15s while the stream moves without tool calls, plus a
   closing event at EOF. Payload: tool name, one repo-relative path (anything
   resolving outside the repo becomes the literal `outside-repo`),
   `files_edited` / `commands_run` / `tests_run` / `commits_made`, and a phase
   word (`reading`, `reviewing`, `editing`, `testing`, `committing`). Exits 0
   always; on an internal error it falls back to a dumb copy so the log is
   never truncated.
4. **`scripts/run-remote.sh`**: ships the reader plus the emitter to
   `~/dev/agent-runtime/`, and passes `AGENT_STREAM_READER`, `FLEET_EVENTS_SH`,
   `FLEET_EVENTS_FILE`, `FLEET_DISPATCH_ID`, `SEAT_TASK_ID`, `SEAT_AGENT`,
   `SEAT_REPO_DIR` to the launcher for a **local worker only**.
   **`scripts/dispatch.sh`**: passes `AGENT_TASK_ID` + the stream file down.
5. **`scripts/fleet-events.sh`**: the four count keys added to
   `_FE_NUMERIC_KEYS` so they land as JSON numbers.
6. **`scripts/desk_live.py`**: `seats[].activity` from the newest
   `seat_progress` (never creates a lane, re-marks an absolute or escaping path
   as `outside-repo`); replay cuts reader lines on `ts`.
7. **Floor**: one activity line under each live seat, phase word as the
   in-flight pill (`templates/experience/floor.js`, `site.css`, and the static
   snapshot `scripts/experience_build.py` `_live_activity_line`).
8. **`docs/experience-data.md`**: the event, its cadence, its redaction law,
   the per-writer `seq` caveat, and `activity` in the `live/1` table.
9. **Tests**: `tests/run-desk-live-tests.sh` Part G (reader) and Part H
   (wiring); `tests/run-launcher-tests.sh` row 18 re-runs all four exit
   classifications with the reader in the pipeline.

## Decisions

- **Reader in the launcher pipeline, not dispatcher side.** `run_and_classify`
  already owns the one place where errexit is toggled and `PIPESTATUS[0]` is
  read, so inserting a filter there cannot disturb the exit contract.
  Dispatcher side would have meant rewriting `REMOTE_EXIT=$?`.
- **Emitting is local-worker only.** The stream file lives on the dispatcher; a
  true remote host would append to a path that is not the Floor's. Remote runs
  degrade to a plain pass-through with an unchanged log.
- **Command lines are inspected, never emitted.** Telling a test run from a
  commit needs the command string in process. Nothing derived from it leaves
  except two integers.
- **Phase is a monotone ladder over the counts** (commits, else tests, else
  edits, else commands, else nothing yet). It says how far the seat has got,
  not what its last keystroke was. Documented as such.
- **`seq` is per writer.** Two processes now append to one stream. Rather than
  make the dispatcher pay a `wc -l` per event (and break the Part A seq
  assertions), the doc states the caveat and the replay scrub cuts reader lines
  on `ts` against the newest kept spine event.
- The verification run pinned a cheap model tier in the **tmp dispatcher copy
  only** (`/tmp/floorcheck/dispatcher/config/routing.yaml`), never in the repo.

## Do not repeat

- Do not make the target repo a clone whose only local branch is the feature
  branch: `run-remote.sh` does `git checkout main`, and a clone copies only the
  source's local branches, so the first dispatch died with
  `error: pathspec 'main' did not match any file(s) known to git`. Give the
  scratch repo a local `main` first.
- Do not run `scripts/experience-build.sh` to capture a live Floor snapshot:
  the data step does `shutil.rmtree(data_dir)` and deletes `data/live.json`, so
  the page renders the empty teach shell. Run `desk_live.py --once` and then
  `scripts/experience_build.py` (the HTML step) only.
- Do not assert redaction by grepping the whole projection file: `recent_events`
  carries raw event lines by design, so a hand-written stream line will show up
  there. Assert on the seat object the Floor renders.
- The agent log lives on the worker during a run
  (`~/dev/agent-logs/<repo>-<branch>-<ts>.log`) and is collected into
  `<dispatcher>/logs/` afterwards. Sample the worker path while the run is live.

## Evidence

Agent log growing during one real one-seat dispatch (localhost worker, sampled
every 5s against `~/dev/agent-logs/dev-agents-scratch-chore-live-check-*.log`):

```
15:51:00Z   6568 bytes
15:51:05Z  12348 bytes
15:51:10Z  20411 bytes
15:51:16Z  25078 bytes
```

`seat_progress` in the stream (second dispatch,
`logs/fleet-events/20260912-155205-dev-agents-scratch.jsonl`):

```
seq6   phase=reading     tool=None   path=None          edited=0 cmd=0 test=0 commit=0
seq7   phase=reading     tool=Read   path=README.md     edited=0 cmd=0 test=0 commit=0
seq8   phase=reading     tool=Read   path=Makefile      edited=0 cmd=0 test=0 commit=0
seq9   phase=reviewing   tool=Bash   path=None          edited=0 cmd=1 test=0 commit=0
seq12  phase=editing     tool=Write  path=live-check.md edited=1 cmd=2 test=0 commit=0
seq14  phase=committing  tool=Bash   path=None          edited=1 cmd=4 test=0 commit=1
```

Floor rendered while the seat was still in flight (`status: running`,
`staleness: live`, `view: live`), from `site/experience/live/index.html`:

```html
<div class="nowact"><span class="st st-run">editing</span><span class="faint">Bash</span><span class="mono faint">1 edited · 3 cmd · 0 test · 0 commit</span></div>
```

Exit codes and outcome:

```
DISPATCH_EXIT=0
seat_exit ... "status":"success","exit":0,"duration_s":57
collected log: 65 lines, 143837 bytes, 0 non-JSON lines,
final line type=result subtype=success is_error=False
redaction over the stream: "sleep 8" 0 hits, task text 0 hits, "git commit" 0 hits
```

Test suites:

```
tests/run-launcher-tests.sh   26 passed, 0 failed
  claude / success + stream reader (exit 0)
  claude / fail    + stream reader (exit 1)
  claude / ratecap + stream reader (exit 75)
  claude / noauth  + stream reader (exit 69)
tests/run-desk-live-tests.sh  209 passed, 0 failed
make test                     All test suites passed.
shellcheck -S warning         no new findings (two pre-existing SC1090)
```

## Open questions

- Should `seat_progress` also refresh `last_heartbeat_ts`? It is a genuine sign
  of life, but quiet detection and the "last heartbeat" label were left alone
  on purpose. A one-line change in the projector if wanted.
- Remote workers get no live activity today. Shipping the events over the ssh
  stdout the dispatcher already reads would cover them; that is a separate
  change to the `REMOTE_EXIT=$?` path.

## Independent re-verification (second pass, same branch, no code change)

The branch was already built and pushed (`0 0` against `origin/feat/floor-queue`,
clean tree). This pass re-proved the claims above from scratch instead of
trusting them, and changed no code.

Streaming: a stand-in CLI pushing stream-json lines with real delays, run
through the real `run_and_classify` with `AGENT_STREAM_READER` set, log sampled
while in flight:

```
t+2s: 149 bytes    t+5s: 519 bytes    t+8s: 802 bytes    end: 911 bytes
```

`seat_progress` walking the phase ladder in a real event file:

```
phase=reading     tool=Read   path=README.md      0 edit 0 cmd 0 test 0 commit
phase=reading     tool=Read   path=outside-repo   0 edit 0 cmd 0 test 0 commit
phase=editing     tool=Write  path=docs/x.md      1 edit 0 cmd 0 test 0 commit
phase=testing     tool=Bash                       1 edit 1 cmd 1 test 0 commit
phase=committing  tool=Bash                       1 edit 2 cmd 1 test 1 commit
```

Redaction canaries planted in message text, an argument value, a command line
and a commit message, counted over the whole event stream and over the log:

```
event stream: SECRET_PROMPT_TEXT_CANARY 0, CANARY_ARG_VALUE 0, CANARY_CMDLINE 0,
              CANARY_COMMIT_MSG 0, /etc/hosts 0, /Users/... 0
agent log:    all three canaries present (pass-through intact, 9 lines/911 bytes)
```

Exit contract, real launcher process, reader active vs absent (identical):

```
success 0 / fail 1 / ratecap 75 / noauth 69     with reader     all PASS
success 0 / fail 1 / ratecap 75 / noauth 69     without reader  all PASS
```

Projection and Floor from that same stream:

```
seat task_id=0 agent=devops status=running
activity: {"phase":"committing","tool":"Bash","path":null,"files_edited":1,
           "commands_run":2,"tests_run":1,"commits_made":1,"ts":"...T16:00:10Z"}
<div class="nowact"><span class="st st-run">committing</span><span class="faint">Bash</span><span class="mono faint">1 edited · 2 cmd · 1 test · 1 commit</span></div>
```

Gates: `tests/run-launcher-tests.sh` 26 passed 0 failed (row 18 is the four
classifications with the reader in the pipeline); `tests/run-desk-live-tests.sh`
209 passed 0 failed; `make test` all suites passed; shellcheck -S warning gives
5 findings at base `12a4e48` and 5 at HEAD, so no new findings.

Harness note for the next agent: do not call `run_and_classify` from a shell
where you then read `$?`. The function turns errexit back on at the end of its
body rather than restoring the prior state, so a nonzero `return` kills your
calling shell before it can read the code. Run the launcher as a process the way
`tests/run-launcher-tests.sh` does.
