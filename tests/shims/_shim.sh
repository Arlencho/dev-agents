#!/bin/bash
# Shared fake-CLI behavior for launcher tests. Symlinked as claude/kimi/grok.
# Driven by SHIM_MODE: success | fail | ratecap | noauth
# Records the received argv to $SHIM_ARGV_LOG (if set) so tests can assert
# charter injection.
VENDOR="$(basename "$0")"
MODE="${SHIM_MODE:-success}"

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
