#!/bin/bash
# Shared helpers for provider launchers (sourced, not executed).
#
# Launcher contract (providers/<vendor>/launch.sh <role> <task-string>):
#   Env in:  AGENT_MODEL, ROLES_DIR, RATECAP_PATTERNS (all optional)
#   Stdout:  agent output (streamed); stderr: launcher diagnostics
#   Exit:    0 success · 1 task failure · 75 RATE_CAP · 69 UNAVAILABLE
#            78 PROVIDER_LIMIT · 124 HUNG

EXIT_RATECAP=75         # sysexits EX_TEMPFAIL — retry on another provider
EXIT_UNAVAILABLE=69     # sysexits EX_UNAVAILABLE — CLI missing / not logged in
EXIT_PROVIDER_LIMIT=78  # account spend/session limit: hold, probe, no retry burn
EXIT_HUNG=124           # no model event for the quiet period: watchdog stopped it

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

# The quiet watchdog (scripts/seat-watchdog.py) wraps the CLI when the quiet
# period is on (SEAT_QUIET_AFTER_S, default 1800; 0 disables): it passes every
# byte through, tracks the last model event, and stops the seat with
# EXIT_HUNG after a quiet period. Degrades to the bare CLI without python3.
watchdog_runner() { # <cmd...> -> sets the RUNNER array
    RUNNER=("$@")
    local watchdog
    watchdog="$(dirname "${BASH_SOURCE[0]}")/../scripts/seat-watchdog.py"
    if [ "${SEAT_QUIET_AFTER_S:-1800}" != "0" ] \
        && command -v python3 >/dev/null 2>&1 && [ -f "$watchdog" ]; then
        RUNNER=(python3 -u "$watchdog" -- "$@")
    fi
}

# The provider-limit signature (issue #84): a fast exit with no API time and
# an error, the tail naming a spend or session limit (or a 401). A seat that
# ran a while, or one whose result carries real API time, did work first and
# takes the normal failure path instead.
provider_limit_gate_ok() { # <tail_out> <elapsed_s> <cmd_exit>
    local tail_out="$1" elapsed="$2" cmd_exit="$3"
    [ "$elapsed" -lt "${PROVIDER_LIMIT_MAX_SEAT_S:-15}" ] || return 1
    if [ "$cmd_exit" -eq 0 ]; then
        printf '%s\n' "$tail_out" | grep -q '"is_error": *true' || return 1
    fi
    if printf '%s\n' "$tail_out" | grep -qE '"duration_api_ms": *[1-9]'; then
        return 1
    fi
    return 0
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
    local cmd_exit start_ts elapsed
    watchdog_runner "$@"
    start_ts=$(date +%s)
    set +e
    "${RUNNER[@]}" 2>&1 | "${reader[@]}" | tee "$tmp"
    cmd_exit="${PIPESTATUS[0]}"
    set -e
    elapsed=$(( $(date +%s) - start_ts ))

    # A seat the watchdog stopped for going quiet is hung, whatever its last
    # lines say (usually thinking-token ticks, which match nothing below). A
    # stop for a tool call past the tool ceiling names the tool: the
    # watchdog's own stop line is in the log, pass its reason through.
    if [ "$cmd_exit" -eq "$EXIT_HUNG" ]; then
        local hung_note
        hung_note=$(grep '^seat-watchdog: ' "$tmp" 2>/dev/null | tail -1 || true)
        case "$hung_note" in
            *" tool ceiling;"*)
                echo "HUNG seat: ${hung_note#seat-watchdog: }" >&2 ;;
            *)
                echo "HUNG seat: no model event for ${SEAT_QUIET_AFTER_S:-1800}s (exit $EXIT_HUNG)" >&2 ;;
        esac
        rm -f "$tmp"
        return "$EXIT_HUNG"
    fi

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
                elif [ "$class" = "limit" ]; then
                    # Not the signature? Keep scanning: a slow 401 is still
                    # the plain auth failure the table also carries.
                    if provider_limit_gate_ok "$tail_out" "$elapsed" "$cmd_exit"; then
                        echo "PROVIDER_LIMIT detected for $vendor after ${elapsed}s (pattern: $regex), hold, do not retry" >&2
                        return "$EXIT_PROVIDER_LIMIT"
                    fi
                fi
            fi
        done < "$patterns"
    fi

    [ "$cmd_exit" -eq 0 ] && return 0
    return 1
}
