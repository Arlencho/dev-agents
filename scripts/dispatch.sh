#!/bin/bash
set -euo pipefail

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

# --------------------------------------------------
# Usage
# --------------------------------------------------
usage() {
    echo "Usage: dispatch.sh <repo-url> <plan-file|--interactive> [flags]"
    echo ""
    echo "Flags:"
    echo "  --auto                       Auto-continue between waves (no prompt)"
    echo "  --retries N                  Max retries per task (default: 2)"
    echo "  --retry-on-different-worker  Retry failed tasks on a different worker"
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
        --retry-on-different-worker)
            RETRY_DIFFERENT_WORKER=true
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
declare -a TASK_WAVE TASK_AGENT TASK_DESC TASK_BRANCH

for i in "${!TASKS[@]}"; do
    task_line="${TASKS[$i]}"
    IFS='|' read -ra fields <<< "$task_line"

    if [ "$FORMAT" = "wave" ]; then
        wave=$(echo "${fields[0]}" | xargs)
        agent=$(echo "${fields[1]}" | xargs)
        desc=$(echo "${fields[2]}" | xargs)
        branch=$(echo "${fields[3]:-}" | xargs)
    else
        wave=1
        agent=$(echo "${fields[0]}" | xargs)
        desc=$(echo "${fields[1]}" | xargs)
        branch=$(echo "${fields[2]:-}" | xargs)
    fi

    branch="${branch:-fix/$agent-$(date +%s)}"

    TASK_WAVE[$i]="$wave"
    TASK_AGENT[$i]="$agent"
    TASK_DESC[$i]="$desc"
    TASK_BRANCH[$i]="$branch"

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
    running=$(ssh -o ConnectTimeout=5 "$host" "pgrep -c claude 2>/dev/null || echo 0" 2>/dev/null || echo 0)
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

