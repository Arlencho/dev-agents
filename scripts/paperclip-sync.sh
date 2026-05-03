#!/bin/bash
set -euo pipefail

# Sync dev-agents/providers/claude/agents/<slug>.md → live Paperclip AGENTS.md for each agent.
#
# Modes:
#   (default / --check)  → report drift only (exit 1 if any drift or no-provider)
#   --apply              → copy provider → live (provider is authoritative)
#   --reverse <slug>     → copy live → provider (for negative-drift captures; then PR the result)
#
# Environment overrides:
#   PAPERCLIP_COMPANY_ID     default: ec35552a-a808-46f3-acbe-4e6dec4969f1
#   PAPERCLIP_INSTANCE_BASE  default: ~/.paperclip/instances/default
#   PAPERCLIP_API            default: http://127.0.0.1:3100/api

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PROVIDERS_DIR="$REPO_DIR/providers/claude/agents"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:-ec35552a-a808-46f3-acbe-4e6dec4969f1}"
INSTANCE_BASE="${PAPERCLIP_INSTANCE_BASE:-$HOME/.paperclip/instances/default}"
LIVE_BASE="$INSTANCE_BASE/companies/$COMPANY_ID/agents"
API_BASE="${PAPERCLIP_API:-http://127.0.0.1:3100/api}"

MODE="check"
REVERSE_SLUG=""

case "${1:-}" in
    --check|"") MODE="check" ;;
    --apply)    MODE="apply" ;;
    --reverse)
        MODE="reverse"
        REVERSE_SLUG="${2:-}"
        if [ -z "$REVERSE_SLUG" ]; then
            echo "Usage: $0 --reverse <slug>"
            echo "  <slug> is the provider filename without .md (e.g., devops, api-designer)"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [--check | --apply | --reverse <slug>]"
        exit 1
        ;;
esac

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Counters
IN_SYNC=0
APPLIED=0
NO_PROVIDER=0
DRIFT=0
SKIPPED=0

# Convert "Agent Name" → "agent-name"
name_to_slug() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

# 3-level lookup: find the provider file that corresponds to a live agent.
#   1. providers/<kebab(name)>.md
#   2. providers/<role>.md
#   3. providers/<frontmatter-name-from-live>.md
find_provider_file() {
    local name="$1"
    local role="$2"
    local agent_id="$3"

    local slug
    slug=$(name_to_slug "$name")
    if [ -f "$PROVIDERS_DIR/$slug.md" ]; then
        echo "$PROVIDERS_DIR/$slug.md"
        return
    fi

    if [ -n "$role" ] && [ "$role" != "null" ] && [ -f "$PROVIDERS_DIR/$role.md" ]; then
        echo "$PROVIDERS_DIR/$role.md"
        return
    fi

    local live_file="$LIVE_BASE/$agent_id/instructions/AGENTS.md"
    if [ -f "$live_file" ]; then
        local fm_name
        fm_name=$(awk 'BEGIN{p=0} /^---/{p++; next} p==1 && /^name:/{print $2; exit}' "$live_file" 2>/dev/null || true)
        if [ -n "$fm_name" ] && [ -f "$PROVIDERS_DIR/$fm_name.md" ]; then
            echo "$PROVIDERS_DIR/$fm_name.md"
            return
        fi
    fi

    echo ""
}

# Fetch agents from API
agents_json=$(curl -s --connect-timeout 3 "$API_BASE/companies/$COMPANY_ID/agents" 2>/dev/null || echo "")

if [ -z "$agents_json" ] || [ "$agents_json" = "[]" ] || [ "$agents_json" = "null" ]; then
    echo "ERROR: Could not reach Paperclip API at $API_BASE"
    echo "Run 'make paperclip-up' to start the local instance."
    exit 1
fi

# Parse agents into TSV (id TAB name TAB role)
agents_tsv=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    agents = data if isinstance(data, list) else data.get('agents', data.get('data', []))
    for a in agents:
        print(a.get('id','') + '\t' + a.get('name','') + '\t' + (a.get('role','') or ''))
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
" <<< "$agents_json")

echo "=== Paperclip → Provider Sync ==="
echo "Mode    : $MODE"
echo "Live    : $LIVE_BASE"
echo "Provider: ${PROVIDERS_DIR#$REPO_DIR/}"
echo ""

