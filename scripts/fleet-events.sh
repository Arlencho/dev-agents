#!/usr/bin/env bash
# Fleet Desk v2 — Phase B event emitter (schema: fleet-events/1)
#
# Append-only JSONL stream of dispatch facts for the Ops Floor.
#   logs/fleet-events/<dispatch_id>.jsonl   one JSON object per line
#   logs/fleet-events/latest                pointer file (basename of the newest run)
#
# Law: docs/proposals/fleet-desk-v2-SYNTHESIS.md §3 Phase B
# Schema doc: docs/experience-data.md § Live event stream
#
# REDACTION LAW (do not weaken):
#   - never emit an agent transcript, prompt, task description, or handoff body
#   - logs travel as BASENAMES only, never as absolute paths
#   - values are control-char stripped and truncated to 200 chars
# Emitting is best-effort: every function returns 0 so a dispatch never dies
# because a log line could not be written.
#
# Usage (library):
#   . "$SCRIPT_DIR/fleet-events.sh"
#   fleet_events_init "dev-agents" "wave" "plan.txt"
#   fleet_event seat_dispatch task_id=0 agent=devops branch=feat/x provider=claude
#
# Usage (CLI, mostly for tests):
#   scripts/fleet-events.sh init <repo> [mode] [plan]
#   scripts/fleet-events.sh emit <event> [key=value ...]     (needs FLEET_EVENTS_FILE)
#
# Opt-out: FLEET_EVENTS=0 disables every write (init becomes a no-op).
# Override target dir: FLEET_EVENTS_DIR=/path (default <repo>/logs/fleet-events).

FLEET_EVENTS_SCHEMA="fleet-events/1"

# Keys emitted as JSON numbers when the value is an integer. Everything else is
# a quoted string — a branch literally named "42" must not become a number.
_FE_NUMERIC_KEYS=" seq exit wave waves seats attempt duration_s elapsed_s succeeded failed total blocked cooldown_minutes next_wave "

_fe_enabled() {
    [ "${FLEET_EVENTS:-1}" = "0" ] && return 1
    return 0
}

# JSON-escape one value: backslash, quote, control chars, length cap.
_fe_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037' 2>/dev/null || printf '%s' "$s")"
    printf '%s' "${s:0:200}"
}

# fleet_events_init <repo_slug> [mode] [plan_label] [dispatch_id]
# Sets FLEET_DISPATCH_ID / FLEET_EVENTS_FILE and writes the latest pointer.
# On any failure (unwritable dir, opt-out) it clears FLEET_EVENTS_FILE, which
# makes every later fleet_event call a silent no-op.
fleet_events_init() {
    FLEET_EVENTS_FILE=""
    FLEET_EVENT_SEQ=0
    if ! _fe_enabled; then
        return 0
    fi

    local repo_slug="${1:-fleet}" mode="${2:-wave}" plan="${3:-}" forced_id="${4:-}"
    local base_dir="${FLEET_EVENTS_DIR:-}"
    if [ -z "$base_dir" ]; then
        local here
        here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
        base_dir="$(dirname "$here")/logs/fleet-events"
    fi

    if ! mkdir -p "$base_dir" 2>/dev/null; then
        echo "fleet-events: cannot create $base_dir — event stream disabled" >&2
        return 0
    fi

    local slug
    slug="$(printf '%s' "$repo_slug" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
    FLEET_DISPATCH_ID="${forced_id:-$(date -u +%Y%m%d-%H%M%S)-${slug:-fleet}}"
    FLEET_EVENTS_DIR="$base_dir"
    FLEET_EVENTS_FILE="$base_dir/${FLEET_DISPATCH_ID}.jsonl"

    if ! : >> "$FLEET_EVENTS_FILE" 2>/dev/null; then
        echo "fleet-events: cannot write $FLEET_EVENTS_FILE — event stream disabled" >&2
        FLEET_EVENTS_FILE=""
        return 0
    fi

    # Pointer file: one line, the basename of the current stream. A plain file
    # (not a symlink) so it survives copy, rsync, and non-POSIX filesystems.
    printf '%s\n' "${FLEET_DISPATCH_ID}.jsonl" > "$base_dir/latest" 2>/dev/null || true

    fleet_event dispatch_start mode="$mode" repo="$repo_slug" plan="$(basename "${plan:-}" 2>/dev/null || printf '%s' "$plan")"
    return 0
}

# fleet_event <event> [key=value ...]
fleet_event() {
    if ! _fe_enabled; then return 0; fi
    if [ -z "${FLEET_EVENTS_FILE:-}" ]; then return 0; fi
    if [ $# -lt 1 ]; then return 0; fi

    local event="$1"; shift
    FLEET_EVENT_SEQ=$(( ${FLEET_EVENT_SEQ:-0} + 1 ))

    local ts line kv key val
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="{\"schema\":\"$FLEET_EVENTS_SCHEMA\""
    line="$line,\"seq\":$FLEET_EVENT_SEQ"
    line="$line,\"ts\":\"$ts\""
    line="$line,\"dispatch_id\":\"$(_fe_escape "${FLEET_DISPATCH_ID:-unknown}")\""
    line="$line,\"event\":\"$(_fe_escape "$event")\""

    for kv in "$@"; do
        case "$kv" in
            *=*) ;;
            *) continue ;;
        esac
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            ''|*[!a-z0-9_]*) continue ;;   # only lower_snake keys reach the stream
        esac
        [ -z "$val" ] && continue          # omit unknowns instead of emitting ""
        case "$_FE_NUMERIC_KEYS" in
            *" $key "*)
                if [[ "$val" =~ ^-?[0-9]+$ ]]; then
                    line="$line,\"$key\":$val"
                    continue
                fi
                ;;
        esac
        line="$line,\"$key\":\"$(_fe_escape "$val")\""
    done
    line="$line}"

    printf '%s\n' "$line" >> "$FLEET_EVENTS_FILE" 2>/dev/null || true
    return 0
}

# CLI mode — only when executed directly, never when sourced.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    set -euo pipefail
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        init)
            fleet_events_init "${1:-fleet}" "${2:-wave}" "${3:-}" "${4:-}"
            printf '%s\n' "${FLEET_EVENTS_FILE:-}"
            ;;
        emit)
            [ -n "${FLEET_EVENTS_FILE:-}" ] || { echo "fleet-events: FLEET_EVENTS_FILE not set" >&2; exit 1; }
            # Each CLI call is a fresh process — continue the sequence from the
            # lines already on disk instead of restarting at 1.
            FLEET_EVENT_SEQ="$(wc -l < "$FLEET_EVENTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
            fleet_event "$@"
            ;;
        *)
            echo "Usage: fleet-events.sh init <repo> [mode] [plan] [dispatch_id]" >&2
            echo "       FLEET_EVENTS_FILE=... fleet-events.sh emit <event> [key=value ...]" >&2
            exit 1
            ;;
    esac
fi
