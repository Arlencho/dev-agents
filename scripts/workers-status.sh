#!/bin/bash
set -euo pipefail

# Fleet-wide health check for worker machines.
# Reads config/workers.yaml and checks each machine's status via SSH.
#
# Usage:
#   ./scripts/workers-status.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$REPO_DIR/config/workers.yaml"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
TOTAL=0
ONLINE=0
OFFLINE=0
TOTAL_AGENTS=0
TOTAL_MAX=0

# --------------------------------------------------
# Parse workers.yaml (simple grep-based — no yq dependency)
# --------------------------------------------------
parse_machines() {
    local in_machine=false
    local name="" host="" role="" max_agents=""
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
            # Emit previous machine
            if [ "$in_machine" = true ] && [ -n "$name" ] && [ -n "$host" ]; then
                echo "$name|$host|$role|$max_agents"
            fi
            name="${BASH_REMATCH[1]}"
            host="" role="" max_agents="4"
            in_machine=true
        elif [[ "$line" =~ ^[[:space:]]*host:[[:space:]]*(.*) ]]; then
            host="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*role:[[:space:]]*(.*) ]]; then
            role="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*max_agents:[[:space:]]*(.*) ]]; then
            max_agents="${BASH_REMATCH[1]}"
        fi
    done < "$CONFIG"
    # Last entry
    if [ "$in_machine" = true ] && [ -n "$name" ] && [ -n "$host" ]; then
        echo "$name|$host|$role|$max_agents"
    fi
}

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: No worker config found at $CONFIG"
    exit 1
fi

echo "=========================================="
echo "  Worker Fleet Status"
echo "=========================================="
echo ""

printf "  ${BOLD}%-18s %-14s %-10s %-10s %-12s %s${NC}\n" "NAME" "STATUS" "ROLE" "AGENTS" "DISK FREE" "LAST PUSH"
printf "  %-18s %-14s %-10s %-10s %-12s %s\n" "----" "------" "----" "------" "---------" "---------"

while IFS='|' read -r name host role max_agents; do
    TOTAL=$((TOTAL + 1))
    TOTAL_MAX=$((TOTAL_MAX + max_agents))

    # Check if this is localhost (orchestrator)
    is_local=false
    if [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ]; then
        is_local=true
    fi

    # SSH ping (5 second timeout)
    if [ "$is_local" = true ]; then
        reachable=true
    elif ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "echo ok" >/dev/null 2>&1; then
        reachable=true
    else
        reachable=false
    fi

    if [ "$reachable" = false ]; then
        OFFLINE=$((OFFLINE + 1))
        printf "  %-18s ${RED}%-14s${NC} %-10s %-10s %-12s %s\n" "$name" "OFFLINE" "$role" "-" "-" "-"
        continue
    fi

    ONLINE=$((ONLINE + 1))

    # Gather info (local or remote)
    if [ "$is_local" = true ]; then
        running_agents=$(pgrep -fc "claude" 2>/dev/null || echo "0")
        disk_free=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
        last_push=$(git -C "$REPO_DIR" log --oneline -1 --format="%ar" 2>/dev/null || echo "unknown")
    else
        info=$(ssh -o ConnectTimeout=5 "$host" bash -s <<'REMOTE'
            agents=$(pgrep -fc "claude" 2>/dev/null || echo "0")
            disk=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
            pushtime=$(git -C ~/dev/dev-agents log --oneline -1 --format="%ar" 2>/dev/null || echo "unknown")
            echo "$agents|$disk|$pushtime"
REMOTE
        ) 2>/dev/null || info="0|unknown|unknown"
        IFS='|' read -r running_agents disk_free last_push <<< "$info"
    fi

    TOTAL_AGENTS=$((TOTAL_AGENTS + running_agents))

    # Determine status color
    if [ "$running_agents" -ge "$max_agents" ] 2>/dev/null; then
        status_color="$YELLOW"
        status="BUSY ($running_agents/$max_agents)"
    else
        status_color="$GREEN"
        status="ONLINE ($running_agents/$max_agents)"
    fi

    printf "  %-18s ${status_color}%-14s${NC} %-10s %-10s %-12s %s\n" \
        "$name" "$status" "$role" "$running_agents/$max_agents" "$disk_free" "$last_push"

done <<< "$(parse_machines)"

# --------------------------------------------------
# Summary
# --------------------------------------------------
AVAILABLE=$((TOTAL_MAX - TOTAL_AGENTS))
echo ""
echo "---"
echo "Summary: $ONLINE/$TOTAL online, $TOTAL_AGENTS agents running, $AVAILABLE slots available"

if [ "$OFFLINE" -gt 0 ]; then
    echo -e "${RED}WARNING: $OFFLINE machine(s) offline${NC}"
fi
