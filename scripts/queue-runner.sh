#!/usr/bin/env bash
# Queue runner: one tick of the Ops Floor queue. Meant to run every minute from
# launchd (docs/queue-runner-launchd.plist, make queue-runner-install); safe to
# run by hand at any time.
#
# What one tick does:
#   1. If QUEUE_RUNNER_PAUSE=1 is set, nothing. That one variable is the pause
#      switch: launchctl setenv QUEUE_RUNNER_PAUSE 1 / launchctl unsetenv ...
#   2. Settles what ended (scripts/queue_loop.py settle): for every detached
#      dispatch that has ended since the last tick, reads the critic verdicts
#      on its PR (the first-line convention, parsed by scripts/desk_live.py):
#        - every critic seat posted SAFE-TO-MERGE or APPROVE-MERGE, the checks
#          are green and the merge state is CLEAN: with QUEUE_LOOP_LAND on
#          (default off, until the landing gate is proven) lands the PR through
#          scripts/land.sh (a draft is marked ready first, and the pass that
#          marked ready never lands: the next tick re-reads the head); off, the
#          runner makes no write call at all and the PR becomes a stop of kind
#          ready_to_merge with the action merge;
#        - a critic posted BLOCK-FIX and the plan is not itself a fix plan:
#          writes <plan>-fix1.plan next to the original (one producer seat of
#          the same role and branch with the comment quoted in full plus "fix
#          every finding and add a test per finding", then the same critic seat
#          for round 2), queues it first with AFTER the original;
#        - anything else (a second BLOCK-FIX, BLOCK-ESCALATE, BLOCK-CLOSE, a
#          verdict the runner does not act on, a silent critic, red checks, a
#          merge state that is not clean, a refused merge, no PR): a stop. One
#          line in logs/fleet-stops.jsonl with the critic sentence and one
#          action, which the Floor reads. Never a merge.
#   3. Memory guard (scripts/queue_loop.py guard): reads free memory and swap
#      (vm_stat, sysctl vm.swapusage). Under the thresholds in
#      config/queue-runner.yaml (defaults: 50 percent free, 3.5 GB swap) it
#      starts nothing, says why once per change of state, and writes the
#      reason into the queue (hold) and the stops file. It resumes by itself
#      when the numbers recover. It never kills anything.
#   4. Reads logs/fleet-queue.json in declared order. A plan is a candidate
#      when its status is "queued", its blocked reason is empty (queue.sh block
#      / unblock set and clear it), and, when its header carries
#      "# AFTER: <plan>", the named plan has a dispatch_end with outcome landed
#      (its reason is written into the entry as "waiting:" until then, and
#      cleared by the runner itself).
#   5. A repo is busy when a dispatch is running for it: a live pid in
#      logs/dispatch-runs/*.pid for that repo (detached runs), or a live pid in
#      a branch lock under ~/dev/dispatch-locks/<repo>/ (any local run, attached
#      ones included). One run per repo at a time; the per-branch locks in
#      dispatch.sh stay the safety net beneath this rule.
#   6. The first candidate whose repo is not busy is started with
#      dispatch.sh <repo-url> <plan> --detach --auto <flags>. The repo URL and
#      the flags come from the plan's own "# DISPATCH: ./scripts/dispatch.sh
#      <repo-url> <plan> <flags>" header line, the line every plan already
#      carries for a human to copy. At most one start per tick, so at most one
#      per minute under launchd.
#   7. What it started, settled, held or stopped (or why a start failed) goes
#      to logs/dispatch-runs/queue-runner.log, next to the run logs.
#
# A plan that cannot be started (no plan file, no DISPATCH line, dispatch.sh
# refused) is marked blocked in the queue with the reason, so the runner does
# not retry it every minute and the reason shows in make queue-list. Fix the
# cause, then: ./scripts/queue.sh unblock <plan>.
#
# Flags:
#   --dry-run    say what would settle, hold and start; write nothing, start
#                nothing, mark nothing, land nothing
#   --verbose    also print the idle / paused / busy reasoning (a tty gets this
#                by default; launchd's log gets only starts, stops and failures)
#
# Exit 0 on every tick that ran, including an idle one; 1 only when the runner
# itself could not do its job (no python3, unreadable queue).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
QUEUE="$SCRIPT_DIR/queue.sh"
LOOP="$SCRIPT_DIR/queue_loop.py"
LAND="${QUEUE_RUNNER_LAND:-$SCRIPT_DIR/land.sh}"
QUEUE_FILE="${FLEET_QUEUE_FILE:-$REPO_DIR/logs/fleet-queue.json}"
RUNS_DIR="${DISPATCH_RUNS_DIR:-$REPO_DIR/logs/dispatch-runs}"
EVENTS_DIR="${FLEET_EVENTS_DIR:-$REPO_DIR/logs/fleet-events}"
STOPS_FILE="${FLEET_STOPS_FILE:-$REPO_DIR/logs/fleet-stops.jsonl}"
CONFIG_FILE="${QUEUE_RUNNER_CONFIG:-$REPO_DIR/config/queue-runner.yaml}"
RUNNER_LOG="$RUNS_DIR/queue-runner.log"
# Same base as the dispatch lock in dispatch.sh: machine-global, per user.
FLEET_HOME="${FLEET_HOME:-$HOME/dev}"
LOCK_DIR="${LOCK_DIR:-$FLEET_HOME/dispatch-locks}"

