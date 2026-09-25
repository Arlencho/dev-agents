#!/usr/bin/env bash
# Requires bash 4+ (associative arrays) — macOS /bin/bash is 3.2; use Homebrew bash.
set -euo pipefail
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERROR: dispatch.sh needs bash >= 4 (associative arrays). Found: ${BASH_VERSION:-unknown}"
    echo "Install: brew install bash — or run: /opt/homebrew/bin/bash scripts/dispatch.sh ..."
    exit 1
fi

# Dispatch agent tasks to worker machines from a wave plan.
# Reads worker config from config/workers.yaml.
#
# Usage:
#   ./scripts/dispatch.sh <repo-url> <plan-file> [flags]
#   ./scripts/dispatch.sh <repo-url> --interactive [flags]
#
# Plan file format (one task per line):
#   <agent> | <task description> | [branch-name]
#
# Wave-aware format (tasks grouped by wave number):
#   1 | <agent> | <task description> | [branch-name]
#   1 | <agent> | <task description> | [branch-name]
#   2 | <agent> | <task description> | [branch-name]
#
# Flags:
#   --auto                     Auto-continue between waves (no prompt)
#   --retries N                Max retries per task (default: 2)
#   --retry-on-different-worker Retry failed tasks on a different worker
#   --skip-auth-preflight      Skip vendor session preflight (not recommended)
#   --no-wait                  Exit 9 instead of queueing when another dispatch
#                              already holds a lock on one of this plan's branches
#   --detach                   Re-exec as a session leader (fork + setsid, stdin
#                              from /dev/null, HUP ignored), all output to
#                              logs/dispatch-runs/<dispatch id>.log, pid file next
#                              to it; print the id and the log path and return.
#                              Implies --auto. Check: scripts/dispatch-status.sh
#
# Example plan.txt:
#   1 | go-backend | implement payment service | feat/payments-svc
#   1 | db-architect | create migration | feat/payments-db
#   2 | web-frontend | build checkout page | feat/payments-ui
#   3 | test-engineer | add tests | feat/payments-tests
#
# Backward compatible — lines without a wave prefix are treated as wave 1.

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$REPO_DIR/config/workers.yaml"
ROUTING_CONFIG="$REPO_DIR/config/routing.yaml"
LOGS_DIR="$REPO_DIR/logs"
WAVE_PLANS_DIR="$REPO_DIR/wave-plans"
NOTIFY_SCRIPT="$SCRIPT_DIR/notify.sh"

# Seat resolution (get_provider / get_failover_chain / get_model) is shared with
# flow.sh, sync-providers.sh and the routing tests. CONFIG and ROUTING_CONFIG are
# already set above, so the library picks them up rather than its own defaults.
# shellcheck source=scripts/config-lib.sh
. "$SCRIPT_DIR/config-lib.sh"

# Fleet Desk Phase B — append-only event stream for the Ops Floor.
# Best-effort and opt-out (FLEET_EVENTS=0); a missing library never blocks a
# dispatch, so every call site can assume fleet_event exists.
if [ -f "$SCRIPT_DIR/fleet-events.sh" ]; then
    # shellcheck source=scripts/fleet-events.sh
    . "$SCRIPT_DIR/fleet-events.sh"
else
    fleet_events_init() { :; }
    fleet_event() { :; }
fi

# Fleet Desk: the Ops Floor queue (logs/fleet-queue.json). The queue is the
# orchestrator's declared order; keeping it current must be the machine's job,
# not memory, so a dispatch marks its own plan running and settles it on the way
# out. Same law as fleet-events: best effort, never blocking. Every failure mode
# (missing script, unwritable logs dir, busy lock, no python3) is swallowed, so a
# dispatch is never killed by its own bookkeeping. Opt-out: FLEET_QUEUE=0.
fleet_queue() {
    if [ "${FLEET_QUEUE:-1}" = "0" ]; then
        return 0
    fi
    if [ -x "$SCRIPT_DIR/queue.sh" ]; then
        "$SCRIPT_DIR/queue.sh" "$@" >/dev/null 2>&1 || true
    fi
    return 0
}

# --------------------------------------------------
# Usage
# --------------------------------------------------
usage() {
    echo "Usage: dispatch.sh <repo-url> <plan-file|--interactive> [flags]"
    echo ""
    echo "Flags:"
    echo "  --auto                       Auto-continue between waves (no prompt)"
    echo "  --retries N                  Max retries per task (default: 2)"
    echo "  --review                     Run autoplan review before dispatching"
    echo "  --retry-on-different-worker  Retry failed tasks on a different worker"
    echo "  --skip-auth-preflight        Skip vendor CLI session preflight (default: on)"
    echo "  --no-wait                    Do not queue behind another dispatch on one of this"
    echo "                               plan's branches; exit 9 immediately if a lock is held"
    echo "  --detach                     Run as a session leader in the background: output to"
    echo "                               logs/dispatch-runs/<dispatch id>.log, pid file beside it,"
    echo "                               prints the id and returns (implies --auto)"
    echo ""
    echo "Plan file format:"
    echo "  [wave] | agent | task description | [branch-name]"
    exit 1
}

# --------------------------------------------------
# Parse arguments
# --------------------------------------------------
if [ $# -lt 2 ]; then
    usage
fi

REPO_URL="$1"
PLAN_SOURCE="$2"
shift 2

AUTO_CONTINUE=false
MAX_RETRIES=2
RETRY_DIFFERENT_WORKER=false
REVIEW_PLAN=false
SKIP_AUTH_PREFLIGHT=false
NO_WAIT=false
DETACH=false
# The flags a detached child is re-executed with: everything but --detach
# itself and --review (the review gate runs in the foreground, before the fork).
PASS_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)
            AUTO_CONTINUE=true
            PASS_ARGS+=("$1")
            shift
            ;;
        --retries)
            MAX_RETRIES="${2:?--retries requires a number}"
            PASS_ARGS+=("$1" "$2")
            shift 2
            ;;
        --review)
            REVIEW_PLAN=true
            shift
            ;;
        --retry-on-different-worker)
            RETRY_DIFFERENT_WORKER=true
            PASS_ARGS+=("$1")
            shift
            ;;
        --skip-auth-preflight)
            SKIP_AUTH_PREFLIGHT=true
            PASS_ARGS+=("$1")
            shift
            ;;
        --no-wait)
            NO_WAIT=true
            PASS_ARGS+=("$1")
            shift
            ;;
        --detach)
            DETACH=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown flag: $1${NC}"
            usage
            ;;
    esac
done

# --------------------------------------------------
# Autoplan review gate
# --------------------------------------------------
if [ "$REVIEW_PLAN" = true ] && [ "$PLAN_SOURCE" != "--interactive" ]; then
    echo "Running autoplan review..."
    "$SCRIPT_DIR/autoplan.sh" "$PLAN_SOURCE" || { echo "Plan review failed."; exit 1; }
    echo ""
fi

# --------------------------------------------------
# Detached mode: re-exec as a session leader, print the id, return
# --------------------------------------------------
# A dispatch started from a chat session or an ssh shell dies with that shell:
# the harness kills the process group of its background tasks when the turn
# ends, a hangup kills the terminal's session. --detach forks a child that
# calls setsid() so it is the leader of a session of its own with no controlling
# terminal, gives it /dev/null for stdin and the run log for stdout and stderr,
# ignores HUP in it (what nohup does), and execs this script again in it. Nothing
# aimed at the parent, its process group or its session reaches the child. The
# two steps are done in one perl call because macOS ships nohup but no setsid
# binary; perl and its POSIX module are on every mac and every worker.
#
# The parent returns at once with the dispatch id, the pid and the log path.
# The child runs the attached code path unchanged: same lock, same queue marks,
# same events, same notify hooks. It carries its id in DISPATCH_DETACHED so the
# event stream is opened under the id the parent already printed.
#
#   logs/dispatch-runs/<id>.log    everything the run prints
#   logs/dispatch-runs/<id>.pid    pid, repo slug, plan, start time, repo url
#                                  (one per line; the url is what the queue
#                                  runner asks gh about once the run has ended)
#   logs/dispatch-runs/<id>.exit   the run's exit code, written on its way out
#
# ---- dispatch-detach:begin (tests/run-detached-dispatch-tests.sh reads this block) ----
DISPATCH_RUNS_DIR="${DISPATCH_RUNS_DIR:-$LOGS_DIR/dispatch-runs}"

# Detached child only: leave the exit code where dispatch-status.sh reads it.
dispatch_run_note_exit() { # <rc>
    [ -n "${DISPATCH_DETACHED:-}" ] || return 0
    printf '%s\n' "$1" > "$DISPATCH_RUNS_DIR/$DISPATCH_DETACHED.exit" 2>/dev/null || true
}

if [ "$DETACH" = true ] && [ -z "${DISPATCH_DETACHED:-}" ]; then
    if [ "$PLAN_SOURCE" = "--interactive" ]; then
        echo -e "${RED}ERROR: --detach needs a plan file; a detached run has no stdin to read tasks from${NC}" >&2
        exit 1
    fi
    if [ ! -f "$PLAN_SOURCE" ]; then
        echo -e "${RED}ERROR: Plan file not found: $PLAN_SOURCE${NC}" >&2
        exit 1
    fi
    if ! command -v perl >/dev/null 2>&1; then
        echo -e "${RED}ERROR: --detach needs perl (fork + POSIX::setsid); it was not found on PATH${NC}" >&2
        exit 1
    fi
    if ! mkdir -p "$DISPATCH_RUNS_DIR" 2>/dev/null; then
        echo -e "${RED}ERROR: cannot create $DISPATCH_RUNS_DIR${NC}" >&2
        exit 1
    fi
    # Same shape as fleet-events.sh builds: <utc second>-<repo slug>-<pid>. The
    # pid is the parent's here; the id is an opaque token, nothing parses it.
    detach_slug="$(printf '%s' "$(basename "$REPO_URL" .git)" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
    DETACH_ID="$(date -u +%Y%m%d-%H%M%S)-${detach_slug:-fleet}-$$"
    DETACH_LOG="$DISPATCH_RUNS_DIR/$DETACH_ID.log"
    DETACH_PIDFILE="$DISPATCH_RUNS_DIR/$DETACH_ID.pid"
    : > "$DETACH_LOG"

    # perl prints the child's pid on stdout and exits; the child (already a
    # session leader, stdio moved off the pipe) execs this script.
    DETACH_PID="$(DISPATCH_DETACHED="$DETACH_ID" DISPATCH_RUN_LOG="$DETACH_LOG" perl -e '
        use strict; use POSIX qw(setsid);
        my $log = $ENV{DISPATCH_RUN_LOG};
        my $pid = fork();
        defined $pid or die "fork: $!\n";
        if ($pid) { print "$pid\n"; exit 0; }
        setsid() != -1 or die "setsid: $!\n";
        open(STDIN,  "<",  "/dev/null") or die "stdin: $!\n";
        open(STDOUT, ">>", $log)        or die "open $log: $!\n";
        open(STDERR, ">&", \*STDOUT)    or die "stderr: $!\n";
        $SIG{HUP} = "IGNORE";
        exec @ARGV or die "exec: $!\n";
    ' -- "$BASH" "$0" "$REPO_URL" "$PLAN_SOURCE" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"})"
    if [ -z "$DETACH_PID" ]; then
        echo -e "${RED}ERROR: could not fork the detached dispatch${NC}" >&2
        exit 1
    fi
    printf '%s\n%s\n%s\n%s\n%s\n' "$DETACH_PID" "${detach_slug:-fleet}" "$PLAN_SOURCE" "$(date -u +%FT%TZ)" "$REPO_URL" > "$DETACH_PIDFILE"

    echo "dispatch id: $DETACH_ID"
    echo "pid:         $DETACH_PID (session leader)"
    echo "log:         $DETACH_LOG"
    echo "check:       scripts/dispatch-status.sh $DETACH_ID"
    echo "wait:        scripts/dispatch-wait.sh $DETACH_ID [timeout seconds]"
    exit 0
