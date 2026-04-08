#!/bin/bash
set -euo pipefail

# Dispatch agent tasks to worker machines from a wave plan.
# Reads worker config from config/workers.yaml.
#
# Usage:
#   ./scripts/dispatch.sh <repo-url> <plan-file>
#   ./scripts/dispatch.sh <repo-url> --interactive
#
# Plan file format (one task per line):
#   <agent> | <task description> | [branch-name]
#
# Example plan.txt:
#   go-backend | implement payment service | feat/payments-svc
#   web-frontend | build checkout page | feat/payments-ui
#   db-architect | create payments migration | feat/payments-db
#
# Interactive mode: paste tasks line by line, Ctrl+D when done.
#
# The script assigns each task to the best available worker based on
# preferred_agents in config/workers.yaml, then runs them via SSH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$REPO_DIR/config/workers.yaml"

REPO_URL="${1:?Usage: dispatch.sh <repo-url> <plan-file|--interactive>}"
PLAN_SOURCE="${2:?Usage: dispatch.sh <repo-url> <plan-file|--interactive>}"

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

# --------------------------------------------------
# Load workers
# --------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: No worker config found at $CONFIG"
    echo "Run setup-machine.sh on your Mac Minis first, then edit config/workers.yaml"
    exit 1
fi

WORKERS=$(get_workers)
if [ -z "$WORKERS" ]; then
    echo "ERROR: No workers configured in $CONFIG"
    echo "Uncomment and fill in the mac-mini entries in config/workers.yaml"
    exit 1
fi

echo "=========================================="
echo "  Agent Dispatch"
echo "=========================================="
echo ""
echo "Repo: $REPO_URL"
echo ""
echo "Available workers:"
echo "$WORKERS" | while IFS='|' read -r name host; do
    # Check SSH connectivity
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo ok" >/dev/null 2>&1; then
        echo "  $name ($host) — online"
    else
        echo "  $name ($host) — OFFLINE"
    fi
done
echo ""

# --------------------------------------------------
# Read plan
# --------------------------------------------------
TASKS=()
if [ "$PLAN_SOURCE" = "--interactive" ]; then
    echo "Enter tasks (one per line, format: agent | task description | branch-name)"
    echo "Press Ctrl+D when done."
    echo ""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        TASKS+=("$line")
    done
else
    if [ ! -f "$PLAN_SOURCE" ]; then
        echo "ERROR: Plan file not found: $PLAN_SOURCE"
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

echo ""
echo "Tasks to dispatch: ${#TASKS[@]}"
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

dispatch_task() {
    local agent="$1"
    local task="$2"
    local branch="$3"

    # Try to find a worker that prefers this agent
    local assigned=false
    for w in "${WORKER_ARRAY[@]}"; do
        IFS='|' read -r wname whost <<< "$w"
        preferred=$(get_preferred_agents "$wname")
        if echo "$preferred" | grep -q "^${agent}$"; then
            echo "  → $wname ($whost): $agent — \"$task\" [$branch]"
            "$SCRIPT_DIR/run-remote.sh" "$whost" "$REPO_URL" "$agent" "$task" "$branch" &
            assigned=true
            break
        fi
    done

    # Round-robin fallback if no preferred match
    if [ "$assigned" = false ]; then
        IFS='|' read -r wname whost <<< "${WORKER_ARRAY[$WORKER_IDX]}"
        echo "  → $wname ($whost): $agent — \"$task\" [$branch] (round-robin)"
        "$SCRIPT_DIR/run-remote.sh" "$whost" "$REPO_URL" "$agent" "$task" "$branch" &
        WORKER_IDX=$(( (WORKER_IDX + 1) % WORKER_COUNT ))
    fi
}

echo "Dispatching..."
echo ""

for task_line in "${TASKS[@]}"; do
    IFS='|' read -r agent task branch <<< "$task_line"
    agent=$(echo "$agent" | xargs)  # trim whitespace
    task=$(echo "$task" | xargs)
    branch=$(echo "${branch:-fix/$agent-$(date +%s)}" | xargs)
    dispatch_task "$agent" "$task" "$branch"
done

echo ""
echo "All tasks dispatched. Waiting for completion..."
wait

echo ""
echo "=========================================="
echo "  All agents finished"
echo "=========================================="
echo ""
echo "Check PRs: gh pr list -R $(echo "$REPO_URL" | sed 's/.*://' | sed 's/\.git//')"
