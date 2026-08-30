#!/bin/bash
# Shared config-parsing helpers for config/workers.yaml + config/routing.yaml.
#
# Extracted verbatim from dispatch.sh so that flow.sh, sync-providers.sh and the
# routing tests resolve seats through ONE implementation. Before this file there
# were three copies (dispatch.sh inline, tests/run-routing-tests.sh "mirror
# dispatch get_model", and any new caller), which is the same duplicated
# source-of-truth failure that let roles/ and providers/ drift apart.
#
# Grep-friendly YAML parsing on purpose: no python/yq dependency, and it must
# keep working on the bash that ships on a worker over ssh.
#
# Usage:
#   source "$REPO_DIR/scripts/config-lib.sh"
#   get_provider devops-critic          # -> grok
#   get_model    go-backend             # -> sonnet
#   get_failover_chain devops-critic    # -> "grok kimi"
#   role_providers devops-critic        # -> "grok kimi"  (primary + failover)
#
# CONFIG / ROUTING_CONFIG may be pre-set by the caller (dispatch.sh does);
# otherwise they default to this repo's config/.

_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_LIB_REPO="$(dirname "$_CONFIG_LIB_DIR")"
CONFIG="${CONFIG:-$_CONFIG_LIB_REPO/config/workers.yaml}"
ROUTING_CONFIG="${ROUTING_CONFIG:-$_CONFIG_LIB_REPO/config/routing.yaml}"

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

# --------------------------------------------------
# Get the Claude model tier for an agent from routing.yaml model_routing:.
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
# Every vendor that may ever run <role>: primary + failover chain, deduplicated,
# primary first. This is the ownership rule sync-providers.sh uses to decide
# whether a role needs a copy in providers/<vendor>/agents/.
#
# Only Claude needs such a copy (its `--agent <name>` registry resolves through
# ~/.claude/agents symlinks). The kimi and grok launchers read roles/<role>.md
# directly and strip_frontmatter() it. A grok-only seat must therefore NOT be
# synced into providers/claude/agents/: doing so registers a Claude agent pinned
# to a model Claude cannot resolve.
# --------------------------------------------------
role_providers() {
    local role="$1" candidate ordered=""
    for candidate in $(get_provider "$role") $(get_failover_chain "$role"); do
        case " $ordered " in *" $candidate "*) ;; *) ordered="$ordered $candidate" ;; esac
    done
    echo "${ordered# }"
}