fi

if [ -n "${DISPATCH_DETACHED:-}" ]; then
    # The child. No one is at the other end of stdin, so every wave gate would
    # read EOF: --auto is implied. Colors are noise in a log file.
    AUTO_CONTINUE=true
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
    # Until the run's own close-out traps are armed, an early exit (bad config,
    # no workers) still leaves its code behind for dispatch-status.sh.
    trap 'dispatch_run_note_exit $?' EXIT
    echo "Detached dispatch $DISPATCH_DETACHED: pid $$, session leader, started $(date -u +%FT%TZ)"
    echo "--auto implied (stdin is /dev/null)"
    echo ""
fi
# ---- dispatch-detach:end ----

# --------------------------------------------------
# Parse workers.yaml (simple grep-based — no yq dependency)
# --------------------------------------------------
get_workers() {
    # Extract worker entries (name + host pairs where role = worker)
    local in_machine=false
    local name="" host="" role=""
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
            # Save previous machine if it was a worker
            if [ "$in_machine" = true ] && [ "$role" = "worker" ] && [ -n "$name" ] && [ -n "$host" ]; then
                echo "$name|$host"
            fi
            name="${BASH_REMATCH[1]}"
            host="" role=""
            in_machine=true
        elif [[ "$line" =~ ^[[:space:]]*host:[[:space:]]*(.*) ]]; then
            host="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*role:[[:space:]]*(.*) ]]; then
            role="${BASH_REMATCH[1]}"
        fi
    done < "$CONFIG"
    # Don't forget last entry
    if [ "$in_machine" = true ] && [ "$role" = "worker" ] && [ -n "$name" ] && [ -n "$host" ]; then
        echo "$name|$host"
    fi
}

get_preferred_agents() {
    local target_name="$1"
    local in_target=false
    local in_preferred=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
            if [ "${BASH_REMATCH[1]}" = "$target_name" ]; then
                in_target=true
            else
                in_target=false
            fi
            in_preferred=false
        elif [ "$in_target" = true ] && [[ "$line" =~ ^[[:space:]]*preferred_agents: ]]; then
            in_preferred=true
        elif [ "$in_preferred" = true ] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*) ]]; then
            echo "${BASH_REMATCH[1]}"
        elif [ "$in_preferred" = true ] && ! [[ "$line" =~ ^[[:space:]]*- ]]; then
            in_preferred=false
        fi
    done < "$CONFIG"
}