# --------------------------------------------------
# Dispatch a single task, returns PID
# --------------------------------------------------
dispatch_task() {
    local idx="$1"
    local agent="${TASK_AGENT[$idx]}"
    local task="${TASK_DESC[$idx]}"
    local branch="${TASK_BRANCH[$idx]}"
    local exclude_worker="${2:-}"

    local worker_info
    worker_info=$(find_worker "$agent" "$exclude_worker")
    IFS='|' read -r wname whost <<< "$worker_info"

    local provider
    provider=$(get_provider "$agent")

    local is_preferred=""
    preferred=$(get_preferred_agents "$wname")
    if ! echo "$preferred" | grep -q "^${agent}$"; then
        is_preferred=" (round-robin)"
    fi

    echo -e "  ${CYAN}→${NC} $wname ($whost): ${BOLD}$agent${NC} [${provider}] — \"$task\" [$branch]$is_preferred" >&2

    RESULT_WORKER[$idx]="$wname"
    RESULT_BRANCH[$idx]="$branch"

    # Run in subshell to capture exit code
    (
        "$SCRIPT_DIR/run-remote.sh" "$whost" "$REPO_URL" "$agent" "$task" "$branch"
    ) &
    echo $!
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

    dispatch_task "$idx" "$exclude"
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

    echo -e "${BOLD}------------------------------------------${NC}"
    echo -e "${BOLD}  Wave $wave_num — ${#wave_indices[@]} task(s)${NC}"
    echo -e "${BOLD}------------------------------------------${NC}"
    echo ""
    echo "Dispatching..."

    # Track PIDs for this wave
    declare -A WAVE_PIDS  # pid -> task_idx
    declare -A TASK_START # idx -> epoch

    for idx in "${wave_indices[@]}"; do
        TASK_START[$idx]=$(date +%s)
        pid=$(dispatch_task "$idx")
        WAVE_PIDS[$pid]="$idx"
    done

    echo ""
    echo "Waiting for wave $wave_num to complete..."

    # Wait for all PIDs and collect results
    wave_success=0
    wave_fail=0
    declare -A FAILED_TASKS  # idx -> retry_count

    for pid in "${!WAVE_PIDS[@]}"; do
        idx="${WAVE_PIDS[$pid]}"
        set +e
        wait "$pid"
        status=$?
        set -e

        end_time=$(date +%s)
        duration=$(( end_time - TASK_START[$idx] ))
        RESULT_DURATION[$idx]="${duration}s"

        if [ $status -eq 0 ]; then
            RESULT_STATUS[$idx]="success"
            wave_success=$((wave_success + 1))
            echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$idx]} completed in ${duration}s"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "success" 2>/dev/null || true
        else
            RESULT_STATUS[$idx]="failed"
            FAILED_TASKS[$idx]=0
            echo -e "  ${RED}✗${NC} ${TASK_AGENT[$idx]} failed (exit $status) after ${duration}s"
            [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "failure" 2>/dev/null || true
        fi
    done

    # Retry failed tasks
    if [ ${#FAILED_TASKS[@]} -gt 0 ] && [ "$MAX_RETRIES" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Retrying failed tasks (max $MAX_RETRIES retries)...${NC}"

        for idx in "${!FAILED_TASKS[@]}"; do
            local_attempts=0
            while [ $local_attempts -lt "$MAX_RETRIES" ]; do
                local_attempts=$((local_attempts + 1))
                retry_pid=$(retry_task "$idx" "$local_attempts")

                TASK_START[$idx]=$(date +%s)
                set +e
                wait "$retry_pid"
                retry_status=$?
                set -e

                end_time=$(date +%s)
                duration=$(( end_time - TASK_START[$idx] ))
                RESULT_DURATION[$idx]="${duration}s"

                if [ $retry_status -eq 0 ]; then
                    RESULT_STATUS[$idx]="success (retry $local_attempts)"
                    echo -e "  ${GREEN}✓${NC} ${TASK_AGENT[$idx]} succeeded on retry $local_attempts in ${duration}s"
                    [ -x "$NOTIFY_SCRIPT" ] && "$NOTIFY_SCRIPT" "${TASK_AGENT[$idx]}" "${RESULT_WORKER[$idx]}" "${TASK_BRANCH[$idx]}" "success" 2>/dev/null || true
                    unset 'FAILED_TASKS[$idx]'
                    break
                else
                    echo -e "  ${RED}✗${NC} ${TASK_AGENT[$idx]} retry $local_attempts failed after ${duration}s"
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
                read -r answer
                if [[ ! "$answer" =~ ^[Yy] ]]; then
                    echo -e "${RED}Aborted by user.${NC}"
                    break
                fi
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
                read -r
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

        if [ -n "$whost" ] && [ "$whost" != "localhost" ] && [ "$whost" != "127.0.0.1" ]; then
            repo_name=$(basename "$REPO_URL" .git)
            branch_safe="${TASK_BRANCH[$i]//\//-}"
            # Find the most recent matching log on the worker
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
    printf "%-4s %-5s %-18s %-30s %-14s %-10s %-25s %s\n" "#" "Wave" "Agent" "Branch" "Worker" "Duration" "Status" "Log"
    printf "%-4s %-5s %-18s %-30s %-14s %-10s %-25s %s\n" "---" "----" "-----------------" "-----------------------------" "-------------" "---------" "------------------------" "---"
    for i in "${!TASK_AGENT[@]}"; do
        printf "%-4s %-5s %-18s %-30s %-14s %-10s %-25s %s\n" \
            "$i" "${TASK_WAVE[$i]}" "${TASK_AGENT[$i]}" "${TASK_BRANCH[$i]}" \
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
echo ""
echo -e "Total duration: ${OVERALL_DURATION}s"
echo -e "Tasks: ${GREEN}$TOTAL_SUCCESS/$TOTAL_TASKS succeeded${NC}, ${RED}$TOTAL_FAIL failed${NC}"
echo ""

# Per-task report
printf "%-4s %-5s %-18s %-30s %-14s %-10s %-25s %s\n" "#" "Wave" "Agent" "Branch" "Worker" "Duration" "Status" "Log"
printf "%-4s %-5s %-18s %-30s %-14s %-10s %-25s %s\n" "---" "----" "-----------------" "-----------------------------" "-------------" "---------" "------------------------" "---"

for i in "${!TASK_AGENT[@]}"; do
    status="${RESULT_STATUS[$i]:-unknown}"
    if [[ "$status" == success* ]]; then
        status_colored="${GREEN}${status}${NC}"
    else
        status_colored="${RED}${status}${NC}"
    fi
    log_path="${RESULT_LOG[$i]:-none}"
    [ "$log_path" != "none" ] && log_path="$(basename "$log_path")"
    printf "%-4s %-5s %-18s %-30s %-14s %-10s " \
        "$i" "${TASK_WAVE[$i]}" "${TASK_AGENT[$i]}" "${TASK_BRANCH[$i]}" \
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
