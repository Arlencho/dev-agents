#!/usr/bin/env bash
# Queue runner: one tick of the Ops Floor queue. Meant to run every minute from
# launchd (docs/queue-runner-launchd.plist, make queue-runner-install); safe to
# run by hand at any time.
#
# What one tick does:
#   1. If QUEUE_RUNNER_PAUSE=1 is set, nothing. That one variable is the pause
#      switch: launchctl setenv QUEUE_RUNNER_PAUSE 1 / launchctl unsetenv ...
#   2. Reads logs/fleet-queue.json in declared order. A plan is a candidate when
#      its status is "queued" and its blocked reason is empty (queue.sh block /
#      unblock set and clear it).
#   3. A repo is busy when a dispatch is running for it: a live pid in
#      logs/dispatch-runs/*.pid for that repo (detached runs), or a live pid in
#      a branch lock under ~/dev/dispatch-locks/<repo>/ (any local run, attached
#      ones included). One run per repo at a time; the per-branch locks in
#      dispatch.sh stay the safety net beneath this rule.
#   4. The first candidate whose repo is not busy is started with
#      dispatch.sh <repo-url> <plan> --detach --auto <flags>. The repo URL and
#      the flags come from the plan's own "# DISPATCH: ./scripts/dispatch.sh
#      <repo-url> <plan> <flags>" header line, the line every plan already
#      carries for a human to copy. At most one start per tick, so at most one
#      per minute under launchd.
#   5. What it started (or why a start failed) goes to
#      logs/dispatch-runs/queue-runner.log, next to the run logs.
#
# A plan that cannot be started (no plan file, no DISPATCH line, dispatch.sh
# refused) is marked blocked in the queue with the reason, so the runner does
# not retry it every minute and the reason shows in make queue-list. Fix the
# cause, then: ./scripts/queue.sh unblock <plan>.
#
# Flags:
#   --dry-run    say what would start, start nothing, mark nothing
#   --verbose    also print the idle / paused / busy reasoning (a tty gets this
#                by default; launchd's log gets only starts and failures)
#
# Exit 0 on every tick that ran, including an idle one; 1 only when the runner
# itself could not do its job (no python3, unreadable queue).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DISPATCH="$SCRIPT_DIR/dispatch.sh"
QUEUE="$SCRIPT_DIR/queue.sh"
QUEUE_FILE="${FLEET_QUEUE_FILE:-$REPO_DIR/logs/fleet-queue.json}"
RUNS_DIR="${DISPATCH_RUNS_DIR:-$REPO_DIR/logs/dispatch-runs}"
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
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "queue-runner.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

say() { [ "$VERBOSE" = true ] && echo "$*"; return 0; }
# Starts and failures: the runner log and stdout both.
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

# One tick at a time: a tick is short (dispatch --detach returns at once), but
# launchd does not wait for the previous run before firing the next.
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
# blocked reason. The queue's own render stays the human view.
candidates="$(python3 - "$QUEUE_FILE" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError) as exc:
    sys.stderr.write("queue-runner: cannot read queue: %s\n" % exc)
    sys.exit(1)
for entry in data.get("entries") or []:
    if (entry.get("status") or "queued") != "queued":
        continue
    if (entry.get("blocked") or "").strip():
        continue
    repo = (entry.get("repo") or "").strip()
    plan = (entry.get("plan") or "").strip()
    if repo and plan:
        print("%s\t%s" % (repo, plan))
PY
)" || exit 1

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