DRY_RUN=false
VERBOSE=false
[ -t 1 ] && VERBOSE=true
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true; VERBOSE=true ;;
        --verbose|-v) VERBOSE=true ;;
        -h|--help)
            sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "queue-runner.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

say() { [ "$VERBOSE" = true ] && echo "$*"; return 0; }
# Starts, stops and failures: the runner log and stdout both.
note() {
    local line
    line="$(date -u +%FT%TZ) $*"
    echo "$line"
    if [ "$DRY_RUN" != true ]; then
        mkdir -p "$RUNS_DIR" 2>/dev/null && printf '%s\n' "$line" >> "$RUNNER_LOG" 2>/dev/null || true
    fi
}

if [ "${QUEUE_RUNNER_PAUSE:-0}" = "1" ]; then
    say "queue-runner: paused (QUEUE_RUNNER_PAUSE=1)"
    exit 0
fi
if [ ! -f "$QUEUE_FILE" ]; then
    say "queue-runner: no queue at $QUEUE_FILE"
    exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "queue-runner: python3 not found on PATH" >&2; exit 1; }

# One tick at a time: a tick is usually short (dispatch --detach returns at
# once), but a landing waits on land.sh, and launchd does not wait for the
# previous run before firing the next.
mkdir -p "$RUNS_DIR" 2>/dev/null || { echo "queue-runner: cannot create $RUNS_DIR" >&2; exit 1; }
TICK_LOCK="$RUNS_DIR/queue-runner.lock"
if ! mkdir "$TICK_LOCK" 2>/dev/null; then
    holder="$(cat "$TICK_LOCK/pid" 2>/dev/null || echo "")"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        say "queue-runner: another tick (pid $holder) is still running"
        exit 0
    fi
    rm -rf "$TICK_LOCK"
    mkdir "$TICK_LOCK" 2>/dev/null || { echo "queue-runner: cannot take $TICK_LOCK" >&2; exit 1; }
fi
echo "$$" > "$TICK_LOCK/pid"
trap 'rm -rf "$TICK_LOCK"' EXIT

# ---- the loop helper -----------------------------------------------------------
# scripts/queue_loop.py prints tab-separated lines: "note<TAB>text" goes to the
# runner log, "say<TAB>text" to verbose output, anything else is a result the
# caller reads (guard state, candidates).
LOOP_ARGS=(--queue "$QUEUE_FILE" --runs-dir "$RUNS_DIR" --events-dir "$EVENTS_DIR"
           --stops "$STOPS_FILE" --config "$CONFIG_FILE" --queue-sh "$QUEUE" --land "$LAND")
[ "$DRY_RUN" = true ] && LOOP_ARGS+=(--dry-run)
loop() { # <subcommand>  -> relays note/say; results land in $TICK_LOCK/<subcommand>.out
    local out rc lvl msg result="$TICK_LOCK/$1.out"
    : > "$result"
    out="$(cd "$REPO_DIR" && python3 "$LOOP" "$1" "${LOOP_ARGS[@]}" 2>&1)"
    rc=$?
    while IFS=$'\t' read -r lvl msg; do
        [ -n "$lvl" ] || continue
        case "$lvl" in
            note) note "$msg" ;;
            say) say "$msg" ;;
            guard|cand) printf '%s\t%s\n' "$lvl" "$msg" >> "$result" ;;
            *) say "queue_loop: $lvl${msg:+ $msg}" ;;
        esac
    done <<< "$out"
    return "$rc"
}

# ---- settle what ended --------------------------------------------------------------
# Verdicts, one fix round, landings and stops for every detached run that has
# ended since the last tick. Runs before the guard: landing and queueing start
# nothing, so low memory must not hold them back.
loop settle || note "queue_loop settle failed; will try again next tick"

# ---- memory guard ---------------------------------------------------------------
loop guard
GUARD_STATE="$(awk -F'\t' '$1 == "guard" { print $2 }' "$TICK_LOCK/guard.out" | tail -n 1)"

# ---- who is busy -------------------------------------------------------------
# Space-separated list of repo slugs with a live dispatch. bash 3.2 friendly.
BUSY=" "
busy_add() { case "$BUSY" in *" $1 "*) ;; *) BUSY="$BUSY$1 " ;; esac; }
is_busy() { case "$BUSY" in *" $1 "*) return 0 ;; esac; return 1; }

