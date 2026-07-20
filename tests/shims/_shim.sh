#!/bin/bash
# Shared fake-CLI behavior for launcher tests. Symlinked as claude/kimi/grok.
# Driven by SHIM_MODE: success | fail | ratecap | noauth
# Records the received argv to $SHIM_ARGV_LOG (if set) so tests can assert
# charter injection.
VENDOR="$(basename "$0")"
MODE="${SHIM_MODE:-success}"

[ -n "${SHIM_ARGV_LOG:-}" ] && printf '%s\0' "$@" > "$SHIM_ARGV_LOG"

# Emit a realistic prompt echo so charter-injection assertions have something
# to grep. The prompt is the argument after -p / --prompt / --agent, but the
# simplest robust thing is to echo every arg.
echo "[$VENDOR shim] args: $*"

case "$MODE" in
    success)
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
        esac
        exit 1 ;;
    noauth)
        case "$VENDOR" in
            claude) echo "Not logged in. Please run /login" ;;
            kimi)   echo "HTTP 401 unauthorized — please run 'kimi login'" ;;
            grok)   echo "Not authenticated. Run 'grok login' first." ;;
        esac
        exit 1 ;;
    *)
        echo "unknown SHIM_MODE=$MODE" >&2
        exit 2 ;;
esac
