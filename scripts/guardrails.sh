#!/usr/bin/env bash
set -euo pipefail

# Safety guardrails for unattended agent execution
# Checks commands against blocked/warned patterns from config/guardrails.yaml
#
# Subcommands:
#   check <command>  -- returns 0 (safe), exits 77 (blocked), returns 2 (warned)
#   install <dir>    -- installs git hooks (pre-push blocks force to main/master)
#   list             -- show all blocked + warned patterns

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/../config/guardrails.yaml"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# --------------------------------------------------
# Parse guardrails.yaml into blocked/warned arrays
# --------------------------------------------------
parse_config() {
    local section=""
    BLOCKED_PATTERNS=()
    WARNED_PATTERNS=()

    if [ ! -f "$CONFIG" ]; then
        echo -e "${RED}ERROR: Guardrails config not found at $CONFIG${NC}" >&2
        exit 1
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Detect section headers
        if [[ "$line" =~ ^blocked: ]]; then
            section="blocked"
            continue
        elif [[ "$line" =~ ^warned: ]]; then
            section="warned"
            continue
        elif [[ "$line" =~ ^[a-zA-Z] ]]; then
            section=""
            continue
        fi

        # Parse list items
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"(.*)\" ]]; then
            pattern="${BASH_REMATCH[1]}"
            if [ "$section" = "blocked" ]; then
                BLOCKED_PATTERNS+=("$pattern")
            elif [ "$section" = "warned" ]; then
                WARNED_PATTERNS+=("$pattern")
            fi
        fi
    done < "$CONFIG"
}

# --------------------------------------------------
# check <command>
# Returns: 0 = safe, 77 = blocked, 2 = warned
# --------------------------------------------------
cmd_check() {
    local cmd="$1"
    parse_config

    # Check blocked patterns first
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
        if echo "$cmd" | grep -qi "$pattern" 2>/dev/null; then
            echo -e "${RED}BLOCKED${NC}: Command matches blocked pattern: ${BOLD}$pattern${NC}" >&2
            echo -e "${RED}Command${NC}: $cmd" >&2
            exit 77
        fi
    done

    # Check warned patterns
    for pattern in "${WARNED_PATTERNS[@]}"; do
        if echo "$cmd" | grep -qi "$pattern" 2>/dev/null; then
            echo -e "${YELLOW}WARNING${NC}: Command matches warned pattern: ${BOLD}$pattern${NC}" >&2
            echo -e "${YELLOW}Command${NC}: $cmd" >&2
            return 2
        fi
    done

    echo -e "${GREEN}SAFE${NC}: $cmd" >&2
    return 0
}

# --------------------------------------------------
# install <dir>
# Installs a git pre-push hook that blocks force-push to main/master
# --------------------------------------------------
cmd_install() {
    local repo_dir="$1"

    if [ ! -d "$repo_dir/.git" ]; then
        echo -e "${RED}ERROR: Not a git repository: $repo_dir${NC}" >&2
        exit 1
    fi

    local hooks_dir="$repo_dir/.git/hooks"
    mkdir -p "$hooks_dir"

    local hook_file="$hooks_dir/pre-push"

    # If hook exists and already has our guardrail marker, skip
    if [ -f "$hook_file" ] && grep -q "# guardrails:agent-safety" "$hook_file" 2>/dev/null; then
        echo -e "${GREEN}Guardrail pre-push hook already installed in $repo_dir${NC}"
        return 0
    fi

    cat > "$hook_file" <<'HOOK'
#!/usr/bin/env bash
# guardrails:agent-safety — blocks force-push to main/master
# Installed by dev-agents/scripts/guardrails.sh

remote="$1"

while read -r local_ref local_sha remote_ref remote_sha; do
    # Detect protected branches
    if [[ "$remote_ref" =~ refs/heads/(main|master)$ ]]; then
        branch="${BASH_REMATCH[1]}"
        # Check if this is a force push (remote sha is not ancestor of local sha)
        if [ "$remote_sha" != "0000000000000000000000000000000000000000" ]; then
            if ! git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
                echo "BLOCKED by guardrails: force-push to $branch is not allowed"
                exit 1
            fi
        fi
    fi
done

exit 0
HOOK

    chmod +x "$hook_file"
    echo -e "${GREEN}Installed guardrail pre-push hook in $repo_dir${NC}"
}

# --------------------------------------------------
# list
# Pretty-print all blocked and warned patterns
# --------------------------------------------------
cmd_list() {
    parse_config

    echo -e "${BOLD}Safety Guardrails${NC}"
    echo ""

    echo -e "${RED}${BOLD}BLOCKED${NC} ${RED}(exit 77 — agent stops immediately):${NC}"
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
        echo -e "  ${RED}✗${NC} $pattern"
    done

    echo ""
    echo -e "${YELLOW}${BOLD}WARNED${NC} ${YELLOW}(logged but allowed):${NC}"
    for pattern in "${WARNED_PATTERNS[@]}"; do
        echo -e "  ${YELLOW}!${NC} $pattern"
    done
}

# --------------------------------------------------
# Main
# --------------------------------------------------
usage() {
    echo "Usage: guardrails.sh <subcommand> [args]"
    echo ""
    echo "Subcommands:"
    echo "  check <command>   Check a command against guardrails (exit 0=safe, 77=blocked, 2=warned)"
    echo "  install <dir>     Install git pre-push hook in a repository"
    echo "  list              Show all blocked and warned patterns"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

SUBCMD="$1"
shift

case "$SUBCMD" in
    check)
        [ $# -lt 1 ] && { echo "Usage: guardrails.sh check <command>" >&2; exit 1; }
        cmd_check "$*"
        ;;
    install)
        [ $# -lt 1 ] && { echo "Usage: guardrails.sh install <dir>" >&2; exit 1; }
        cmd_install "$1"
        ;;
    list)
        cmd_list
        ;;
    *)
        echo -e "${RED}Unknown subcommand: $SUBCMD${NC}" >&2
        usage
        ;;
esac
