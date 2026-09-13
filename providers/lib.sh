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
# Usage: AGENT_PROMPT_TEXT=<prompt> run_and_classify <vendor> <cmd...>
# Only the LAST 25 lines of output are matched — cap/auth messages appear at
# the end of a run; agents may legitimately discuss rate limits mid-transcript.
# Lines that appear verbatim in AGENT_PROMPT_TEXT are never matched.
run_and_classify() {
    local vendor="$1"; shift
    local patterns="${RATECAP_PATTERNS:-$(dirname "${BASH_SOURCE[0]}")/../config/ratecap-patterns.conf}"
    local tmp
    tmp=$(mktemp)

    # Optional live-stream reader: a pass-through filter between the CLI and
    # the log. It folds progress facts out of a streaming run for the Ops Floor
    # and writes every byte back, so the log keeps exactly what the CLI printed.
    # PIPESTATUS[0] still belongs to the vendor CLI, so the exit code and the
    # rate-cap classification below are unchanged. No reader, no python3, or an
    # unreadable path all degrade to `cat`.
    local reader=(cat)
    if [ -n "${AGENT_STREAM_READER:-}" ] && [ -f "${AGENT_STREAM_READER}" ] \
        && command -v python3 >/dev/null 2>&1; then
        reader=(python3 -u "$AGENT_STREAM_READER")
    fi

    # Launchers run under set -e; a failing vendor CLI must not abort the
    # launcher before classification. Toggle errexit around the pipeline only.
    local cmd_exit
    set +e
    "$@" 2>&1 | "${reader[@]}" | tee "$tmp"
    cmd_exit="${PIPESTATUS[0]}"
    set -e

    local tail_out
    tail_out=$(tail -25 "$tmp")
    rm -f "$tmp"

    # Classify the CLI's own output only. The prompt carries injected text
    # (charter, preamble, learnings, task) that may quote a cap or auth phrase,
    # and a CLI that echoes its prompt would feed it straight back here. Every
    # output line that appears verbatim in the prompt is dropped before the
    # pattern table sees it. Launchers set AGENT_PROMPT_TEXT to the full
    # prompt they hand the CLI.
    if [ -n "${AGENT_PROMPT_TEXT:-}" ]; then
        local prompt_lines
        prompt_lines=$(mktemp)
        printf '%s\n' "$AGENT_PROMPT_TEXT" | sed '/^[[:space:]]*$/d' > "$prompt_lines"
        tail_out=$(printf '%s\n' "$tail_out" | grep -vxF -f "$prompt_lines" || true)
        rm -f "$prompt_lines"
    fi

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