get_max_agents() {
    local target_name="$1"
    local in_target=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
            if [ "${BASH_REMATCH[1]}" = "$target_name" ]; then
                in_target=true
            else
                in_target=false
            fi
        elif [ "$in_target" = true ] && [[ "$line" =~ ^[[:space:]]*max_agents:[[:space:]]*([0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    done < "$CONFIG"
    echo "4"  # default
}

# Cooldown window (minutes) from routing.yaml rate_caps:, default 60.
get_cooldown_minutes() {
    local v
    v=$(grep -A2 '^rate_caps:' "$ROUTING_CONFIG" 2>/dev/null \
        | grep -oE 'cooldown_minutes:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    echo "${v:-60}"
}

# True (0) if a vendor is currently cooling from a recent rate-cap.
provider_cooling() {
    local vendor="$1"
    local credit="$REPO_DIR/logs/provider-state/${vendor}.credit-until"
    local val
    val=$(cat "$credit" 2>/dev/null || true)
    if [ "${val:-0}" -gt "$(date +%s)" ]; then
        return 0
    fi
    local f="$REPO_DIR/logs/provider-state/${vendor}.cooldown"
    [ -f "$f" ] || return 1
    local ts now mins
    ts=$(cat "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    mins=$(get_cooldown_minutes)
    [ $((now - ts)) -lt $((mins * 60)) ]
}

# Pick the provider to run <agent>: primary (workers.yaml) then failover chain,
# skipping any vendor in the excluded set (already tried this task) or cooling.
# Short rate caps keep the legacy fallback when every candidate is cooling.
# Paid-credit cooldowns never fall back to an exhausted vendor.
resolve_provider() {
    local agent="$1"; shift
    local excluded="$*"
    local primary chain candidate ordered=""
    primary=$(get_provider "$agent")
    chain=$(get_failover_chain "$agent")
    for candidate in $primary $chain; do
        case " $ordered " in *" $candidate "*) ;; *) ordered="$ordered $candidate" ;; esac
    done
    for candidate in $ordered; do
        case " $excluded " in *" $candidate "*) continue ;; esac
        provider_cooling "$candidate" && continue
        echo "$candidate"; return 0
    done
    for candidate in $ordered; do
        case " $excluded " in *" $candidate "*) continue ;; esac
        local credit="$REPO_DIR/logs/provider-state/${candidate}.credit-until"
        local val
        val=$(cat "$credit" 2>/dev/null || true)
        if [ "${val:-0}" -gt "$(date +%s)" ]; then
            continue
        fi
        echo "$candidate"; return 0
    done
    local credit="$REPO_DIR/logs/provider-state/${primary}.credit-until"
    local val
    val=$(cat "$credit" 2>/dev/null || true)
    if [ "${val:-0}" -gt "$(date +%s)" ]; then
        return 1
    fi
    echo "$primary"
}

# --------------------------------------------------
# Seat reliability (issues #92 and #84): hung seats and provider limits
# --------------------------------------------------
# A seat that emits no model event for the quiet period is stopped by the
# launcher's watchdog with exit 124 and retried once, and a stop row names the
# seat and the quiet period. A tool call still open is work in flight: the
# watchdog holds the quiet period and applies the longer tool ceiling
# instead; a seat stopped on the ceiling gets a stop row naming the tool
# (run-remote leaves the reason in a file next to the hold files). A seat
# that exits 78 hit the provider's spend or
# session limit: it is marked held, not failed, the retry is not burned, and a
# stop row carries the provider and the reset time from the message. No seat
# starts on a held provider and model until a probe call succeeds; a passed
# probe releases the hold.
SEAT_QUIET_AFTER_S="${SEAT_QUIET_AFTER_S:-1800}"
SEAT_TOOL_CEILING_S="${SEAT_TOOL_CEILING_S:-5400}"
PROVIDER_STATE_DIR="$REPO_DIR/logs/provider-state"
FLEET_STOPS_FILE="${FLEET_STOPS_FILE:-$LOGS_DIR/fleet-stops.jsonl}"
declare -A STOP_OPENED=()   # stop key -> 1: one open row per state change per run
declare -A HUNG_TASKS=()    # idx -> 1 while a hung seat waits for its one retry
declare -A LIMIT_PROBE_CACHE=() LIMIT_PROBE_TS=()

# One row in the stops file (schema fleet-stops/1), the file the queue runner
# writes and the Floor folds by key. Machine-built sentences only, so the
# redaction law holds by construction; quotes and newlines still go.
stop_row() { # <key> <state> <kind> <sentence> <action>
    local key="$1" state="$2" kind="$3" sentence="$4" action="$5"
    sentence=$(printf '%s' "$sentence" | tr '"\\' '  ' | tr '\n' ' ')
    printf '{"schema":"fleet-stops/1","key":"%s","state":"%s","kind":"%s","sentence":"%s","action":"%s","ts":"%s"}\n' \
        "$key" "$state" "$kind" "$sentence" "$action" "$(date -u +%FT%TZ)" \
        >> "$FLEET_STOPS_FILE" 2>/dev/null || true
}

stop_open_once() { # <key> <kind> <sentence> <action>
    [ -n "${STOP_OPENED[$1]:-}" ] && return 0
    STOP_OPENED[$1]=1
    stop_row "$1" open "$2" "$3" "$4"
}

stop_clear() { # <key> <reason>
    local key="$1" reason="$2"
    reason=$(printf '%s' "$reason" | tr '"\\' '  ' | tr '\n' ' ')
    printf '{"schema":"fleet-stops/1","key":"%s","state":"cleared","reason":"%s","ts":"%s"}\n' \
        "$key" "$reason" "$(date -u +%FT%TZ)" >> "$FLEET_STOPS_FILE" 2>/dev/null || true
    unset 'STOP_OPENED[$key]'   # a later stop on this key is a new state change
}

limit_model_key() { # <model>
    printf '%s' "${1:-default}" | tr -c 'A-Za-z0-9._-' '_'
}

limit_hold_key() { # <provider> <model>  the stop-row key
    printf 'provider-limit-%s-%s' "$1" "$(limit_model_key "$2")"
}

limit_hold_file() { # <provider> <model>  run-remote writes it on exit 78
    printf '%s/%s-%s.limit-hold' "$PROVIDER_STATE_DIR" "$1" "$(limit_model_key "$2")"
}

limit_hold_reset() { # <hold file> -> the reset time from the message, or unknown
    local reset
    reset=$(cut -d'|' -f4 "$1" 2>/dev/null || true)
    printf '%s' "${reset:-unknown}"
}

limit_hold_stop_open() { # <provider> <model> <hold file>
    stop_open_once "$(limit_hold_key "$1" "$2")" provider_limit \
        "provider limit reached on $1 (${2:-default}), resets $(limit_hold_reset "$3"); seats on it are held until a probe passes" \
        "wait for the reset, or raise the limit"
}

# Probe a held provider+model, at most once a minute per dispatch run.
limit_probe() { # <provider> <model> -> 0 when the provider answers again
    local key="$1|${2:-default}" now
    now=$(date +%s)
    if [ -n "${LIMIT_PROBE_CACHE[$key]:-}" ] \
        && [ $(( now - ${LIMIT_PROBE_TS[$key]:-0} )) -lt "${FLEET_LIMIT_PROBE_CACHE_S:-60}" ]; then
        [ "${LIMIT_PROBE_CACHE[$key]}" = "ok" ]
        return
    fi
    if AGENT_MODEL="${2:-}" "$SCRIPT_DIR/provider-probe.sh" "$1" >/dev/null 2>&1; then
        LIMIT_PROBE_CACHE[$key]="ok"
        LIMIT_PROBE_TS[$key]=$now
        return 0
    fi
    LIMIT_PROBE_CACHE[$key]="held"
    LIMIT_PROBE_TS[$key]=$now
    return 1
}

# --------------------------------------------------
# Load workers
# --------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}ERROR: No worker config found at $CONFIG${NC}"
    echo "Run setup-machine.sh on your Mac Minis first, then edit config/workers.yaml"
    exit 1
fi

WORKERS=$(get_workers)
if [ -z "$WORKERS" ]; then
    echo -e "${RED}ERROR: No workers configured in $CONFIG${NC}"
    echo "Uncomment and fill in the mac-mini entries in config/workers.yaml"
    exit 1
fi

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Agent Dispatch${NC}"
echo -e "${BOLD}==========================================${NC}"
echo ""
echo -e "Repo: ${CYAN}$REPO_URL${NC}"
echo ""
echo "Available workers:"
echo "$WORKERS" | while IFS='|' read -r name host; do
    max=$(get_max_agents "$name")
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo ok" >/dev/null 2>&1; then
        echo -e "  ${GREEN}$name${NC} ($host) — online [max_agents: $max]"
    else
        echo -e "  ${RED}$name${NC} ($host) — OFFLINE"
    fi
done
echo ""

# --------------------------------------------------
# Read plan
# --------------------------------------------------
TASKS=()
if [ "$PLAN_SOURCE" = "--interactive" ]; then
    echo "Enter tasks (one per line, format: [wave |] agent | task description | branch-name)"
    echo "Press Ctrl+D when done."
    echo ""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        TASKS+=("$line")
    done
else
    if [ ! -f "$PLAN_SOURCE" ]; then
        echo -e "${RED}ERROR: Plan file not found: $PLAN_SOURCE${NC}"
        exit 1
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [ -z "$line" ] && continue
        TASKS+=("$line")
    done < "$PLAN_SOURCE"
fi

if [ ${#TASKS[@]} -eq 0 ]; then
    echo "No tasks to dispatch."
    exit 0
fi

# --------------------------------------------------
# Fix-round gate: no full-suite VERIFY in a fix round
# --------------------------------------------------
# ---- fix-round-gate:begin (tests/run-plan-check-tests.sh reads this block) ----
# Fleet rule (stated in every producer and critic charter): a fix round runs
# only the tests that cover the code it touched plus the critic's failing
# tests; the full suite runs once, in the final round before merge, or in CI.
# This gate is the mechanical half: it refuses to start a fix-round dispatch
# whose plan still asks a seat for the full suite.
#
# A plan is a fix round when any of these hold:
#   - the plan file's basename carries a fix suffix (w2-fix1.plan)
#   - a header line opens with FIX-ROUND: (the queue runner writes these)
#   - the header or a task line names a round number above 1
# A task line carries a full-suite VERIFY when it says `make test` (any
# case), names the whole tests directory runner (a tests/ glob), or says
# "full suite", unless the same line also says "final round". The three
# phrases are also matched against the joined task text (newlines and
# backslash continuations collapsed), so a VERIFY split across lines is
# still caught.
# Override: a header line opening with ALLOW-FULL-SUITE (owner decision).
fix_round_plan_p() { # <plan file> -> 0 when the plan is a fix round
    local plan="$1"
    case "$(basename "$plan")" in
        *-fix[0-9]*) return 0 ;;
    esac
    [ -f "$plan" ] || return 1
    grep -qiE '^[[:space:]]*#[[:space:]]*FIX-ROUND:' "$plan" && return 0
    grep -qiE '(^|[^a-z])round[[:space:]:#-]*([2-9]|[1-9][0-9])([^0-9]|$)' "$plan" && return 0
    return 1
}

fix_round_full_suite_verify_p() { # <task line> -> 0 when the line asks for the full suite
    local line="$1"
    printf '%s\n' "$line" | grep -qiE 'final[[:space:]-]*round' && return 1
    printf '%s\n' "$line" | grep -qiE '(^|[^A-Za-z0-9_-])make[[:space:]]+test([^A-Za-z0-9_-]|$)' && return 0
    printf '%s\n' "$line" | grep -qE 'tests/[^[:space:]]*\*' && return 0
    printf '%s\n' "$line" | grep -qiE 'full[[:space:]-]*suite' && return 0
    return 1
}

fix_round_gate() { # <plan file> <task line>... -> 1 (refused) when a fix round asks for the full suite
    local plan="$1"; shift
    fix_round_plan_p "$plan" || return 0
    if [ -f "$plan" ] && grep -qE '^[[:space:]]*#[[:space:]]*ALLOW-FULL-SUITE([^A-Za-z0-9_-]|$)' "$plan"; then
        echo -e "${YELLOW}Fix round: ALLOW-FULL-SUITE header set; full-suite VERIFY lines allowed (owner override).${NC}"
        return 0
    fi
    local line
    for line in "$@"; do
        if fix_round_full_suite_verify_p "$line"; then
            echo -e "${RED}ERROR: fix round refused: a task line asks for the full test suite.${NC}" >&2
            echo -e "  task line: $line" >&2
            echo -e "  rule: in a fix round, run only the test file or test names that cover the code you touched, plus the failing tests the critic wrote; the full suite runs once, in the final round before merge, or in CI." >&2
            echo -e "  final round? say 'final round' on the task line. Owner override: add a header line '# ALLOW-FULL-SUITE'." >&2
            return 1
        fi
    done
    # Per-line matching misses a VERIFY split across lines; re-check the three
    # phrases against the joined task text with newlines and trailing
    # backslash continuations collapsed.
    local joined
    joined=$(printf '%s\n' "$@" | sed 's/[[:space:]]*\\[[:space:]]*$//' | tr '\n' ' ')
    if [ -n "$joined" ] && fix_round_full_suite_verify_p "$joined"; then
        echo -e "${RED}ERROR: fix round refused: a task line asks for the full test suite.${NC}" >&2
        echo -e "  the full-suite phrase spans a line break: $joined" >&2
        echo -e "  rule: in a fix round, run only the test file or test names that cover the code you touched, plus the failing tests the critic wrote; the full suite runs once, in the final round before merge, or in CI." >&2
        echo -e "  final round? say 'final round' on the task line. Owner override: add a header line '# ALLOW-FULL-SUITE'." >&2
        return 1
    fi
    return 0
}
# ---- fix-round-gate:end ----

if ! fix_round_gate "$PLAN_SOURCE" ${TASKS[@]+"${TASKS[@]}"}; then
    exit 1
fi

# --------------------------------------------------
# Risk-tier gate: every plan declares TIER: A, B or C
# --------------------------------------------------
# ---- tier-gate:begin (tests/run-plan-check-tests.sh reads this block) ----
# Fleet rule (docs/risk-tiers.md, fleet optimization W2): every plan declares
# its risk tier in a header line '# TIER: A', '# TIER: B' or '# TIER: C'. The
# tier fixes the critic set, the round cap and what counts as a blocking
# finding. This gate is the mechanical half: it refuses to start a plan with
# no valid TIER header, and names the tier in the dispatch banner.
# Override: a header line opening with ALLOW-NO-TIER (owner decision).
plan_tier() { # <plan file> -> prints A, B or C; returns 1 when no valid TIER header
    local plan="$1"
    [ -f "$plan" ] || return 1
    local tier
    tier=$(sed -nE 's/^[[:space:]]*#[[:space:]]*[Tt][Ii][Ee][Rr]:[[:space:]]*([ABCabc])([^A-Za-z0-9].*)?$/\1/p' "$plan" | head -1 | tr '[:lower:]' '[:upper:]')
    [ -n "$tier" ] || return 1
    printf '%s\n' "$tier"
}

tier_gate() { # <plan file> -> 1 (refused) when the plan has no valid TIER header
    local plan="$1"
    if [ ! -f "$plan" ]; then
        # Interactive dispatch has no plan file; nothing to read a header from.
        echo -e "${YELLOW}No plan file ($plan): the TIER check applies to plan files only.${NC}"
        return 0
    fi
    if grep -qE '^[[:space:]]*#[[:space:]]*ALLOW-NO-TIER([^A-Za-z0-9_-]|$)' "$plan"; then
        echo -e "${YELLOW}ALLOW-NO-TIER header set: dispatching without a TIER header (owner override).${NC}"
        return 0
    fi
    local tier
    if tier=$(plan_tier "$plan"); then
        echo -e "Plan tier: ${BOLD}$tier${NC} (risk tiers: docs/risk-tiers.md)"
        return 0
    fi
    echo -e "${RED}ERROR: dispatch refused: the plan has no TIER header.${NC}" >&2
    echo -e "  rule: every plan declares its risk tier with a header line '# TIER: A', '# TIER: B' or '# TIER: C' (docs/risk-tiers.md)." >&2
    echo -e "  Owner override: add a header line '# ALLOW-NO-TIER'." >&2
    return 1
}
# ---- tier-gate:end ----

if ! tier_gate "$PLAN_SOURCE"; then
    exit 1
fi

echo "Tasks to dispatch: ${#TASKS[@]}"
echo ""

# ---- constraints-header:begin (tests/run-constraints-tests.sh reads this block) ----
# Plan-wide rules belong in the header once, not retyped on every task line
# (#115). A plan declares them as repeatable header lines:
#
#   # CONSTRAINTS: no long dash anywhere, no AI tool or vendor name
#   # CONSTRAINTS: no Co-Authored-By trailer
#
# Every seat of that plan, producer and critic alike, receives them at the
# front of its task, so one wording reaches every seat and a task line that
# forgets the clause is no longer a seat running without the rule.
#
# Two gates keep the header and the task lines from drifting apart:
#   * a task line that repeats a rule verbatim stops the dispatch (say it
#     once, in the header);
#   * a plan that declares rules whose seats did not receive them stops the
#     dispatch. Silent injection failure would strip the rule from every
#     seat at once, so this fails closed, never open.
plan_constraints() { # <plan file> -> one rule per line, empty when none
    local plan="$1"
    [ -n "$plan" ] && [ -f "$plan" ] || return 0
    sed -nE 's/^[[:space:]]*#[[:space:]]*CONSTRAINTS:[[:space:]]*//p' "$plan" \
        | sed -E 's/[[:space:]]+$//' | grep -v '^$' || true
}

constraints_prefix() { # <plan file> -> the block prepended to every task
    local plan="$1" rule out="" n=1
    while IFS= read -r rule; do
        out="$out $n) $rule"
        n=$((n + 1))
    done < <(plan_constraints "$plan")
    [ -n "$out" ] || return 0
    printf 'CONSTRAINTS (from the plan header, they bind this task as if written in it):%s ----' "$out"
}

constraints_dup_gate() { # <plan file> <task desc>... -> 1 when a task repeats a rule
    local plan="$1"; shift
    local rule desc
    while IFS= read -r rule; do
        for desc in "$@"; do
            case "$desc" in
                *"$rule"*)
                    echo -e "${RED}ERROR: dispatch refused: a task line repeats a CONSTRAINTS rule.${NC}" >&2
                    echo -e "  rule: '$rule'" >&2
                    echo -e "  it is already in the plan header and reaches every seat from there; two copies drift." >&2
                    echo -e "  fix: delete the clause from the task line." >&2
                    return 1
                    ;;
            esac
        done
    done < <(plan_constraints "$plan")
    return 0
}

constraints_delivered() { # <plan file> <task desc>... -> 1 when a seat did not get a rule
    local plan="$1"; shift
    local rule desc
    while IFS= read -r rule; do
        for desc in "$@"; do
            case "$desc" in
                *"$rule"*) ;;
                *)
                    echo -e "${RED}ERROR: dispatch refused: a seat did not receive the plan constraints.${NC}" >&2
                    echo -e "  rule: '$rule'" >&2
                    echo -e "  every seat of a plan with CONSTRAINTS header lines must carry them; this fails closed." >&2
                    return 1
                    ;;
            esac
        done
    done < <(plan_constraints "$plan")
    return 0
}
# ---- constraints-header:end ----

# --------------------------------------------------
# Trim leading and trailing whitespace.
#
# Deliberately not `echo "$x" | xargs`. xargs parses its input as shell words,
# so a single apostrophe anywhere in a task description ("the day's data")
# aborts the entire dispatch with "xargs: unterminated quote" before a single
# seat starts, and quotes and backslashes elsewhere are silently eaten. Plan
# text is prose written by a person and must survive verbatim.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Parse tasks into waves
# --------------------------------------------------
# Detect format: if first field of first task is a number, it's wave-aware
# Otherwise, all tasks go to wave 1
detect_wave_format() {
    local first_line="$1"
    local fields
    IFS='|' read -ra fields <<< "$first_line"
    local first_field
    first_field=$(trim "${fields[0]}")
    if [[ "$first_field" =~ ^[0-9]+$ ]]; then
        echo "wave"
    else
        echo "legacy"
    fi
}

FORMAT=$(detect_wave_format "${TASKS[0]}")

