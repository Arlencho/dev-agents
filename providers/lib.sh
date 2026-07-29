#!/bin/bash
# Shared helpers for provider launchers (sourced, not executed).
#
# Launcher contract (providers/<vendor>/launch.sh <role> <task-string>):
#   Env in:  AGENT_MODEL, ROLES_DIR, RATECAP_PATTERNS (all optional)
#   Stdout:  agent output (streamed); stderr: launcher diagnostics
#   Exit:    0 success · 1 task failure · 75 RATE_CAP · 69 UNAVAILABLE

EXIT_RATECAP=75      # sysexits EX_TEMPFAIL — retry on another provider
EXIT_UNAVAILABLE=69  # sysexits EX_UNAVAILABLE — CLI missing / not logged in

# Print a charter body without its YAML frontmatter block
strip_frontmatter() {
    awk 'BEGIN{fm=0} /^---$/{fm++; next} fm!=1' "$1"
}

# Resolve what model the launcher will actually use (Ground Truth provenance).
# Usage: effective_model <vendor> <requested>
# - Claude: requested tier/id is passed through; empty → "default"
# - Kimi/Grok: Claude tier aliases (opus|sonnet|haiku) are ignored → vendor-default
#   (Kimi CLI default = K3; Grok CLI default = current Build model)
# - Non-empty non-alias requested → passed through as vendor-native id
effective_model() {
    local vendor="${1:-}"
    local requested="${2:-}"
    case "$vendor" in
        kimi|grok)
            case "$requested" in
                ""|opus|sonnet|haiku|claude-fable-5|claude-*|fable-*)
                    if [ "$vendor" = "kimi" ]; then
                        echo "vendor-default-k3"
                    else
                        echo "vendor-default"
                    fi
                    ;;
                *)
                    echo "$requested"
                    ;;
            esac
            ;;
        claude|*)
            if [ -n "$requested" ]; then
                echo "$requested"
            else
                echo "default"
            fi
            ;;
    esac
}

# Run a vendor CLI, classify the outcome against the rate-cap pattern table.
# Usage: run_and_classify <vendor> <cmd...>
# Only the LAST 25 lines of output are matched — cap/auth messages appear at
# the end of a run; agents may legitimately discuss rate limits mid-transcript.
run_and_classify() {
    local vendor="$1"; shift
    local patterns="${RATECAP_PATTERNS:-$(dirname "${BASH_SOURCE[0]}")/../config/ratecap-patterns.conf}"
    local tmp
    tmp=$(mktemp)

    # Launchers run under set -e; a failing vendor CLI must not abort the
    # launcher before classification. Toggle errexit around the pipeline only.
    local cmd_exit
    set +e
    "$@" 2>&1 | tee "$tmp"
    cmd_exit="${PIPESTATUS[0]}"
    set -e

    local tail_out
    tail_out=$(tail -25 "$tmp")
    rm -f "$tmp"

    if [ -f "$patterns" ]; then
        local class regex
        while IFS='|' read -r pvendor class regex; do
            [[ "$pvendor" =~ ^[[:space:]]*# ]] && continue
            [ -z "$regex" ] && continue
            [ "$pvendor" = "$vendor" ] || continue
            if echo "$tail_out" | grep -qiE "$regex"; then
                if [ "$class" = "ratecap" ]; then
                    echo "RATE_CAP detected for $vendor (pattern: $regex)" >&2
                    return "$EXIT_RATECAP"
                elif [ "$class" = "auth" ]; then
                    echo "AUTH failure for $vendor (pattern: $regex) — run '$vendor login' on this machine" >&2
                    return "$EXIT_UNAVAILABLE"
                fi
            fi
        done < "$patterns"
    fi

    [ "$cmd_exit" -eq 0 ] && return 0
    return 1
}
