#!/bin/bash
# Shared fake-CLI behavior for launcher tests. Symlinked as claude/kimi/grok/codex.
# Driven by SHIM_MODE (or the contents of SHIM_MODE_FILE when set):
# success | fail | ratecap | noauth | work | quiet | heartbeat | chatty |
# limit | slow-limit | quiet-once | tool-open | tool-hung | tool-hung-once
#   work: behaves like a seat that did something. Writes one file in the
#   current directory (a seat worktree under run-remote), commits it, records
#   its real cwd to $SHIM_CWD_LOG, prints two stream-json tool_use lines (an
#   edit of that file by absolute path, and an edit of $SHIM_OUTSIDE_PATH when
#   set) so the live-progress reader has something to fold, then sleeps
#   $SHIM_WORK_SLEEP seconds (default 3) so a test can observe two seats alive
#   at once. Exit 0.
#   quiet: one assistant stream-json line, then silence (sleeps
#   SHIM_QUIET_SLEEP, default 120). The seat watchdog should stop it.
#   heartbeat: thinking-token ticks from the real 2026-09-14 hung-seat log,
#   forever, never a model event. Quiet by definition.
#   chatty: a stream of assistant lines, then exit 0. A working seat the
#   watchdog must never stop.
#   limit: the real 2026-09-13 spend-limit stream (issue #84), fast, exit 1.
#   slow-limit: the same stream after a sleep, past the limit gate window.
#   quiet-once: quiet on the first invocation (marker in SHIM_STATE_DIR),
#   then re-execs in work mode, so a retried seat succeeds.
#   tool-open: a tool_use stream-json line, silence past the quiet period
#   (SHIM_TOOL_SLEEP, default 6), then the matching tool_result and exit 0.
#   A working seat with a tool in flight: the watchdog must not stop it.
#   tool-hung: a tool_use line, then silence (SHIM_QUIET_SLEEP, default 120)
#   with no tool_result ever. The tool ceiling, not the quiet period, stops
#   the seat and the stop line names the tool.
#   tool-hung-once: tool-hung on the first invocation (marker in
#   SHIM_STATE_DIR), then re-execs in work mode, so a retried seat succeeds.
# Records the received argv to $SHIM_ARGV_LOG (if set) so tests can assert
# charter injection.
VENDOR="$(basename "$0")"
MODE="${SHIM_MODE:-success}"
if [ -n "${SHIM_MODE_FILE:-}" ] && [ -f "$SHIM_MODE_FILE" ]; then
    MODE="$(head -1 "$SHIM_MODE_FILE" | tr -d '[:space:]')"
fi
SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "${SHIM_ARGV_LOG:-}" ] && printf '%s\0' "$@" > "$SHIM_ARGV_LOG"

# ── Auth preflight probes (vendor-auth-check.sh) ──────────────────────
# claude auth status → JSON loggedIn
if [ "$VENDOR" = "claude" ] && [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
    case "$MODE" in
        success)
            echo '{"loggedIn":true,"authMethod":"claude.ai","email":"shim@example.com"}'
            exit 0
            ;;
        noauth)
            echo '{"loggedIn":false}'
            exit 0
            ;;
        fail)
            echo "Failed to authenticate: OAuth session expired and could not be refreshed"
            exit 1
            ;;
        ratecap)
            echo "You've reached your usage limit. Limit resets at 5pm."
            exit 1
            ;;
    esac
fi

# kimi doctor → config ok (credentials checked via filesystem separately)
if [ "$VENDOR" = "kimi" ] && [ "${1:-}" = "doctor" ]; then
    case "$MODE" in
        success|noauth)
            # noauth still returns doctor ok — credential files decide fail
            echo "Kimi doctor"
            echo "All checked config files are valid."
            exit 0
            ;;
        fail)
            echo "Kimi doctor"
            echo "ERROR: invalid config"
            exit 1
            ;;
        ratecap)
            echo "HTTP 429: rate limit exceeded"
            exit 1
            ;;
    esac
fi

# codex login status → "Logged in using ChatGPT" (exit 0) or "Not logged in" (exit 1)
if [ "$VENDOR" = "codex" ] && [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
    case "$MODE" in
        success|ratecap)
            echo "Logged in using ChatGPT"
            exit 0
            ;;
        noauth|fail)
            echo "Not logged in"
            exit 1
            ;;
    esac
fi

# Emit a realistic prompt echo so charter-injection assertions have something
# to grep. The prompt is the argument after -p / --prompt / --agent, but the
# simplest robust thing is to echo every arg.
echo "[$VENDOR shim] args: $*"