for pf in "$RUNS_DIR"/*.pid; do
    [ -f "$pf" ] || continue
    { read -r ppid; read -r prepo; } < "$pf"
    if [ -n "${ppid:-}" ] && kill -0 "$ppid" 2>/dev/null; then
        busy_add "${prepo:-unknown}"
        say "busy: $prepo (detached dispatch pid $ppid, $(basename "$pf" .pid))"
    fi
done
for lf in "$LOCK_DIR"/*/*.lock; do
    [ -f "$lf" ] || continue
    lpid="$(sed -n '1p' "$lf" 2>/dev/null || echo "")"
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
        lrepo="$(basename "$(dirname "$lf")")"
        busy_add "$lrepo"
        say "busy: $lrepo (branch lock $(basename "$lf") held by pid $lpid)"
    fi
done

# ---- candidates, in declared order -------------------------------------------
# One line per candidate: <repo><TAB><plan>. Only queued entries with an empty
# blocked reason whose AFTER header, if any, is satisfied. The queue's own
# render stays the human view.
loop candidates || exit 1
candidates="$(awk -F'\t' '$1 == "cand" { print $2 "\t" $3 }' "$TICK_LOCK/candidates.out")"

if [ "$GUARD_STATE" = "active" ]; then
    say "queue-runner: memory guard active, starting nothing this tick"
    exit 0
fi
if [ -z "$candidates" ]; then
    say "queue-runner: nothing queued and unblocked"
    exit 0
fi

# ---- the plan's own dispatch line ---------------------------------------------
# "# DISPATCH: ./scripts/dispatch.sh <repo-url> <plan> [flags]". Sets
# PLAN_REPO_URL and PLAN_FLAGS (flags after the plan, minus --detach and
# --review: the review gate needs a person at the terminal).
read_dispatch_line() { # <plan file>
    PLAN_REPO_URL=""
    PLAN_FLAGS=()
    local line words w i
    line="$(grep -m1 -E '^#[[:space:]]*DISPATCH:' "$1" 2>/dev/null | sed -E 's/^#[[:space:]]*DISPATCH:[[:space:]]*//')"
    [ -n "$line" ] || return 1
    read -r -a words <<< "$line"
    # Everything up to and including the dispatch.sh token is the command.
    i=0
    while [ "$i" -lt "${#words[@]}" ]; do
        case "${words[$i]}" in
            *dispatch.sh) i=$((i + 1)); break ;;
        esac
        i=$((i + 1))
    done
    [ "$i" -lt "${#words[@]}" ] || return 1
    PLAN_REPO_URL="${words[$i]}"
    i=$((i + 2))   # skip the plan path
    while [ "$i" -lt "${#words[@]}" ]; do
        w="${words[$i]}"
        case "$w" in
            --detach|--review) ;;
            --retries) PLAN_FLAGS+=("$w" "${words[$((i + 1))]:-}"); i=$((i + 1)) ;;
            --*) PLAN_FLAGS+=("$w") ;;
        esac
        i=$((i + 1))
    done
    [ -n "$PLAN_REPO_URL" ]
}

block_entry() { # <plan> <reason>
    [ "$DRY_RUN" = true ] && return 0
    "$QUEUE" block "$1" "$2" >/dev/null 2>&1 || true
}

# ---- start at most one -----------------------------------------------------------
cd "$REPO_DIR" || exit 1
started=false
while IFS=$'\t' read -r repo plan; do
    [ -n "$repo" ] || continue
    if is_busy "$repo"; then
        say "skip: $plan ($repo is busy)"
        continue
    fi
    if [ ! -f "$plan" ]; then
        note "cannot start $plan for $repo: plan file not found; marked blocked"
        block_entry "$plan" "runner: plan file not found"
        continue
    fi
    if ! read_dispatch_line "$plan"; then
        note "cannot start $plan for $repo: no '# DISPATCH: ./scripts/dispatch.sh <repo-url> <plan> ...' header; marked blocked"
        block_entry "$plan" "runner: no DISPATCH header line in the plan"
        continue
    fi
    if [ "$DRY_RUN" = true ]; then
        note "would start: $DISPATCH $PLAN_REPO_URL $plan --detach --auto ${PLAN_FLAGS[*]+"${PLAN_FLAGS[*]}"}"
        started=true
        break
    fi
    out="$("$DISPATCH" "$PLAN_REPO_URL" "$plan" --detach --auto ${PLAN_FLAGS[@]+"${PLAN_FLAGS[@]}"} 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        note "cannot start $plan for $repo: dispatch.sh --detach exit $rc; marked blocked. Output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
        block_entry "$plan" "runner: dispatch --detach exit $rc, see logs/dispatch-runs/queue-runner.log"
        continue
    fi
    did="$(printf '%s\n' "$out" | sed -n 's/^dispatch id: *//p' | head -n 1)"
    dpid="$(printf '%s\n' "$out" | sed -n 's/^pid: *\([0-9]*\).*/\1/p' | head -n 1)"
    note "started $plan for $repo: dispatch ${did:-?} (pid ${dpid:-?}) via $PLAN_REPO_URL"
    started=true
    break
done <<< "$candidates"

[ "$started" = true ] || say "queue-runner: candidates present, every repo busy"
exit 0
