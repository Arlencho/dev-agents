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

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)
            AUTO_CONTINUE=true
            shift
            ;;
        --retries)
            MAX_RETRIES="${2:?--retries requires a number}"
            shift 2
            ;;
        --review)
            REVIEW_PLAN=true
            shift
            ;;
        --retry-on-different-worker)
            RETRY_DIFFERENT_WORKER=true
            shift
            ;;
        --skip-auth-preflight)
            SKIP_AUTH_PREFLIGHT=true
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

# --------------------------------------------------
# Get provider preference for an agent
# --------------------------------------------------
get_provider() {
    local agent="$1"
    local in_prefs=false
    local default_provider="claude"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*provider_preferences: ]]; then
            in_prefs=true
            continue
        fi
        if [ "$in_prefs" = true ]; then
            # Stop when we hit a non-indented line (next top-level key)
            if [[ "$line" =~ ^[a-zA-Z] ]]; then
                in_prefs=false
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*${agent}:[[:space:]]*(.*) ]]; then
                echo "${BASH_REMATCH[1]}"
                return
            fi
            if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*(.*) ]]; then
                default_provider="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$CONFIG"
    echo "$default_provider"
}

# --------------------------------------------------
# Get the failover chain for an agent from routing.yaml provider_failover:.
# Returns space-separated vendors (agent-specific, else default:, else empty).
# --------------------------------------------------
get_failover_chain() {
    local agent="$1"
    [ -f "$ROUTING_CONFIG" ] || { echo ""; return; }
    local in_block=false default_chain=""
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*provider_failover: ]]; then in_block=true; continue; fi
        if [ "$in_block" = true ]; then
            [[ "$line" =~ ^[a-zA-Z] ]] && { in_block=false; continue; }
            if [[ "$line" =~ ^[[:space:]]*${agent}:[[:space:]]*\[(.*)\] ]]; then
                echo "${BASH_REMATCH[1]}" | tr ',' ' '; return
            fi
            if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*\[(.*)\] ]]; then
                default_chain=$(echo "${BASH_REMATCH[1]}" | tr ',' ' ')
            fi
        fi
    done < "$ROUTING_CONFIG"
    echo "$default_chain"
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
# Never deadlocks — if every candidate is excluded/cooling, returns the primary
# anyway (same philosophy as find_worker's forced third pass).
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
        echo "$candidate"; return 0
    done
    echo "$primary"
}

# --------------------------------------------------
# Get model tier for an agent from routing.yaml
# Returns tier alias (opus/sonnet/haiku) or explicit model ID.
# Returns empty string if no routing config — caller should skip --model
# and let claude use its default.
# --------------------------------------------------
get_model() {
    local agent="$1"
    [ -f "$ROUTING_CONFIG" ] || { echo ""; return; }
    local in_routing=false
    local default_model=""
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*model_routing: ]]; then
            in_routing=true
            continue
        fi
        if [ "$in_routing" = true ]; then
            # Stop when we hit a non-indented line (next top-level key)
            if [[ "$line" =~ ^[a-zA-Z] ]]; then
                in_routing=false
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*${agent}:[[:space:]]*(.*) ]]; then
                # Strip inline comments and whitespace (Ground Truth: clean AGENT_MODEL)
                local val="${BASH_REMATCH[1]}"
                val="${val%%#*}"
                val="${val// /}"
                val="${val//$'\t'/}"
                echo "$val"
                return
            fi
            if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*(.*) ]]; then
                default_model="${BASH_REMATCH[1]}"
                default_model="${default_model%%#*}"
                default_model="${default_model// /}"
                default_model="${default_model//$'\t'/}"
            fi
        fi
    done < "$ROUTING_CONFIG"
    echo "$default_model"
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

echo "Tasks to dispatch: ${#TASKS[@]}"
echo ""