# Build associative arrays for waves
# WAVE_TASKS[wave_num] = "idx1,idx2,idx3" (indices into parallel arrays)
declare -A WAVE_TASKS
declare -a TASK_WAVE TASK_AGENT TASK_DESC TASK_BRANCH TASK_MODEL

for i in "${!TASKS[@]}"; do
    task_line="${TASKS[$i]}"
    IFS='|' read -ra fields <<< "$task_line"
    n=${#fields[@]}

    # The task description may itself contain '|' (e.g. "VERDICT: PASS|REVISE").
    # Rule: the branch is only the LAST field, and only when it looks like a
    # branch slug (no spaces, contains '/'). Everything between agent and
    # branch is re-joined as the description. Plans that legitimately use
    # branch names without '/' fall back to a generated branch name.
    last=""
    [ "$n" -ge 1 ] && last=$(trim "${fields[$((n-1))]}")
    is_branch=false
    case "$last" in
        */*) case "$last" in *[!A-Za-z0-9/_.-]*) is_branch=false ;; *) is_branch=true ;; esac ;;
    esac

    if [ "$FORMAT" = "wave" ]; then
        wave=$(trim "${fields[0]}")
        agent=$(trim "${fields[1]}")
        start=2
    else
        wave=1
        agent=$(trim "${fields[0]}")
        start=1
    fi

    branch=""
    if [ "$is_branch" = true ] && [ "$n" -gt $((start + 1)) ]; then
        branch="$last"
        desc=$(IFS='|'; echo "${fields[*]:$start:$((n - start - 1))}")
    else
        desc=$(IFS='|'; echo "${fields[*]:$start}")
    fi
    desc=$(trim "$desc")

    branch="${branch:-fix/$agent-$(date +%s)}"

    TASK_WAVE[$i]="$wave"
    TASK_AGENT[$i]="$agent"
    TASK_DESC[$i]="$desc"
    TASK_BRANCH[$i]="$branch"
    # Cache the model tier once per task — avoids re-parsing routing.yaml
    # on every row of the exec-log and summary report loops.
    TASK_MODEL[$i]="$(get_model "$agent")"

    if [ -n "${WAVE_TASKS[$wave]:-}" ]; then
        WAVE_TASKS[$wave]="${WAVE_TASKS[$wave]},$i"
    else
        WAVE_TASKS[$wave]="$i"
    fi
done

# Plan-wide constraints reach every seat from the header (#115).
if [ "$PLAN_SOURCE" != "--interactive" ]; then
    CONSTRAINTS_PREFIX="$(constraints_prefix "$PLAN_SOURCE")"
    if [ -n "$CONSTRAINTS_PREFIX" ]; then
        constraints_dup_gate "$PLAN_SOURCE" "${TASK_DESC[@]}" || exit 1
        for i in "${!TASK_DESC[@]}"; do
            TASK_DESC[$i]="$CONSTRAINTS_PREFIX ${TASK_DESC[$i]}"
        done
        constraints_delivered "$PLAN_SOURCE" "${TASK_DESC[@]}" || exit 1
        echo -e "Constraints: $(plan_constraints "$PLAN_SOURCE" | wc -l | tr -d "[:space:]") from the plan header, on every task."
    fi
fi

# Sort wave numbers
SORTED_WAVES=($(echo "${!WAVE_TASKS[@]}" | tr ' ' '\n' | sort -n))

echo -e "Waves: ${#SORTED_WAVES[@]} (format: $FORMAT)"
for w in "${SORTED_WAVES[@]}"; do
    IFS=',' read -ra indices <<< "${WAVE_TASKS[$w]}"
    echo -e "  Wave $w: ${#indices[@]} task(s)"
done
echo ""

# --------------------------------------------------
# Fleet Desk event stream — open the run
# --------------------------------------------------
# Mode is derived, never guessed loosely: a plan living under a conductor
# directory, or a multi-wave plan where every wave holds exactly one seat, is a
# serial Conductor chain. Everything else renders as parallel wave lanes.
detect_dispatch_mode() {
    case "$PLAN_SOURCE" in
        *conductor*) echo "conductor"; return ;;
    esac
    [ "${#SORTED_WAVES[@]}" -gt 1 ] || { echo "wave"; return; }
    local w idxs
    for w in "${SORTED_WAVES[@]}"; do
        IFS=',' read -ra idxs <<< "${WAVE_TASKS[$w]}"
        [ "${#idxs[@]}" -eq 1 ] || { echo "wave"; return; }
    done
    echo "conductor"
}

DISPATCH_MODE="$(detect_dispatch_mode)"
REPO_SLUG_EVENTS="$(basename "$REPO_URL" .git)"
# A detached child opens the stream under the id its parent already printed.
fleet_events_init "$REPO_SLUG_EVENTS" "$DISPATCH_MODE" "$PLAN_SOURCE" "${DISPATCH_DETACHED:-}"
fleet_event dispatch_plan waves="${#SORTED_WAVES[@]}" seats="${#TASK_AGENT[@]}" format="$FORMAT"
# Queue: this plan is now running. Armed plans keep their position and gain the
# dispatch id; a plan dispatched without being armed is appended as running with
# the purpose read from its own header line (never from a task body).
if [ -f "$PLAN_SOURCE" ]; then
    fleet_queue start "$PLAN_SOURCE" "${FLEET_DISPATCH_ID:-}" "$REPO_SLUG_EVENTS"
fi
if [ -n "${FLEET_EVENTS_FILE:-}" ]; then
    echo -e "Live events: ${CYAN}logs/fleet-events/$(basename "$FLEET_EVENTS_FILE")${NC}  (watch: make desk-live)"
    echo ""
fi

# Honest close-out even on Ctrl-C / early exit: the Floor must never show a run
# that is still "running" after the dispatcher is gone.
FLEET_DISPATCH_CLOSED=false
fleet_close_dispatch() {
    local status="${1:-aborted}"
    [ "$FLEET_DISPATCH_CLOSED" = true ] && return 0
    FLEET_DISPATCH_CLOSED=true
    fleet_event dispatch_end status="$status" \
        total="${TOTAL_TASKS:-0}" succeeded="${TOTAL_SUCCESS:-0}" failed="${TOTAL_FAIL:-0}" \
        duration_s="$(( $(date +%s) - ${OVERALL_START:-$(date +%s)} ))"
    # Same close-out for the queue: the plan stops being "running" the moment
    # the dispatcher is gone, aborted runs included.
    if [ -f "$PLAN_SOURCE" ]; then
        fleet_queue settle "$PLAN_SOURCE" "$status"
    fi
}
# EXIT covers normal and error exits; the INT/TERM traps make the close-out
# ordering explicit on Ctrl-C / kill and pin the conventional 130/143 exit
# codes instead of relying on the shell's signal-death behavior (whether an
# EXIT trap runs on fatal signals varies by shell and version: bash 3.2 and 5.3
# both run it, but nothing guarantees it). The FLEET_DISPATCH_CLOSED guard keeps
# the later EXIT trap a no-op after a signal close-out.
#
# The EXIT trap captures the status it was entered with and exits with it again,
# so the close-out cannot report success over a run that was interrupted (130),
# terminated (143) or failed. Wrappers read that code.
trap 'dispatch_rc=$?; fleet_close_dispatch aborted; dispatch_run_note_exit "$dispatch_rc"; exit "$dispatch_rc"' EXIT
trap 'fleet_close_dispatch aborted; exit 130' INT
trap 'fleet_close_dispatch aborted; exit 143' TERM

# --------------------------------------------------
# Vendor auth preflight (session validity before any launch)
# --------------------------------------------------
# Fail-closed for seats the plan needs (primary + failover). Validate only —
# does not re-login. Override: --skip-auth-preflight.
if [ "$SKIP_AUTH_PREFLIGHT" = false ]; then
    AUTH_CHECK="$SCRIPT_DIR/vendor-auth-check.sh"
    if [ ! -x "$AUTH_CHECK" ] && [ -f "$AUTH_CHECK" ]; then
        chmod +x "$AUTH_CHECK" 2>/dev/null || true
    fi
    if [ -f "$AUTH_CHECK" ]; then
        # Union of primary + failover vendors for every role in the plan
        declare -A NEED_VENDORS=()
        for i in "${!TASK_AGENT[@]}"; do
            agent="${TASK_AGENT[$i]}"
            primary=$(get_provider "$agent")
            chain=$(get_failover_chain "$agent")
            for v in $primary $chain; do
                v=$(trim "$v")
                [ -n "$v" ] && NEED_VENDORS["$v"]=1
            done
        done
        VENDOR_LIST=""
        for v in "${!NEED_VENDORS[@]}"; do
            VENDOR_LIST="${VENDOR_LIST:+$VENDOR_LIST,}$v"
        done

        # Unique worker hosts that may run tasks (role: worker only)
        declare -A NEED_HOSTS=()
        while IFS='|' read -r _wname whost; do
            [ -n "$whost" ] && NEED_HOSTS["$whost"]=1
        done <<< "$WORKERS"

        # --deep: real headless one-shot per vendor (status/files alone can lie)
        echo -e "${BOLD}Vendor auth preflight (deep headless)${NC} (vendors: ${VENDOR_LIST:-none})"
        AUTH_FAIL=0
        for whost in "${!NEED_HOSTS[@]}"; do
            if [ "$whost" = "localhost" ] || [ "$whost" = "127.0.0.1" ]; then
                if ! "$AUTH_CHECK" --deep --vendors "$VENDOR_LIST"; then
                    AUTH_FAIL=1
                fi
            else
                echo -e "  remote host ${CYAN}$whost${NC}:"
                if ! "$AUTH_CHECK" --deep --host "$whost" --vendors "$VENDOR_LIST"; then
                    AUTH_FAIL=1
                fi
            fi
        done
        if [ "$AUTH_FAIL" -ne 0 ]; then
            echo -e "${RED}ERROR: vendor auth preflight failed — fix login(s) above, then re-dispatch.${NC}"
            echo "  Skip only if intentional: --skip-auth-preflight"
            exit 1
        fi
        echo ""
    else
        echo -e "${YELLOW}WARNING: vendor-auth-check.sh missing — skipping preflight${NC}"
        echo ""
    fi
else
    echo -e "${YELLOW}Vendor auth preflight skipped (--skip-auth-preflight)${NC}"
    echo ""
fi

# --------------------------------------------------
# Assign tasks to workers
# --------------------------------------------------
WORKER_ARRAY=()
while IFS='|' read -r name host; do
    WORKER_ARRAY+=("$name|$host")
done <<< "$WORKERS"

WORKER_COUNT=${#WORKER_ARRAY[@]}
WORKER_IDX=0

# --------------------------------------------------
# Check worker capacity via SSH
# --------------------------------------------------
check_worker_capacity() {
    local host="$1"
    local wname="$2"
    local max
    max=$(get_max_agents "$wname")
    local running
    # Count every vendor CLI: a worker may be running kimi/grok/codex agents too.
    # `pgrep … | wc -l` (not `pgrep -c`) — BSD/macOS pgrep has no -c flag; the
    # old `pgrep -c claude` silently returned 0 on Mac workers via the fallback.
    running=$(ssh -o ConnectTimeout=5 "$host" "pgrep -fl 'claude|kimi|grok|codex' 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo 0)
    running="${running:-0}"
    if [ "$running" -ge "$max" ]; then
        return 1  # at capacity
    fi
    return 0
}

# Find available worker for an agent, respecting max_agents
find_worker() {
    local agent="$1"
    local exclude_worker="${2:-}"  # worker name to exclude (for retry-on-different-worker)

    # First pass: try preferred worker with capacity
    for w in "${WORKER_ARRAY[@]}"; do
        IFS='|' read -r wname whost <<< "$w"
        [ "$wname" = "$exclude_worker" ] && continue
        preferred=$(get_preferred_agents "$wname")
        if echo "$preferred" | grep -q "^${agent}$"; then
            if check_worker_capacity "$whost" "$wname"; then
                echo "$wname|$whost"
                return 0
            fi
        fi
    done

    # Second pass: round-robin with capacity check
    local tried=0
    while [ $tried -lt $WORKER_COUNT ]; do
        IFS='|' read -r wname whost <<< "${WORKER_ARRAY[$WORKER_IDX]}"
        WORKER_IDX=$(( (WORKER_IDX + 1) % WORKER_COUNT ))
        tried=$((tried + 1))
        [ "$wname" = "$exclude_worker" ] && continue
        if check_worker_capacity "$whost" "$wname"; then
            echo "$wname|$whost"
            return 0
        fi
    done

    # Third pass: force round-robin ignoring capacity (all workers full)
    IFS='|' read -r wname whost <<< "${WORKER_ARRAY[$WORKER_IDX]}"
    WORKER_IDX=$(( (WORKER_IDX + 1) % WORKER_COUNT ))
    if [ "$wname" != "$exclude_worker" ]; then
        echo "$wname|$whost"
    else
        # Just pick the next one
        IFS='|' read -r wname whost <<< "${WORKER_ARRAY[$WORKER_IDX]}"
        WORKER_IDX=$(( (WORKER_IDX + 1) % WORKER_COUNT ))
        echo "$wname|$whost"
    fi
    return 0
}

# --------------------------------------------------
# Result tracking
# --------------------------------------------------
declare -A RESULT_STATUS RESULT_DURATION RESULT_WORKER RESULT_BRANCH
declare -A RESULT_PROVIDER    # idx -> vendor that ran the task (feeds scorecard)
declare -A TASK_TRIED_PROVIDERS  # idx -> space-separated vendors already tried (failover exclusion)
declare -A TASK_ATTEMPT          # idx -> attempt number (1 = first run) for the event stream

# --------------------------------------------------
# Dispatch a single task, returns PID
# --------------------------------------------------
dispatch_task() {
    local idx="$1"
    local agent="${TASK_AGENT[$idx]}"
    local task="${TASK_DESC[$idx]}"
    local branch="${TASK_BRANCH[$idx]}"
    local exclude_worker="${2:-}"

    # Initialize result fields FIRST. Anything below can fail early (no worker
    # found, provider resolution, launcher missing) — with every slot set, the
    # wave result loop reports cleanly under set -u instead of dying on an
    # unbound RESULT_WORKER (live-run bug).
    RESULT_STATUS[$idx]="failed"
    RESULT_PROVIDER[$idx]=""
    RESULT_WORKER[$idx]=""
    RESULT_BRANCH[$idx]="$branch"

    local worker_info wname whost
    if ! worker_info=$(find_worker "$agent" "$exclude_worker"); then
        echo -e "  ${RED}✗${NC} $agent — no worker available" >&2
        fleet_event seat_exit task_id="$idx" agent="$agent" branch="$branch" \
            wave="${CURRENT_WAVE:-1}" status=failed exit=1 reason=no_worker
        # Keep the "always returns a waitable pid" contract: reports as failed.
        ( exit 1 ) &
        DISPATCH_PID=$!
        return 0
    fi
    IFS='|' read -r wname whost <<< "$worker_info"

    # Resolve provider through the failover chain, skipping vendors already
    # tried on this task (rate-capped/unavailable) and any currently cooling.
    local provider
    if ! provider=$(resolve_provider "$agent" "${TASK_TRIED_PROVIDERS[$idx]:-}"); then
        echo "No funded provider available for $agent" >&2
        RESULT_STATUS[$idx]="out-of-credit"
        ( exit 76 ) &
        DISPATCH_PID=$!
        return 0
    fi
    RESULT_PROVIDER[$idx]="$provider"

    local model="${TASK_MODEL[$idx]:-}"

    # Provider-limit hold (issue #84): no seat starts on a held provider and
    # model until a probe call succeeds. A passed probe releases the hold for
    # every later seat; a failed one marks this seat held without starting it.
    local hold_file
    hold_file="$(limit_hold_file "$provider" "$model")"
    if [ -f "$hold_file" ]; then
        if limit_probe "$provider" "$model"; then
            rm -f "$hold_file"
            stop_clear "$(limit_hold_key "$provider" "$model")" \
                "probe passed on $provider (${model:-default}); seats on it resume"
            echo -e "  ${GREEN}✓${NC} $provider (${model:-default}) answers again, provider-limit hold released" >&2
        else
            RESULT_STATUS[$idx]="held($provider/${model:-default})"
            echo -e "  ${YELLOW}⏸${NC} $agent: $provider (${model:-default}) held for a provider limit (resets $(limit_hold_reset "$hold_file")); seat not started" >&2
            limit_hold_stop_open "$provider" "$model" "$hold_file"
            fleet_event provider_limit task_id="$idx" agent="$agent" branch="$branch" \
                wave="${CURRENT_WAVE:-1}" provider="$provider" model="${model:-default}" \
                reset="$(limit_hold_reset "$hold_file")"
            # Keep the "always returns a waitable pid" contract: the wave loop
            # classifies this exit exactly like a seat that hit the limit.
            ( exit 78 ) &
            DISPATCH_PID=$!
            return 0
        fi
    fi

    local is_preferred=""
    local preferred
    preferred=$(get_preferred_agents "$wname" || true)
    if ! echo "$preferred" | grep -q "^${agent}$"; then
        is_preferred=" (round-robin)"
    fi

    local model_label="${model:-default}"
    echo -e "  ${CYAN}→${NC} $wname ($whost): ${BOLD}$agent${NC} [${provider}/${model_label}] — \"$task\" [$branch]$is_preferred" >&2

    RESULT_WORKER[$idx]="$wname"

    # Seat is going out — record the facts only (no task text ever).
    fleet_event seat_dispatch task_id="$idx" agent="$agent" branch="$branch" \
        wave="${CURRENT_WAVE:-1}" provider="$provider" model="${model:-default}" \
        worker="$wname" attempt="${TASK_ATTEMPT[$idx]:-1}"

    # Run in subshell to capture exit code. Pass model + provider via env so
    # run-remote.sh selects the right launcher and forwards --model.
    # The PID travels via the DISPATCH_PID global — callers must NOT capture
    # $(dispatch_task): a command-substitution subshell would swallow every
    # RESULT_* write above (the actual root cause of the unbound-variable crash).
    # FLEET_EVENTS_FILE + FLEET_DISPATCH_ID + AGENT_TASK_ID travel with the seat
    # so the stream reader can attribute live activity to this lane. Facts only,
    # same redaction law as every other event.
    (
        AGENT_MODEL="$model" AGENT_PROVIDER="$provider" AGENT_WAVE="${CURRENT_WAVE:-1}" \
            AGENT_TASK_ID="$idx" \
            SEAT_QUIET_AFTER_S="$SEAT_QUIET_AFTER_S" \
            SEAT_TOOL_CEILING_S="$SEAT_TOOL_CEILING_S" \
            FLEET_EVENTS_FILE="${FLEET_EVENTS_FILE:-}" \
            FLEET_DISPATCH_ID="${FLEET_DISPATCH_ID:-}" \
            "$SCRIPT_DIR/run-remote.sh" "$whost" "$REPO_URL" "$agent" "$task" "$branch"
    ) &
    DISPATCH_PID=$!
}

# --------------------------------------------------
# Seat outcome → event stream
# --------------------------------------------------
# fleet_seat_exit <idx> <status> <exit_code> <duration_s>
# status: success | no-delivery | out-of-credit | failed | blocked | ratecap | unavailable | held | hung
emit_seat_exit() {
    local idx="$1" status="$2" code="$3" duration="$4"
    fleet_event seat_exit task_id="$idx" agent="${TASK_AGENT[$idx]}" \
        branch="${TASK_BRANCH[$idx]}" wave="${TASK_WAVE[$idx]}" \
        provider="${RESULT_PROVIDER[$idx]:-}" worker="${RESULT_WORKER[$idx]:-}" \
        status="$status" exit="$code" duration_s="$duration" \
        attempt="${TASK_ATTEMPT[$idx]:-1}"
}

# --------------------------------------------------
# Retry logic with exponential backoff
# --------------------------------------------------
read -ra BACKOFF_DELAYS <<< "${FLEET_BACKOFF_DELAYS:-10 30}"

retry_task() {
    local idx="$1"
    local attempt="$2"
    local agent="${TASK_AGENT[$idx]}"
    local task="${TASK_DESC[$idx]}"
    local branch="${TASK_BRANCH[$idx]}"

    local delay_idx=$((attempt - 1))
    local delay=${BACKOFF_DELAYS[$delay_idx]:-30}

    echo -e "  ${YELLOW}Retrying${NC} task $idx ($agent) in ${delay}s [attempt $((attempt + 1))/$((MAX_RETRIES + 1))]..." >&2
    dispatch_sleep_interruptible "$delay"

    local exclude=""
    if [ "$RETRY_DIFFERENT_WORKER" = true ]; then
        exclude="${RESULT_WORKER[$idx]}"
        echo -e "  ${YELLOW}Excluding previous worker:${NC} $exclude" >&2
    fi

    local prev_provider="${RESULT_PROVIDER[$idx]:-}"
    TASK_ATTEMPT[$idx]=$((attempt + 1))
    dispatch_task "$idx" "$exclude"

    # A retry that landed on a different vendor is a failover — say so plainly.
    if [ -n "$prev_provider" ] && [ "${RESULT_PROVIDER[$idx]:-}" != "$prev_provider" ]; then
        fleet_event failover task_id="$idx" agent="$agent" branch="$branch" \
            wave="${CURRENT_WAVE:-1}" from_provider="$prev_provider" \
            to_provider="${RESULT_PROVIDER[$idx]:-}" attempt="$((attempt + 1))"
    fi
}

# --------------------------------------------------
# Local dispatch lock (one dispatch per branch on localhost workers)
# --------------------------------------------------
# Every localhost seat runs in its own git worktree (scripts/run-remote.sh,
# issue #66), so two dispatches on one repo no longer share a checkout and can
# run side by side. What still must not interleave is two dispatches driving
# the same branch: their producer / critic seats would take turns on one
# branch with no plan-level ordering. So the lock is per branch: a dispatch
# takes one lock per distinct branch in its plan, in sorted order (two
# dispatches sharing several branches therefore queue on the first common one
# and never deadlock), and holds them until the run ends.
#
# Remote (ssh) workers are unaffected: they have their own machines and their
# own checkouts, so the locks are taken only when a localhost worker is in play.
# ---- dispatch-lock:begin (tests/run-dispatch-lock-tests.sh sources this block) ----
# Machine-global, not per fleet clone. What a lock protects is a branch of the
# fetch point every localhost seat works from, $HOME/dev/<repo> (FETCH_DIR in
# scripts/run-remote.sh), so two dev-agents clones on one host must contend for
# the same file; a path under this clone's logs/ would give each clone a private
# lock and serialize nothing. FLEET_HOME is the per-user fleet base on a machine,
# the one that already holds ~/dev/agent-logs, ~/dev/agent-runtime and the seat
# worktrees. The locks sit beside them: <LOCK_DIR>/<repo>/<branch>.lock, with
# the branch's slashes written as dashes.
FLEET_HOME="${FLEET_HOME:-$HOME/dev}"
LOCK_DIR="${LOCK_DIR:-$FLEET_HOME/dispatch-locks}"
LOCK_REPO_NAME=$(basename "$REPO_URL" .git)
LOCK_FILES=()        # one per distinct branch in the plan, sorted
LOCK_HELD_FILES=()   # the ones this pid owns
# Distinct from 1 so a caller can tell "another dispatch is running" apart from
# "this dispatch failed".
LOCK_BUSY_EXIT=9
# Poll granularity while queueing. The heartbeat below stays at 60s regardless;
# only the tests shorten this.
LOCK_POLL_S="${DISPATCH_LOCK_POLL_S:-5}"

dispatch_lock_uses_localhost() {
    local w wname whost
    for w in "${WORKER_ARRAY[@]}"; do
        IFS='|' read -r wname whost <<< "$w"
        case "$whost" in
            localhost|127.0.0.1) return 0 ;;
        esac
    done
    return 1
}

dispatch_lock_files() {
    local b
    LOCK_FILES=()
    while IFS= read -r b; do
        [ -n "$b" ] && LOCK_FILES+=("$LOCK_DIR/$LOCK_REPO_NAME/$b.lock")
    done < <(printf '%s\n' "${TASK_BRANCH[@]}" | tr '/ ' '--' | sort -u)
}

# Atomic create-or-fail: noclobber makes ">" fail when the file already exists.
dispatch_lock_try_acquire() { # <lock file>
    mkdir -p "$(dirname "$1")"
    if ( set -o noclobber; printf '%s\n%s\n%s\n' \
            "$$" "$PLAN_SOURCE" "$(date -u +%FT%TZ)" > "$1" ) 2>/dev/null; then
        LOCK_HELD_FILES+=("$1")
        return 0
    fi
    return 1
}

# Release only our own locks, once, and never a lock another pid has since taken.
dispatch_lock_release() {
    local f owner
    for f in ${LOCK_HELD_FILES[@]+"${LOCK_HELD_FILES[@]}"}; do
        owner=$(sed -n '1p' "$f" 2>/dev/null || echo "")
        [ "$owner" = "$$" ] && rm -f "$f"
    done
    LOCK_HELD_FILES=()
    return 0
}

# Block until this dispatch owns every branch lock its plan needs. Exits
# $LOCK_BUSY_EXIT (releasing anything already taken) instead of queueing when
# --no-wait was given.
dispatch_lock_acquire() {
    local f branch_label holder_pid holder_plan holder_since waited
    dispatch_lock_files
    for f in ${LOCK_FILES[@]+"${LOCK_FILES[@]}"}; do
        branch_label=$(basename "$f" .lock)
        while ! dispatch_lock_try_acquire "$f"; do
            holder_pid=$(sed -n '1p' "$f" 2>/dev/null || echo "")
            holder_plan=$(sed -n '2p' "$f" 2>/dev/null || echo "unknown plan")
            holder_since=$(sed -n '3p' "$f" 2>/dev/null || echo "unknown time")

            # A lock file with no live owner is the residue of a killed dispatch.
            if [ -z "$holder_pid" ] || ! kill -0 "$holder_pid" 2>/dev/null; then
                echo -e "${YELLOW}Clearing stale $LOCK_REPO_NAME/$branch_label dispatch lock (pid ${holder_pid:-unknown} is gone).${NC}"
                rm -f "$f"
                continue
            fi

            echo -e "${YELLOW}Another dispatch holds $LOCK_REPO_NAME branch $branch_label: pid $holder_pid running plan '$holder_plan' (since $holder_since).${NC}"
            if [ "${NO_WAIT:-false}" = true ]; then
                echo -e "${RED}--no-wait given: not queueing behind it. Exiting $LOCK_BUSY_EXIT.${NC}" >&2
                dispatch_lock_release
                exit "$LOCK_BUSY_EXIT"
            fi
            echo "Waiting for it to finish. Ctrl-C to give up, or re-run with --no-wait to fail fast."

            waited=0
            while kill -0 "$holder_pid" 2>/dev/null && [ -f "$f" ] \
                  && [ "$(sed -n '1p' "$f" 2>/dev/null || echo "")" = "$holder_pid" ]; do
                sleep "$LOCK_POLL_S"
                waited=$(( waited + LOCK_POLL_S ))
                if [ "$waited" -ge 60 ]; then
                    echo "  still waiting on pid $holder_pid, plan '$holder_plan', branch $branch_label ($(date -u +%FT%TZ))"
                    waited=0
                fi
            done
        done
    done
    return 0
}

# Blocking builtins defer traps. `wait` hands the shell to the kernel until the
# child exits, and a long `sleep` does the same, so a signal that arrives first
# is only serviced once the block returns: Ctrl-C during a wave could leave the
# lock files behind for as long as the seats keep running. Poll in short slices
# instead, so a queued INT/TERM trap runs at most one slice late and the locks
# are released while the seats are still live.
DISPATCH_WAIT_SLICE_S="${DISPATCH_WAIT_SLICE_S:-1}"

# Wait for one background seat and return its exit status. bash keeps the status
# of a finished background job until `wait` claims it, so the trailing wait is
# exact even though the poll loop already saw the pid disappear.
dispatch_wait_interruptible() {
    local pid="$1"
    while kill -0 "$pid" 2>/dev/null; do
        sleep "$DISPATCH_WAIT_SLICE_S"
    done
    wait "$pid" 2>/dev/null
}

# Same reason, for fixed delays such as the retry backoff: one long sleep would
# hold a pending trap for its whole duration.
dispatch_sleep_interruptible() {
    local total="$1"
    local slept=0
    while [ "$slept" -lt "$total" ]; do
        sleep "$DISPATCH_WAIT_SLICE_S"
        slept=$(( slept + DISPATCH_WAIT_SLICE_S ))
    done
}

# Close-out traps for a run that holds locks: release them on every exit path
# (normal end, `set -e` abort, Ctrl-C, kill, hangup). dispatch_lock_release is
# idempotent, so the explicit call at the end of the run is harmless here.
# A function rather than inline traps so the lock suite can arm the real thing.
dispatch_lock_arm_traps() {
    trap 'dispatch_rc=$?; dispatch_lock_release; fleet_close_dispatch aborted; dispatch_run_note_exit "$dispatch_rc"; exit "$dispatch_rc"' EXIT
    trap 'dispatch_lock_release; fleet_close_dispatch aborted; exit 130' INT
    trap 'dispatch_lock_release; fleet_close_dispatch aborted; exit 143' TERM
    trap 'dispatch_lock_release; fleet_close_dispatch aborted; exit 129' HUP
}
# ---- dispatch-lock:end ----

if dispatch_lock_uses_localhost; then
    dispatch_lock_acquire
    echo -e "${GREEN}Holding the $LOCK_REPO_NAME branch locks${NC} (pid $$): $(printf '%s ' "${LOCK_HELD_FILES[@]#"$LOCK_DIR"/}")"
    echo ""
    dispatch_lock_arm_traps
fi

# --------------------------------------------------
# Execute waves
# --------------------------------------------------
TOTAL_TASKS=${#TASK_AGENT[@]}
TOTAL_SUCCESS=0
TOTAL_FAIL=0
OVERALL_START=$(date +%s)

for wave_num in "${SORTED_WAVES[@]}"; do
    IFS=',' read -ra wave_indices <<< "${WAVE_TASKS[$wave_num]}"
    CURRENT_WAVE="$wave_num"   # passed to run-remote as AGENT_WAVE (handoff ledger)

    echo -e "${BOLD}------------------------------------------${NC}"
    echo -e "${BOLD}  Wave $wave_num — ${#wave_indices[@]} task(s)${NC}"
    echo -e "${BOLD}------------------------------------------${NC}"
    echo ""
    echo "Dispatching..."

    fleet_event wave_start wave="$wave_num" seats="${#wave_indices[@]}" mode="$DISPATCH_MODE"

    # Track PIDs for this wave
    declare -A WAVE_PIDS  # pid -> task_idx
    declare -A TASK_START # idx -> epoch

    for idx in "${wave_indices[@]}"; do
        TASK_START[$idx]=$(date +%s)
        TASK_ATTEMPT[$idx]=1
        dispatch_task "$idx"
        WAVE_PIDS[$DISPATCH_PID]="$idx"
    done

    echo ""
    echo "Waiting for wave $wave_num to complete..."

    # Wait for all PIDs and collect results
    wave_success=0
    wave_fail=0
    declare -A FAILED_TASKS=()  # idx -> retry_count (=() keeps ${#..[@]} bound under set -u)

    # Seat heartbeats keep Ops Floor last_event_ts fresh while agents work.
    # Without them the Floor goes STALE after 120s of event silence even when
    # seats are healthy (seat_dispatch … long gap … seat_exit). Override:
    #   FLEET_HEARTBEAT_S=45   (default; set 0 to disable)
    # Must stay under desk_live QUIET_AFTER (90) / STALE_AFTER (120).
    heartbeat_s="${FLEET_HEARTBEAT_S:-45}"

    for pid in "${!WAVE_PIDS[@]}"; do
        idx="${WAVE_PIDS[$pid]}"
        set +e
        if [ "${heartbeat_s:-0}" -gt 0 ] 2>/dev/null; then
            # Emit immediately, then every heartbeat_s until this pid exits.
            while kill -0 "$pid" 2>/dev/null; do
                for hpid in "${!WAVE_PIDS[@]}"; do
                    if kill -0 "$hpid" 2>/dev/null; then
                        hidx="${WAVE_PIDS[$hpid]}"
                        helapsed=$(( $(date +%s) - TASK_START[$hidx] ))
                        fleet_event seat_heartbeat \
                            task_id="$hidx" \
                            agent="${TASK_AGENT[$hidx]}" \
                            branch="${TASK_BRANCH[$hidx]}" \
                            wave="$wave_num" \
                            provider="${RESULT_PROVIDER[$hidx]:-}" \
                            worker="${RESULT_WORKER[$hidx]:-}" \
                            elapsed_s="$helapsed"
                    fi
                done
                # Sleep in short slices so we notice seat exit without
                # full-interval lag, and so Ctrl-C is serviced mid-wave.
                slept=0
                while [ "$slept" -lt "$heartbeat_s" ] && kill -0 "$pid" 2>/dev/null; do
                    sleep "$DISPATCH_WAIT_SLICE_S"
                    slept=$(( slept + DISPATCH_WAIT_SLICE_S ))
                done
            done
        fi
        dispatch_wait_interruptible "$pid"
        status=$?
        set -e

        end_time=$(date +%s)
        duration=$(( end_time - TASK_START[$idx] ))
        RESULT_DURATION[$idx]="${duration}s"

        if [ $status -eq 0 ]; then
            RESULT_STATUS[$idx]="success"
            wave_success=$((wave_success + 1))
            echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$idx]} completed in ${duration}s"
            emit_seat_exit "$idx" success "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "success" 2>/dev/null || true
        elif [ $status -eq 76 ] && [ "${RESULT_STATUS[$idx]}" = out-of-credit ]; then
            emit_seat_exit "$idx" out-of-credit "$status" "$duration"
        elif [ $status -eq 79 ] || [ $status -eq 76 ]; then
            outcome=no-delivery
            if [ "$status" -eq 76 ]; then
                outcome=out-of-credit
                TASK_TRIED_PROVIDERS[$idx]="${TASK_TRIED_PROVIDERS[$idx]:-} ${RESULT_PROVIDER[$idx]}"
            fi
            RESULT_STATUS[$idx]="$outcome"
            FAILED_TASKS[$idx]=0
            emit_seat_exit "$idx" "$outcome" "$status" "$duration"
            echo "  ${TASK_AGENT[$idx]}: $outcome after ${duration}s"
        elif [ $status -eq 77 ]; then
            RESULT_STATUS[$idx]="BLOCKED"
            FAILED_TASKS[$idx]=0
            echo -e "  ${RED}■${NC} ${TASK_AGENT[$idx]} ${RED}BLOCKED by guardrails${NC} after ${duration}s (not retryable)"
            emit_seat_exit "$idx" blocked "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "blocked" 2>/dev/null || true
        elif [ $status -eq 75 ]; then
            # Rate-cap: exclude this vendor and let the retry loop fail over.
            RESULT_STATUS[$idx]="ratecap(${RESULT_PROVIDER[$idx]})"
            FAILED_TASKS[$idx]=0
            TASK_TRIED_PROVIDERS[$idx]="${TASK_TRIED_PROVIDERS[$idx]:-} ${RESULT_PROVIDER[$idx]}"
            echo -e "  ${YELLOW}⏳${NC} ${TASK_AGENT[$idx]} — ${RESULT_PROVIDER[$idx]} rate-capped after ${duration}s (failing over)"
            fleet_event ratecap task_id="$idx" agent="${TASK_AGENT[$idx]}" \
                wave="${TASK_WAVE[$idx]}" provider="${RESULT_PROVIDER[$idx]:-}" \
                worker="${RESULT_WORKER[$idx]:-}" cooldown_minutes="$(get_cooldown_minutes)"
            emit_seat_exit "$idx" ratecap "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "ratecap" "${RESULT_PROVIDER[$idx]}" 2>/dev/null || true
        elif [ $status -eq 69 ]; then
            # Provider CLI missing / not logged in on this worker — per-task
            # exclusion only (not a vendor-wide cooldown).
            RESULT_STATUS[$idx]="unavailable(${RESULT_PROVIDER[$idx]})"
            FAILED_TASKS[$idx]=0
            TASK_TRIED_PROVIDERS[$idx]="${TASK_TRIED_PROVIDERS[$idx]:-} ${RESULT_PROVIDER[$idx]}"
            echo -e "  ${YELLOW}✗${NC} ${TASK_AGENT[$idx]} — ${RESULT_PROVIDER[$idx]} unavailable on ${RESULT_WORKER[$idx]} after ${duration}s (failing over)"
            emit_seat_exit "$idx" unavailable "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
        elif [ $status -eq 78 ]; then
            # Provider spend/session limit (issue #84): held, not failed, and
            # NOT added to FAILED_TASKS: the retry is not burned. run-remote
            # already wrote the hold file; the next seat on this provider and
            # model probes before it starts.
            limit_hold_f="$(limit_hold_file "${RESULT_PROVIDER[$idx]}" "${TASK_MODEL[$idx]:-}")"
            RESULT_STATUS[$idx]="held(${RESULT_PROVIDER[$idx]}/${TASK_MODEL[$idx]:-default})"
            echo -e "  ${YELLOW}⏸${NC} ${TASK_AGENT[$idx]}: ${RESULT_PROVIDER[$idx]} provider limit after ${duration}s (held, resets $(limit_hold_reset "$limit_hold_f"); no retry)"
            limit_hold_stop_open "${RESULT_PROVIDER[$idx]}" "${TASK_MODEL[$idx]:-}" "$limit_hold_f"
            fleet_event provider_limit task_id="$idx" agent="${TASK_AGENT[$idx]}" \
                wave="${TASK_WAVE[$idx]}" provider="${RESULT_PROVIDER[$idx]:-}" \
                model="${TASK_MODEL[$idx]:-default}" reset="$(limit_hold_reset "$limit_hold_f")"
            emit_seat_exit "$idx" held "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
        elif [ $status -eq 124 ]; then
            # Hung seat (issue #92): no model event for the quiet period, or a
            # tool call that ran past the tool ceiling. It goes to the retry
            # loop like a failure but is retried exactly once.
            RESULT_STATUS[$idx]="hung"
            FAILED_TASKS[$idx]=0
            HUNG_TASKS[$idx]=1
            hung_why="emitted no model event for ${SEAT_QUIET_AFTER_S}s"
            hung_reason_f="$PROVIDER_STATE_DIR/seat-hung-$idx.reason"
            if [ -f "$hung_reason_f" ]; then
                hung_why="$(head -1 "$hung_reason_f")"
                rm -f "$hung_reason_f"
            fi
            echo -e "  ${YELLOW}⏳${NC} ${TASK_AGENT[$idx]} $hung_why, stopped after ${duration}s, will retry once"
            stop_open_once "seat-hung-${FLEET_DISPATCH_ID:-run}-$idx" seat_hung \
                "seat ${TASK_AGENT[$idx]} (task $idx, ${TASK_BRANCH[$idx]}) $hung_why; stopped and retried once" \
                "check the log"
            emit_seat_exit "$idx" hung "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
        else
            RESULT_STATUS[$idx]="failed"
            FAILED_TASKS[$idx]=0
            echo -e "  ${RED}✗${NC} ${TASK_AGENT[$idx]} failed (exit $status) after ${duration}s"
            emit_seat_exit "$idx" failed "$status" "$duration"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
        fi
    done

    # Retry failed tasks
    if [ ${#FAILED_TASKS[@]} -gt 0 ] && [ "$MAX_RETRIES" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Retrying failed tasks (max $MAX_RETRIES retries)...${NC}"

        for idx in "${!FAILED_TASKS[@]}"; do
            # Skip BLOCKED tasks — guardrail violations are not retryable
            if [ "${RESULT_STATUS[$idx]}" = "BLOCKED" ]; then
                echo -e "  ${RED}■${NC} ${TASK_AGENT[$idx]} — skipping retry (BLOCKED by guardrails)"
                continue
            fi
            local_attempts=0
            while [ $local_attempts -lt "$MAX_RETRIES" ]; do
                local_attempts=$((local_attempts + 1))
                # A hung seat is retried exactly once, whatever --retries says.
                if [ -n "${HUNG_TASKS[$idx]:-}" ] && [ "$local_attempts" -gt 1 ]; then
                    echo -e "  ${RED}✗${NC} ${TASK_AGENT[$idx]}: hung seat already retried once; giving up"
                    RESULT_STATUS[$idx]="failed (hung, retry used)"
                    break
                fi
                retry_task "$idx" "$local_attempts"
                retry_pid="$DISPATCH_PID"

                TASK_START[$idx]=$(date +%s)
                set +e
                dispatch_wait_interruptible "$retry_pid"
                retry_status=$?
                set -e

                end_time=$(date +%s)
                duration=$(( end_time - TASK_START[$idx] ))
                RESULT_DURATION[$idx]="${duration}s"

                if [ $retry_status -eq 0 ]; then
                    RESULT_STATUS[$idx]="success (retry $local_attempts, ${RESULT_PROVIDER[$idx]})"
                    echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$idx]} succeeded on retry $local_attempts via ${RESULT_PROVIDER[$idx]} in ${duration}s"
                    emit_seat_exit "$idx" success "$retry_status" "$duration"
                    [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "success" 2>/dev/null || true
                    if [ -n "${HUNG_TASKS[$idx]:-}" ]; then
                        stop_clear "seat-hung-${FLEET_DISPATCH_ID:-run}-$idx" "the retry did the work"
                        unset 'HUNG_TASKS[$idx]'
                    fi
                    unset 'FAILED_TASKS[$idx]'
                    break
                elif [ $retry_status -eq 76 ] && [ "${RESULT_STATUS[$idx]}" = out-of-credit ]; then
                    emit_seat_exit "$idx" out-of-credit "$retry_status" "$duration"
                    unset 'FAILED_TASKS[$idx]'
                    break
                elif [ $retry_status -eq 79 ] || [ $retry_status -eq 76 ]; then
                    outcome=no-delivery
                    if [ "$retry_status" -eq 76 ]; then
                        outcome=out-of-credit
                        TASK_TRIED_PROVIDERS[$idx]="${TASK_TRIED_PROVIDERS[$idx]:-} ${RESULT_PROVIDER[$idx]}"
                    fi
                    RESULT_STATUS[$idx]="$outcome"
                    emit_seat_exit "$idx" "$outcome" "$retry_status" "$duration"
                    echo "  ${TASK_AGENT[$idx]} retry $local_attempts: $outcome"
                elif [ $retry_status -eq 78 ]; then
                    # The retry landed on a provider at its spend/session
                    # limit: the seat is held, not failed, and the retry
                    # budget is not burned on a limit.
                    limit_hold_f="$(limit_hold_file "${RESULT_PROVIDER[$idx]}" "${TASK_MODEL[$idx]:-}")"
                    RESULT_STATUS[$idx]="held(${RESULT_PROVIDER[$idx]}/${TASK_MODEL[$idx]:-default})"
                    echo -e "  ${YELLOW}⏸${NC} ${TASK_AGENT[$idx]} retry $local_attempts: ${RESULT_PROVIDER[$idx]} provider limit (held, resets $(limit_hold_reset "$limit_hold_f"))"
                    limit_hold_stop_open "${RESULT_PROVIDER[$idx]}" "${TASK_MODEL[$idx]:-}" "$limit_hold_f"
                    fleet_event provider_limit task_id="$idx" agent="${TASK_AGENT[$idx]}" \
                        wave="${TASK_WAVE[$idx]}" provider="${RESULT_PROVIDER[$idx]:-}" \
                        model="${TASK_MODEL[$idx]:-default}" reset="$(limit_hold_reset "$limit_hold_f")"
                    emit_seat_exit "$idx" held "$retry_status" "$duration"
                    unset 'FAILED_TASKS[$idx]'
                    break
                elif [ $retry_status -eq 75 ] || [ $retry_status -eq 69 ]; then
                    # Still capped/unavailable on this vendor — exclude it so the
                    # next retry's resolve_provider advances down the chain.
                    TASK_TRIED_PROVIDERS[$idx]="${TASK_TRIED_PROVIDERS[$idx]:-} ${RESULT_PROVIDER[$idx]}"
                    [ $retry_status -eq 75 ] && RESULT_STATUS[$idx]="ratecap(${RESULT_PROVIDER[$idx]})" || RESULT_STATUS[$idx]="unavailable(${RESULT_PROVIDER[$idx]})"
                    echo -e "  ${YELLOW}⏳${NC} ${TASK_AGENT[$idx]} retry $local_attempts: ${RESULT_PROVIDER[$idx]} unavailable/capped (failing over)"
                    if [ $retry_status -eq 75 ]; then
                        fleet_event ratecap task_id="$idx" agent="${TASK_AGENT[$idx]}" \
                            wave="${TASK_WAVE[$idx]}" provider="${RESULT_PROVIDER[$idx]:-}" \
                            worker="${RESULT_WORKER[$idx]:-}" cooldown_minutes="$(get_cooldown_minutes)"
                        emit_seat_exit "$idx" ratecap "$retry_status" "$duration"
                    else
                        emit_seat_exit "$idx" unavailable "$retry_status" "$duration"
                    fi
                    [ $retry_status -eq 75 ] && [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "ratecap" "${RESULT_PROVIDER[$idx]}" 2>/dev/null || true
                else
                    echo -e "  ${RED}✗${NC} ${TASK_AGENT[$idx]} retry $local_attempts failed after ${duration}s"
                    emit_seat_exit "$idx" failed "$retry_status" "$duration"
                    [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
                fi
            done
        done
    fi

    # Count final results for this wave
    for idx in "${wave_indices[@]}"; do
        if [[ "${RESULT_STATUS[$idx]}" == success* ]]; then
            TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
        else
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
    done

    # Clean up wave-scoped arrays
    unset WAVE_PIDS TASK_START FAILED_TASKS

    # Compute final wave stats (after retries)
    wave_success_final=0
    wave_fail_final=0
    for idx in "${wave_indices[@]}"; do
        if [[ "${RESULT_STATUS[$idx]}" == success* ]]; then
            wave_success_final=$((wave_success_final + 1))
        else
            wave_fail_final=$((wave_fail_final + 1))
        fi
    done

    echo ""
    echo -e "Wave $wave_num: ${GREEN}$wave_success_final succeeded${NC}"
    if [ $wave_fail_final -gt 0 ]; then
        echo -e "Wave $wave_num: ${RED}$wave_fail_final failed${NC}"
    fi

    fleet_event wave_end wave="$wave_num" seats="${#wave_indices[@]}" \
        succeeded="$wave_success_final" failed="$wave_fail_final"

    # Inter-wave prompt (skip after last wave)
    if [ "$wave_num" != "${SORTED_WAVES[-1]}" ]; then
        echo ""
        # Check for failures in this wave
        has_failures=false
        for idx in "${wave_indices[@]}"; do
            [[ "${RESULT_STATUS[$idx]}" == success* ]] || has_failures=true
        done

        if [ "$has_failures" = true ]; then
            next_wave_f=""
            for w in "${SORTED_WAVES[@]}"; do
                if [ "$w" -gt "$wave_num" ]; then
                    next_wave_f="$w"
                    break
                fi
            done
            echo -e "${YELLOW}WARNING: Some tasks in wave $wave_num failed.${NC}"
            if [ "$AUTO_CONTINUE" = false ]; then
                echo -n "Continue to wave $next_wave_f? [y/N] "
                fleet_event human_wait kind=failure_gate wave="$wave_num" \
                    next_wave="$next_wave_f" waiting_on="continue after failed wave $wave_num?"
                read -r answer
                if [[ ! "$answer" =~ ^[Yy] ]]; then
                    fleet_event human_resume kind=failure_gate wave="$wave_num" answer=abort
                    echo -e "${RED}Aborted by user.${NC}"
                    break
                fi
                fleet_event human_resume kind=failure_gate wave="$wave_num" answer=continue
            else
                echo -e "${YELLOW}--auto: continuing despite failures${NC}"
            fi
        else
            if [ "$AUTO_CONTINUE" = false ]; then
                next_wave=""
                for w in "${SORTED_WAVES[@]}"; do
                    if [ "$w" -gt "$wave_num" ]; then
                        next_wave="$w"
                        break
                    fi
                done
                echo -e "${GREEN}Wave $wave_num complete.${NC} Merge PRs and press Enter for wave $next_wave..."
                fleet_event human_wait kind=wave_gate wave="$wave_num" \
                    next_wave="$next_wave" waiting_on="merge PRs, then start wave $next_wave"
                read -r
                fleet_event human_resume kind=wave_gate wave="$wave_num" answer=continue
            else
                echo -e "${GREEN}Wave $wave_num complete.${NC} --auto: continuing to next wave..."
            fi
        fi
    fi
done

# --------------------------------------------------
# Collect logs from workers
# --------------------------------------------------
mkdir -p "$LOGS_DIR"
echo ""
echo "Collecting agent logs from workers..."

declare -A RESULT_LOG
for i in "${!TASK_AGENT[@]}"; do
    if [ -n "${RESULT_WORKER[$i]:-}" ]; then
        # Find the worker host
        whost=""
        for w in "${WORKER_ARRAY[@]}"; do
            IFS='|' read -r wn wh <<< "$w"
            if [ "$wn" = "${RESULT_WORKER[$i]}" ]; then
                whost="$wh"
                break
            fi
        done

        if [ -n "$whost" ]; then
            repo_name=$(basename "$REPO_URL" .git)
            branch_safe="${TASK_BRANCH[$i]//\//-}"
            if [ "$whost" = "localhost" ] || [ "$whost" = "127.0.0.1" ]; then
                # Ground Truth: single-host fleet still writes logs under
                # ~/dev/agent-logs — collect them into repo logs/ (do not skip).
                local_src=$(ls -t "$HOME/dev/agent-logs/${repo_name}-${branch_safe}-"*.log 2>/dev/null | head -1 || true)
                if [ -n "${local_src:-}" ] && [ -f "$local_src" ]; then
                    local_log="$LOGS_DIR/$(basename "$local_src")"
                    if cp "$local_src" "$local_log" 2>/dev/null; then
                        RESULT_LOG[$i]="$local_log"
                        echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$i]}: $(basename "$local_log") (localhost)"
                    else
                        # Fall back to original path if copy fails
                        RESULT_LOG[$i]="$local_src"
                        echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$i]}: $local_src (localhost, in-place)"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} ${TASK_AGENT[$i]}: no log found in ~/dev/agent-logs (localhost)"
                fi
            else
                # Find the most recent matching log on the remote worker
                remote_log=$(ssh -o ConnectTimeout=5 "$whost" "ls -t ~/dev/agent-logs/${repo_name}-${branch_safe}-*.log 2>/dev/null | head -1" 2>/dev/null || echo "")
                if [ -n "$remote_log" ]; then
                    local_log="$LOGS_DIR/$(basename "$remote_log")"
                    if scp -o ConnectTimeout=5 "$whost:$remote_log" "$local_log" 2>/dev/null; then
                        RESULT_LOG[$i]="$local_log"
                        echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$i]}: $(basename "$local_log")"
                    else
                        echo -e "  ${YELLOW}!${NC} ${TASK_AGENT[$i]}: failed to copy log"
                    fi
                else
                    echo -e "  ${YELLOW}-${NC} ${TASK_AGENT[$i]}: no log found on $whost"
                fi
            fi
        fi
    fi
done

# --------------------------------------------------
# Per-dispatch launcher runtime: gone with the dispatch (localhost only; a
# remote worker's copy is left to the daily seat worktree sweep)
# --------------------------------------------------
if [ -n "${FLEET_DISPATCH_ID:-}" ] && dispatch_lock_uses_localhost; then
    rm -rf "$HOME/dev/agent-runtime/${FLEET_DISPATCH_ID}" 2>/dev/null || true
fi

# --------------------------------------------------
# Save wave plan state
# --------------------------------------------------
mkdir -p "$WAVE_PLANS_DIR"
REPO_SLUG_SHORT=$(basename "$REPO_URL" .git)
PLAN_DATE=$(date +%Y%m%d)

# Save the plan file
PLAN_STATE="$WAVE_PLANS_DIR/${REPO_SLUG_SHORT}-${PLAN_DATE}.plan"
{
    echo "# Wave plan for $REPO_SLUG_SHORT — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Generated by dispatch.sh"
    echo ""
    for i in "${!TASK_AGENT[@]}"; do
        echo "${TASK_WAVE[$i]} | ${TASK_AGENT[$i]} | ${TASK_DESC[$i]} | ${TASK_BRANCH[$i]}"
    done
} > "$PLAN_STATE"

# Save execution log
EXEC_LOG="$WAVE_PLANS_DIR/${REPO_SLUG_SHORT}-${PLAN_DATE}.log"
{
    echo "# Execution log for $REPO_SLUG_SHORT — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Repo: $REPO_URL"
    echo ""
    printf "%-4s %-5s %-18s %-8s %-8s %-30s %-14s %-10s %-25s %s\n" "#" "Wave" "Agent" "Provider" "Model" "Branch" "Worker" "Duration" "Status" "Log"
    printf "%-4s %-5s %-18s %-8s %-8s %-30s %-14s %-10s %-25s %s\n" "---" "----" "-----------------" "-------" "-------" "-----------------------------" "-------------" "---------" "------------------------" "---"
    for i in "${!TASK_AGENT[@]}"; do
        printf "%-4s %-5s %-18s %-8s %-8s %-30s %-14s %-10s %-25s %s\n" \
            "$i" "${TASK_WAVE[$i]}" "${TASK_AGENT[$i]}" "${RESULT_PROVIDER[$i]:-n/a}" "${TASK_MODEL[$i]:-}" "${TASK_BRANCH[$i]}" \
            "${RESULT_WORKER[$i]:-n/a}" "${RESULT_DURATION[$i]:-n/a}" \
            "${RESULT_STATUS[$i]:-unknown}" "${RESULT_LOG[$i]:-none}"
    done
} > "$EXEC_LOG"

echo ""
echo -e "Plan saved:  ${CYAN}$PLAN_STATE${NC}"
echo -e "Exec log:    ${CYAN}$EXEC_LOG${NC}"

# --------------------------------------------------
# Final report
# --------------------------------------------------
OVERALL_END=$(date +%s)
OVERALL_DURATION=$(( OVERALL_END - OVERALL_START ))

echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Dispatch Results${NC}"
echo -e "${BOLD}==========================================${NC}"
# Log filenames only — the Floor links a name, never a transcript body.
for i in "${!TASK_AGENT[@]}"; do
    if [ -n "${RESULT_LOG[$i]:-}" ]; then
        fleet_event seat_log task_id="$i" agent="${TASK_AGENT[$i]}" \
            log="$(basename "${RESULT_LOG[$i]}")"
    fi
done

fleet_close_dispatch completed
dispatch_lock_release
trap - EXIT INT TERM HUP

echo ""
echo -e "Total duration: ${OVERALL_DURATION}s"
echo -e "Tasks: ${GREEN}$TOTAL_SUCCESS/$TOTAL_TASKS succeeded${NC}, ${RED}$TOTAL_FAIL failed${NC}"
echo ""

# Per-task report
printf "%-4s %-5s %-18s %-8s %-30s %-14s %-10s %-25s %s\n" "#" "Wave" "Agent" "Model" "Branch" "Worker" "Duration" "Status" "Log"
printf "%-4s %-5s %-18s %-8s %-30s %-14s %-10s %-25s %s\n" "---" "----" "-----------------" "-------" "-----------------------------" "-------------" "---------" "------------------------" "---"

for i in "${!TASK_AGENT[@]}"; do
    status="${RESULT_STATUS[$i]:-unknown}"
    if [[ "$status" == success* ]]; then
        status_colored="${GREEN}${status}${NC}"
    else
        status_colored="${RED}${status}${NC}"
    fi
    log_path="${RESULT_LOG[$i]:-none}"
    [ "$log_path" != "none" ] && log_path="$(basename "$log_path")"
    printf "%-4s %-5s %-18s %-8s %-30s %-14s %-10s " \
        "$i" "${TASK_WAVE[$i]}" "${TASK_AGENT[$i]}" "${TASK_MODEL[$i]:-}" "${TASK_BRANCH[$i]}" \
        "${RESULT_WORKER[$i]:-n/a}" "${RESULT_DURATION[$i]:-n/a}"
    echo -e "$status_colored  $log_path"
done

echo ""

if [ -d "$LOGS_DIR" ] && ls "$LOGS_DIR"/*.log >/dev/null 2>&1; then
    echo -e "Logs collected in: ${CYAN}$LOGS_DIR/${NC}"
fi

# List branches/PRs
REPO_SLUG=$(echo "$REPO_URL" | sed 's/.*://' | sed 's/\.git//')
echo ""
echo "Branches created:"
for i in "${!TASK_BRANCH[@]}"; do
    if [[ "${RESULT_STATUS[$i]:-}" == success* ]]; then
        echo -e "  ${GREEN}✓${NC} ${TASK_BRANCH[$i]}"
    fi
done

echo ""
echo -e "Check PRs: ${CYAN}gh pr list -R $REPO_SLUG${NC}"

# --------------------------------------------------
# Commit wave plan state
# --------------------------------------------------
if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_DIR" add "$PLAN_STATE" "$EXEC_LOG" 2>/dev/null || true
    git -C "$REPO_DIR" commit -m "dispatch: save wave plan for ${REPO_SLUG_SHORT} ($(date +%Y-%m-%d))" \
        "$PLAN_STATE" "$EXEC_LOG" 2>/dev/null || true
fi

# Normal end: the close-out traps were disarmed above, so leave the code here.
dispatch_run_note_exit 0
