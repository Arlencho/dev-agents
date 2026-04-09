#!/bin/bash
set -euo pipefail

# Sync role definitions from roles/ to all provider directories.
# The roles/ directory is the single source of truth. Provider directories
# (e.g., providers/claude/agents/) should always mirror it.
#
# Usage:
#   ./scripts/sync-providers.sh            # Sync (copy) roles/ to providers/
#   ./scripts/sync-providers.sh --check    # Report drift only (exit 1 if any)
#   ./scripts/sync-providers.sh --force    # Overwrite without warning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ROLES_DIR="$REPO_DIR/roles"

MODE="sync"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
elif [ "${1:-}" = "--force" ]; then
    MODE="force"
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No color

# Counters
ADDED=0
UPDATED=0
UNCHANGED=0
DRIFT=0

# --------------------------------------------------
# Find provider directories that have an agents/ folder
# --------------------------------------------------
PROVIDER_DIRS=()
for provider_dir in "$REPO_DIR/providers"/*/; do
    agents_dir="${provider_dir}agents"
    if [ -d "$agents_dir" ]; then
        PROVIDER_DIRS+=("$agents_dir")
    fi
done

if [ ${#PROVIDER_DIRS[@]} -eq 0 ]; then
    echo "No provider directories with agents/ found."
    exit 0
fi

echo "=== Sync Roles to Providers ==="
echo "Mode: $MODE"
echo "Source: roles/"
echo ""

for agents_dir in "${PROVIDER_DIRS[@]}"; do
    provider=$(basename "$(dirname "$agents_dir")")
    echo "Provider: $provider"
    echo "  Target: ${agents_dir#$REPO_DIR/}"
    echo ""

    for role_file in "$ROLES_DIR"/*.md; do
        name=$(basename "$role_file")
        target="$agents_dir/$name"

        if [ ! -f "$target" ]; then
            # New file — needs to be added
            ADDED=$((ADDED + 1))
            if [ "$MODE" = "check" ]; then
                DRIFT=$((DRIFT + 1))
                echo -e "  ${RED}+ $name${NC} (missing from provider)"
            else
                echo -e "  ${GREEN}+ $name${NC} (added)"
                cp "$role_file" "$target"
            fi
        elif diff -q "$role_file" "$target" >/dev/null 2>&1; then
            # Identical
            UNCHANGED=$((UNCHANGED + 1))
            echo -e "  ${GREEN}= $name${NC}"
        else
            # Files differ — check direction of drift
            if [ "$MODE" = "force" ]; then
                UPDATED=$((UPDATED + 1))
                echo -e "  ${YELLOW}~ $name${NC} (overwritten)"
                cp "$role_file" "$target"
            elif [ "$MODE" = "check" ]; then
                DRIFT=$((DRIFT + 1))
                echo -e "  ${RED}! $name${NC} (drift detected)"
                diff --unified=3 "$role_file" "$target" | head -20 || true
                echo ""
            else
                # Default sync — warn about local changes
                DRIFT=$((DRIFT + 1))
                echo -e "  ${RED}! $name${NC} (provider has local changes)"
                echo "    Use --force to overwrite, or update roles/ first"
                diff --unified=3 "$role_file" "$target" | head -20 || true
                echo ""
            fi
        fi
    done

    # Check for files in provider that don't exist in roles/
    for provider_file in "$agents_dir"/*.md; do
        [ -f "$provider_file" ] || continue
        name=$(basename "$provider_file")
        if [ ! -f "$ROLES_DIR/$name" ]; then
            DRIFT=$((DRIFT + 1))
            echo -e "  ${RED}? $name${NC} (exists in provider but not in roles/)"
        fi
    done

    echo ""
done

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo "---"
echo "Summary: $ADDED added, $UPDATED updated, $UNCHANGED unchanged, $DRIFT drift"

if [ "$DRIFT" -gt 0 ]; then
    if [ "$MODE" = "check" ]; then
        echo ""
        echo "FAIL: $DRIFT file(s) out of sync. Run ./scripts/sync-providers.sh to fix."
        exit 1
    elif [ "$MODE" = "sync" ]; then
        echo ""
        echo "WARNING: $DRIFT file(s) have drift. Use --force to overwrite."
        exit 1
    fi
fi