# --------------------------------------------------
# Parse tasks into waves
# --------------------------------------------------
# Detect format: if first field of first task is a number, it's wave-aware
# Otherwise, all tasks go to wave 1
detect_wave_format() {
    local first_line="$1"
    local fields
    IFS='|' read -ra fields <<< "$first_line"
    local first_field
    first_field=$(echo "${fields[0]}" | xargs)
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
    [ "$n" -ge 1 ] && last=$(echo "${fields[$((n-1))]}" | xargs)
    is_branch=false
    case "$last" in
        */*) case "$last" in *[!A-Za-z0-9/_.-]*) is_branch=false ;; *) is_branch=true ;; esac ;;
    esac

    if [ "$FORMAT" = "wave" ]; then
        wave=$(echo "${fields[0]}" | xargs)
        agent=$(echo "${fields[1]}" | xargs)
        start=2
    else
        wave=1
        agent=$(echo "${fields[0]}" | xargs)
        start=1
    fi

    branch=""
    if [ "$is_branch" = true ] && [ "$n" -gt $((start + 1)) ]; then
        branch="$last"
        desc=$(IFS='|'; echo "${fields[*]:$start:$((n - start - 1))}")
    else
        desc=$(IFS='|'; echo "${fields[*]:$start}")
    fi
    desc=$(echo "$desc" | xargs)

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
fleet_events_init "$REPO_SLUG_EVENTS" "$DISPATCH_MODE" "$PLAN_SOURCE"
fleet_event dispatch_plan waves="${#SORTED_WAVES[@]}" seats="${#TASK_AGENT[@]}" format="$FORMAT"
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
}
# EXIT covers normal and error exits; the INT/TERM traps make the close-out
# ordering explicit on Ctrl-C / kill and pin the conventional 130/143 exit
# codes instead of relying on the shell's signal-death behavior (whether an
# EXIT trap runs on fatal signals varies by shell and version — measured here:
# bash 3.2 and 5.3 both run it, but nothing guarantees it). The
# FLEET_DISPATCH_CLOSED guard keeps the later EXIT trap a no-op after a
# signal close-out.
trap 'fleet_close_dispatch aborted' EXIT
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
                v=$(echo "$v" | xargs)
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
    # Count all three vendor CLIs — a worker may be running kimi/grok agents too.
    # `pgrep … | wc -l` (not `pgrep -c`) — BSD/macOS pgrep has no -c flag; the
    # old `pgrep -c claude` silently returned 0 on Mac workers via the fallback.
    running=$(ssh -o ConnectTimeout=5 "$host" "pgrep -fl 'claude|kimi|grok' 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo 0)
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
    provider=$(resolve_provider "$agent" "${TASK_TRIED_PROVIDERS[$idx]:-}")
    RESULT_PROVIDER[$idx]="$provider"

    local model="${TASK_MODEL[$idx]:-}"

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
    (
        AGENT_MODEL="$model" AGENT_PROVIDER="$provider" AGENT_WAVE="${CURRENT_WAVE:-1}" \
            "$SCRIPT_DIR/run-remote.sh" "$whost" "$REPO_URL" "$agent" "$task" "$branch"
    ) &
    DISPATCH_PID=$!
}

# --------------------------------------------------
# Seat outcome → event stream
# --------------------------------------------------
# fleet_seat_exit <idx> <status> <exit_code> <duration_s>
# status: success | failed | blocked | ratecap | unavailable
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
BACKOFF_DELAYS=(10 30)

retry_task() {
    local idx="$1"
    local attempt="$2"
    local agent="${TASK_AGENT[$idx]}"
    local task="${TASK_DESC[$idx]}"
    local branch="${TASK_BRANCH[$idx]}"

    local delay_idx=$((attempt - 1))
    local delay=${BACKOFF_DELAYS[$delay_idx]:-30}

    echo -e "  ${YELLOW}Retrying${NC} task $idx ($agent) in ${delay}s [attempt $((attempt + 1))/$((MAX_RETRIES + 1))]..." >&2
    sleep "$delay"

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
                # Sleep in short chunks so we notice seat exit without full-interval lag.
                slept=0
                while [ "$slept" -lt "$heartbeat_s" ]; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 5
                    slept=$((slept + 5))
                done
            done
            wait "$pid"
            status=$?
        else
            wait "$pid"
            status=$?
        fi
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
                retry_task "$idx" "$local_attempts"
                retry_pid="$DISPATCH_PID"

                TASK_START[$idx]=$(date +%s)
                set +e
                wait "$retry_pid"
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
trap - EXIT INT TERM

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