case "$MODE" in
    success)
        echo "work complete."
        exit 0 ;;
    work)
        [ -n "${SHIM_CWD_LOG:-}" ] && pwd -P >> "$SHIM_CWD_LOG"
        stamp="seat-${SHIM_WORK_TAG:-$$}.txt"
        date -u +%FT%TZ > "$stamp"
        git add "$stamp" && git commit -q -m "chore: seat work ${SHIM_WORK_TAG:-$$}"
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s/%s"}}]}}\n' "$(pwd -P)" "$stamp"
        [ -n "${SHIM_OUTSIDE_PATH:-}" ] && printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$SHIM_OUTSIDE_PATH"
        sleep "${SHIM_WORK_SLEEP:-3}"
        echo "work complete."
        exit 0 ;;
    fail)
        echo "error: something broke in the task"
        exit 1 ;;
    ratecap)
        case "$VENDOR" in
            claude) echo "You've reached your usage limit. Limit resets at 5pm." ;;
            kimi)   echo "HTTP 429: rate limit exceeded, please retry later" ;;
            grok)   echo "Error: HTTP 429 Too Many Requests — quota exceeded" ;;
            codex)  echo "ERROR: You've hit your usage limit. Upgrade to Pro or try again at 3:00 PM." ;;
        esac
        exit 1 ;;
    noauth)
        case "$VENDOR" in
            claude) echo "Not logged in. Please run /login" ;;
            kimi)   echo "HTTP 401 unauthorized — please run 'kimi login'" ;;
            grok)   echo "Not authenticated. Run 'grok login' first." ;;
            codex)  echo "Not logged in. Run 'codex login' to authenticate." ;;
        esac
        exit 1 ;;
    quiet)
        # One real model event, then silence: the watchdog must stop this seat.
        printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"starting the work now"}]}}\n'
        sleep "${SHIM_QUIET_SLEEP:-120}"
        exit 0 ;;
    heartbeat)
        # Thinking-token ticks copied from the real hung-seat log of
        # 2026-09-14, forever: alive, but never a model event.
        while :; do
            cat "$SHIM_DIR/../fixtures/claude-thinking-heartbeats-20260914.jsonl"
            sleep "${SHIM_HEARTBEAT_SLEEP:-0.3}"
        done ;;
    chatty)
        # Model events keep coming: the watchdog must never stop this seat.
        i=0
        while [ "$i" -lt "${SHIM_CHATTY_LINES:-12}" ]; do
            printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working step %s"}]}}\n' "$i"
            sleep "${SHIM_CHATTY_SLEEP:-0.5}"
            i=$(( i + 1 ))
        done
        exit 0 ;;
    limit)
        # The real spend-limit stream of 2026-09-13 (issue #84), fast, exit 1.
        cat "$SHIM_DIR/../fixtures/claude-spend-limit-20260913.jsonl"
        exit 1 ;;
    slow-limit)
        # The same limit text after real time passed: not the fast signature.
        sleep "${SHIM_SLOW_LIMIT_SLEEP:-20}"
        cat "$SHIM_DIR/../fixtures/claude-spend-limit-20260913.jsonl"
        exit 1 ;;
    quiet-once)
        # First seat hangs and is stopped; the retried seat does the work.
        marker="${SHIM_STATE_DIR:?quiet-once needs SHIM_STATE_DIR}/quiet-once-fired"
        if [ ! -f "$marker" ]; then
            : > "$marker"
            printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"starting the work now"}]}}\n'
            sleep "${SHIM_QUIET_SLEEP:-120}"
            exit 0
        fi
        SHIM_MODE=work SHIM_MODE_FILE= exec bash "$0" "$@" ;;
    tool-open)
        # A tool call opens, stays silent past the quiet period, then its
        # result lands: a working seat the watchdog must never stop.
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"make test"}}]}}\n'
        sleep "${SHIM_TOOL_SLEEP:-6}"
        printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"tests passed"}]}}\n'
        exit 0 ;;
    tool-hung)
        # A tool call opens and its result never comes: the tool ceiling,
        # not the quiet period, is what stops the seat, naming the tool.
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"make test"}}]}}\n'
        sleep "${SHIM_QUIET_SLEEP:-120}"
        exit 0 ;;
    tool-hung-once)
        # First seat hangs on an open tool and is stopped on the ceiling;
        # the retried seat does the work.
        marker="${SHIM_STATE_DIR:?tool-hung-once needs SHIM_STATE_DIR}/tool-hung-once-fired"
        if [ ! -f "$marker" ]; then
            : > "$marker"
            printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"make test"}}]}}\n'
            sleep "${SHIM_QUIET_SLEEP:-120}"
            exit 0
        fi
        SHIM_MODE=work SHIM_MODE_FILE= exec bash "$0" "$@" ;;
    *)
        echo "unknown SHIM_MODE=$MODE" >&2
        exit 2 ;;
esac
