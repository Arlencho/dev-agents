#!/bin/bash
set -uo pipefail

# Provider scorecard — read-only. Summarizes cross-vendor health:
#   - current cooldown state per vendor (from logs/provider-state/*.cooldown)
#   - rate-cap event counts + last event (from logs/provider-state/ratecap.log)
#   - task success/failure per provider (from wave-plans/*.log Provider column)
#
# Usage: ./scripts/provider-scorecard.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$REPO_DIR/logs/provider-state"
WAVE_PLANS_DIR="$REPO_DIR/wave-plans"
ROUTING_CONFIG="$REPO_DIR/config/routing.yaml"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
VENDORS="claude kimi grok"

cooldown_minutes() {
    local v
    v=$(grep -A2 '^rate_caps:' "$ROUTING_CONFIG" 2>/dev/null \
        | grep -oE 'cooldown_minutes:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    echo "${v:-60}"
}

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}  Provider Scorecard${NC}"
echo -e "${BOLD}==========================================${NC}"
echo ""

# ---- Current state ----
MINS=$(cooldown_minutes)
NOW=$(date +%s)
echo -e "${BOLD}State${NC} (cooldown window: ${MINS}m)"
for v in $VENDORS; do
    f="$STATE_DIR/${v}.cooldown"
    if [ -f "$f" ]; then
        ts=$(cat "$f" 2>/dev/null || echo 0)
        elapsed=$(( (NOW - ts) / 60 ))
        remaining=$(( MINS - elapsed ))
        if [ "$remaining" -gt 0 ]; then
            echo -e "  ${YELLOW}COOLING${NC}  $v  (${remaining}m remaining)"
        else
            echo -e "  ${GREEN}OK${NC}       $v"
        fi
    else
        echo -e "  ${GREEN}OK${NC}       $v"
    fi
done
echo ""

# ---- Rate-cap events ----
echo -e "${BOLD}Rate-cap events${NC}"
RATECAP_LOG="$STATE_DIR/ratecap.log"
if [ -f "$RATECAP_LOG" ] && [ -s "$RATECAP_LOG" ]; then
    # grep -c prints a count AND exits 1 on zero matches — no `|| echo 0` (that
    # would double the value); the var is always a bare integer.
    for v in $VENDORS; do
        count=$(grep -c "|$v|" "$RATECAP_LOG" 2>/dev/null)
        last=$(grep "|$v|" "$RATECAP_LOG" 2>/dev/null | tail -1 | cut -d'|' -f1)
        [ "${count:-0}" -gt 0 ] && echo -e "  $v: ${RED}$count${NC} event(s), last $last"
    done
    total=$(grep -c '|ratecap' "$RATECAP_LOG" 2>/dev/null)
    echo "  total: ${total:-0}"
else
    echo -e "  ${GREEN}none recorded${NC}"
fi
echo ""

# ---- Task outcomes per provider (from exec logs) ----
echo -e "${BOLD}Task outcomes per provider${NC} (from wave-plans/*.log)"
if ls "$WAVE_PLANS_DIR"/*.log >/dev/null 2>&1; then
    # Exec-log columns: # Wave Agent Provider Model Branch Worker Duration Status Log
    # Provider is field 4; Status is field 9+ (may contain spaces) — read robustly.
    awk '
        /^#/ || /^---/ || /^[[:space:]]*$/ { next }
        /^[0-9]/ {
            prov=$4; st=$9
            key=prov
            if (st ~ /^success/)      ok[key]++
            else if (st ~ /^ratecap/) cap[key]++
            else if (st != "")        fail[key]++
            seen[key]=1
        }
        END {
            for (p in seen)
                printf "  %-8s ok=%d fail=%d ratecap=%d\n", p, ok[p]+0, fail[p]+0, cap[p]+0
        }
    ' "$WAVE_PLANS_DIR"/*.log | sort
else
    echo "  no exec logs yet"
fi
echo ""