# ------------------------------------------------------------------
# --reverse mode: copy live AGENTS.md → provider file
# ------------------------------------------------------------------
if [ "$MODE" = "reverse" ]; then
    echo "Reverse sync: live → providers/$REVERSE_SLUG.md"
    echo ""

    found_id=""
    found_name=""

    while IFS=$'\t' read -r agent_id agent_name agent_role; do
        [ -z "$agent_id" ] && continue
        pf=$(find_provider_file "$agent_name" "$agent_role" "$agent_id" || true)
        if [ -n "$pf" ]; then
            pf_slug=$(basename "$pf" .md)
            if [ "$pf_slug" = "$REVERSE_SLUG" ]; then
                found_id="$agent_id"
                found_name="$agent_name"
                break
            fi
        fi
    done <<< "$agents_tsv"

    if [ -z "$found_id" ]; then
        echo "ERROR: No live agent maps to '$REVERSE_SLUG'"
        echo "Check that '$REVERSE_SLUG.md' exists in providers/ and is reachable via the 3-level lookup."
        exit 1
    fi

    live_file="$LIVE_BASE/$found_id/instructions/AGENTS.md"
    target="$PROVIDERS_DIR/$REVERSE_SLUG.md"

    if [ ! -f "$live_file" ]; then
        echo "ERROR: Live file not found: $live_file"
        exit 1
    fi

    if [ -f "$target" ]; then
        backup="${target}.bak.$(date +%s)"
        cp "$target" "$backup"
        echo -e "${YELLOW}Backed up${NC}: $(basename "$target") → $(basename "$backup")"
    fi

    cp "$live_file" "$target"
    echo -e "${GREEN}Reverse-synced${NC}: $found_name (${found_id:0:8}…) → $REVERSE_SLUG.md"
    echo ""
    echo "Next: review the diff, then open a PR to dev-agents/main."
    exit 0
fi

# ------------------------------------------------------------------
# check / apply mode: iterate all agents
# ------------------------------------------------------------------
while IFS=$'\t' read -r agent_id agent_name agent_role; do
    [ -z "$agent_id" ] && continue

    live_file="$LIVE_BASE/$agent_id/instructions/AGENTS.md"

    if [ ! -f "$live_file" ]; then
        echo -e "  ${YELLOW}? $agent_name${NC} (${agent_id:0:8}…) — no live AGENTS.md (orphan?)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    provider_file=$(find_provider_file "$agent_name" "$agent_role" "$agent_id" || true)

    if [ -z "$provider_file" ]; then
        echo -e "  ${RED}! $agent_name${NC} — NO-PROVIDER"
        echo -e "    Expected: providers/$(name_to_slug "$agent_name").md (or role=$agent_role)"
        NO_PROVIDER=$((NO_PROVIDER + 1))
        continue
    fi

    provider_slug=$(basename "$provider_file")

    if diff -q "$provider_file" "$live_file" >/dev/null 2>&1; then
        echo -e "  ${GREEN}= $agent_name${NC} — $provider_slug (in sync)"
        IN_SYNC=$((IN_SYNC + 1))
    else
        DRIFT=$((DRIFT + 1))

        # Detect direction: live ahead of provider (negative drift)?
        live_lines=$(wc -l < "$live_file")
        prov_lines=$(wc -l < "$provider_file")
        if [ "$live_lines" -gt "$prov_lines" ]; then
            direction="DRIFT-NEGATIVE (live has $((live_lines - prov_lines)) extra lines — consider --reverse)"
        else
            direction="DRIFT (provider → live diff below)"
        fi

        if [ "$MODE" = "check" ]; then
            echo -e "  ${RED}~ $agent_name${NC} — $provider_slug ($direction)"
            diff --unified=3 "$provider_file" "$live_file" | head -25 || true
            echo ""
        else
            # apply: provider is authoritative → overwrite live
            backup="${live_file}.bak.$(date +%s)"
            cp "$live_file" "$backup"
            cp "$provider_file" "$live_file"
            echo -e "  ${GREEN}↓ $agent_name${NC} — $provider_slug (applied; backup: $(basename "$backup"))"
            APPLIED=$((APPLIED + 1))
            DRIFT=$((DRIFT - 1))  # No longer drifted after apply
        fi
    fi

done <<< "$agents_tsv"

echo ""
echo "---"
if [ "$MODE" = "apply" ]; then
    echo "Summary: $IN_SYNC in-sync, $APPLIED applied, $DRIFT remaining-drift, $NO_PROVIDER no-provider, $SKIPPED skipped"
else
    echo "Summary: $IN_SYNC in-sync, $DRIFT drift, $NO_PROVIDER no-provider, $SKIPPED skipped"
fi

if [ "$DRIFT" -gt 0 ] || [ "$NO_PROVIDER" -gt 0 ]; then
    echo ""
    if [ "$MODE" = "check" ]; then
        echo "FAIL: $DRIFT drift + $NO_PROVIDER no-provider."
        echo "  Drift      → run --apply (if provider is authoritative) or --reverse <slug> (if live is ahead)"
        echo "  No-provider→ create providers/claude/agents/<slug>.md then re-run"
        exit 1
    fi
fi
