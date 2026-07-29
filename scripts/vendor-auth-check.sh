#!/usr/bin/env bash
# vendor-auth-check.sh — preflight: validate vendor CLI sessions before dispatch.
#
# Validates (does not re-login). Interactive login is a human step when this fails.
#
# Usage:
#   ./scripts/vendor-auth-check.sh                  # all known vendors on this host
#   ./scripts/vendor-auth-check.sh --vendors claude,kimi
#   ./scripts/vendor-auth-check.sh --plan path.plan  # plan roles → primary+failover
#   ./scripts/vendor-auth-check.sh --json
#   ./scripts/vendor-auth-check.sh --host user@box --vendors claude
#   ./scripts/vendor-auth-check.sh --with-gh         # also check gh auth status
#   ./scripts/vendor-auth-check.sh --deep            # real headless one-shot (required before waves)
#
# Exit: 0 all required vendors OK · 1 one or more failed
#
# Env overrides (tests / unusual installs):
#   KIMI_CODE_HOME   default $HOME/.kimi-code
#   GROK_HOME        default $HOME/.grok
#   VENDOR_AUTH_TIMEOUT_SEC  default 12 shallow / 90 deep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKERS_CONFIG="${WORKERS_CONFIG:-$REPO_DIR/config/workers.yaml}"
ROUTING_CONFIG="${ROUTING_CONFIG:-$REPO_DIR/config/routing.yaml}"

ALL_VENDORS=(claude kimi grok)
VENDORS=()
PLAN_FILE=""
JSON_OUT=false
WITH_GH=false
DEEP=false
REMOTE_HOST=""
TIMEOUT_SEC="${VENDOR_AUTH_TIMEOUT_SEC:-12}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vendors)
            IFS=',' read -ra VENDORS <<< "${2// /}"
            shift 2
            ;;
        --plan)
            PLAN_FILE="${2:?--plan requires a path}"
            shift 2
            ;;
        --json)
            JSON_OUT=true
            shift
            ;;
        --with-gh)
            WITH_GH=true
            shift
            ;;
        --deep)
            DEEP=true
            TIMEOUT_SEC="${VENDOR_AUTH_TIMEOUT_SEC:-90}"
            shift
            ;;
        --host)
            REMOTE_HOST="${2:?--host requires ssh target}"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown flag: $1" >&2
            usage
            ;;
    esac
done

# ── Remote re-entry: run this script on the worker via stdin ──────────
if [ -n "$REMOTE_HOST" ]; then
    args=()
    if [ ${#VENDORS[@]} -gt 0 ]; then
        joined=$(IFS=,; echo "${VENDORS[*]}")
        args+=(--vendors "$joined")
    fi
    [ "$JSON_OUT" = true ] && args+=(--json)
    [ "$WITH_GH" = true ] && args+=(--with-gh)
    [ "$DEEP" = true ] && args+=(--deep)
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
        "bash -s -- ${args[*]+"${args[*]}"}" < "$0"
    exit $?
fi

# ── Resolve vendors from plan (role → primary + failover) ─────────────
get_primary_provider() {
    local agent="$1"
    local in_prefs=false default_provider="claude"
    [ -f "$WORKERS_CONFIG" ] || { echo "claude"; return; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*provider_preferences: ]]; then
            in_prefs=true
            continue
        fi
        if [ "$in_prefs" = true ]; then
            if [[ "$line" =~ ^[a-zA-Z] ]]; then
                in_prefs=false
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*${agent}:[[:space:]]*(.*) ]]; then
                echo "${BASH_REMATCH[1]}" | awk '{print $1}'
                return
            fi
            if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*(.*) ]]; then
                default_provider=$(echo "${BASH_REMATCH[1]}" | awk '{print $1}')
            fi
        fi
    done < "$WORKERS_CONFIG"
    echo "$default_provider"
}

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
                echo "${BASH_REMATCH[1]}" | tr ',' ' '
                return
            fi
            if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*\[(.*)\] ]]; then
                default_chain=$(echo "${BASH_REMATCH[1]}" | tr ',' ' ')
            fi
        fi
    done < "$ROUTING_CONFIG"
    echo "$default_chain"
}

resolve_plan_vendors() {
    local plan="$1"
    local -a agents=() ordered=()
    local line wave agent fields n first
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [ -z "${line// /}" ] && continue
        IFS='|' read -ra fields <<< "$line"
        n=${#fields[@]}
        [ "$n" -lt 2 ] && continue
        first=$(echo "${fields[0]}" | xargs)
        if [[ "$first" =~ ^[0-9]+$ ]]; then
            agent=$(echo "${fields[1]}" | xargs)
        else
            agent="$first"
        fi
        [ -n "$agent" ] || continue
        case " ${agents[*]-} " in *" $agent "*) ;; *) agents+=("$agent") ;; esac
    done < "$plan"

    local a p c v
    for a in "${agents[@]+"${agents[@]}"}"; do
        p=$(get_primary_provider "$a")
        c=$(get_failover_chain "$a")
        for v in $p $c; do
            v=$(echo "$v" | xargs)
            [ -z "$v" ] && continue
            case " ${ordered[*]-} " in *" $v "*) ;; *) ordered+=("$v") ;; esac
        done
    done
    printf '%s\n' "${ordered[@]+"${ordered[@]}"}"
}

if [ -n "$PLAN_FILE" ]; then
    if [ ! -f "$PLAN_FILE" ]; then
        echo "ERROR: plan not found: $PLAN_FILE" >&2
        exit 1
    fi
    while IFS= read -r v; do
        [ -n "$v" ] && VENDORS+=("$v")
    done < <(resolve_plan_vendors "$PLAN_FILE")
fi

if [ ${#VENDORS[@]} -eq 0 ]; then
    VENDORS=("${ALL_VENDORS[@]}")
fi

# ── Probes ────────────────────────────────────────────────────────────

run_with_timeout() {
    # Usage: run_with_timeout <sec> <cmd...>
    # Prefer perl alarm (portable on macOS without GNU timeout).
    local sec="$1"; shift
    perl -e 'alarm shift; exec @ARGV' "$sec" "$@" 2>&1
}

# status|detail  via globals last set by check_* 
PROBE_STATUS=""
PROBE_DETAIL=""
PROBE_FIX=""

check_claude() {
    PROBE_FIX="claude login"
    if ! command -v claude >/dev/null 2>&1; then
        PROBE_STATUS="missing"
        PROBE_DETAIL="claude CLI not on PATH"
        return 1
    fi
    local out
    set +e
    out=$(run_with_timeout "$TIMEOUT_SEC" claude auth status 2>&1)
    local ec=$?
    set -e
    if [ $ec -ne 0 ]; then
        PROBE_STATUS="fail"
        PROBE_DETAIL="claude auth status exit $ec: $(echo "$out" | head -3 | tr '\n' ' ')"
        return 1
    fi
    if echo "$out" | grep -qiE 'oauth session expired|not logged in|please run /login|failed to authenticate'; then
        PROBE_STATUS="expired"
        PROBE_DETAIL=$(echo "$out" | head -2 | tr '\n' ' ')
        return 1
    fi
    if ! echo "$out" | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
        if echo "$out" | grep -qE '"loggedIn"[[:space:]]*:[[:space:]]*false'; then
            PROBE_STATUS="expired"
            PROBE_DETAIL="loggedIn=false"
            return 1
        fi
        PROBE_STATUS="unknown"
        PROBE_DETAIL="unexpected auth status output"
        return 1
    fi
    local email
    email=$(echo "$out" | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    # Deep: headless one-shot (status alone can lie while -p OAuth fails)
    if [ "$DEEP" = true ]; then
        local hout
        set +e
        hout=$(run_with_timeout "$TIMEOUT_SEC" claude -p --dangerously-skip-permissions "Reply with exactly: AUTH_OK" 2>&1)
        local hec=$?
        set -e
        if [ $hec -ne 0 ] || ! echo "$hout" | grep -q 'AUTH_OK'; then
            PROBE_STATUS="expired"
            PROBE_DETAIL="status loggedIn but headless failed: $(echo "$hout" | tr '\n' ' ' | head -c 200)"
            return 1
        fi
        PROBE_STATUS="ok"
        PROBE_DETAIL="${email:-loggedIn=true} + headless AUTH_OK"
        return 0
    fi
    PROBE_STATUS="ok"
    PROBE_DETAIL="${email:-loggedIn=true}"
    return 0
}

check_kimi() {
    PROBE_FIX="kimi login"
    if ! command -v kimi >/dev/null 2>&1; then
        PROBE_STATUS="missing"
        PROBE_DETAIL="kimi CLI not on PATH"
        return 1
    fi
    local home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
    local cred="$home/credentials"
    local oauth="$home/oauth"
    if [ ! -d "$cred" ] && [ ! -d "$oauth" ]; then
        PROBE_STATUS="expired"
        PROBE_DETAIL="no credentials under $home (run kimi login)"
        return 1
    fi
    local has=0
    if [ -d "$cred" ] && find "$cred" -type f ! -size 0 2>/dev/null | grep -q .; then
        has=1
    fi
    if [ -d "$oauth" ] && find "$oauth" -type f ! -size 0 2>/dev/null | grep -q .; then
        has=1
    fi
    if [ "$has" -eq 0 ]; then
        PROBE_STATUS="expired"
        PROBE_DETAIL="credentials/oauth empty under $home"
        return 1
    fi
    set +e
    local dout
    dout=$(run_with_timeout "$TIMEOUT_SEC" kimi doctor 2>&1)
    local dec=$?
    set -e
    if [ $dec -ne 0 ]; then
        PROBE_STATUS="fail"
        PROBE_DETAIL="kimi doctor failed: $(echo "$dout" | head -2 | tr '\n' ' ')"
        return 1
    fi
    if [ "$DEEP" = true ]; then
        # Match launcher: -p + --output-format text (NOT --auto with -p)
        local hout
        set +e
        hout=$(run_with_timeout "$TIMEOUT_SEC" kimi -p "Reply with exactly: AUTH_OK" --output-format text 2>&1)
        local hec=$?
        set -e
        if [ $hec -ne 0 ] || ! echo "$hout" | grep -q 'AUTH_OK'; then
            PROBE_STATUS="expired"
            PROBE_DETAIL="creds present but headless failed: $(echo "$hout" | tr '\n' ' ' | head -c 200)"
            return 1
        fi
        PROBE_STATUS="ok"
        PROBE_DETAIL="credentials + doctor + headless AUTH_OK"
        return 0
    fi
    PROBE_STATUS="ok"
    PROBE_DETAIL="credentials present + doctor ok"
    return 0
}

check_grok() {
    PROBE_FIX="grok login"
    if ! command -v grok >/dev/null 2>&1; then
        PROBE_STATUS="missing"
        PROBE_DETAIL="grok CLI not on PATH"
        return 1
    fi
    local home="${GROK_HOME:-$HOME/.grok}"
    local auth="$home/auth.json"
    if [ ! -f "$auth" ]; then
        PROBE_STATUS="expired"
        PROBE_DETAIL="missing $auth (run grok login)"
        return 1
    fi
    if [ ! -s "$auth" ]; then
        PROBE_STATUS="expired"
        PROBE_DETAIL="empty auth.json"
        return 1
    fi
    if ! python3 - "$auth" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
if not isinstance(d, dict) or len(d) < 1:
    sys.exit(1)
sys.exit(0)
PY
    then
        PROBE_STATUS="fail"
        PROBE_DETAIL="auth.json not a non-empty JSON object"
        return 1
    fi
    if [ "$DEEP" = true ]; then
        local hout
        set +e
        hout=$(run_with_timeout "$TIMEOUT_SEC" grok -p "Reply with exactly: AUTH_OK" 2>&1)
        local hec=$?
        set -e
        if [ $hec -ne 0 ] || ! echo "$hout" | grep -q 'AUTH_OK'; then
            PROBE_STATUS="expired"
            PROBE_DETAIL="auth.json present but headless failed: $(echo "$hout" | tr '\n' ' ' | head -c 200)"
            return 1
        fi
        PROBE_STATUS="ok"
        PROBE_DETAIL="auth.json + headless AUTH_OK"
        return 0
    fi
    PROBE_STATUS="ok"
    PROBE_DETAIL="auth.json present"
    return 0
}

check_gh() {
    PROBE_FIX="gh auth login"
    if ! command -v gh >/dev/null 2>&1; then
        PROBE_STATUS="missing"
        PROBE_DETAIL="gh not on PATH"
        return 1
    fi
    set +e
    local out
    out=$(run_with_timeout "$TIMEOUT_SEC" gh auth status 2>&1)
    local ec=$?
    set -e
    if [ $ec -ne 0 ]; then
        PROBE_STATUS="expired"
        PROBE_DETAIL="$(echo "$out" | head -2 | tr '\n' ' ')"
        return 1
    fi
    PROBE_STATUS="ok"
    PROBE_DETAIL="gh auth status ok"
    return 0
}

run_check() {
    local vendor="$1"
    case "$vendor" in
        claude) check_claude ;;
        kimi)   check_kimi ;;
        grok)   check_grok ;;
        gh)     check_gh ;;
        *)
            PROBE_STATUS="unknown"
            PROBE_DETAIL="unsupported vendor"
            PROBE_FIX=""
            return 1
            ;;
    esac
}

# ── Execute ───────────────────────────────────────────────────────────

declare -a RESULT_LINES=()
FAIL=0
JSON_PARTS=()

if [ "$JSON_OUT" = false ]; then
    echo -e "${BOLD}Vendor auth preflight${NC} (host: $(hostname -s 2>/dev/null || hostname))"
fi

for vendor in "${VENDORS[@]}"; do
    vendor=$(echo "$vendor" | xargs | tr '[:upper:]' '[:lower:]')
    [ -z "$vendor" ] && continue
    if run_check "$vendor"; then
        if [ "$JSON_OUT" = true ]; then
            JSON_PARTS+=("{\"vendor\":\"$vendor\",\"status\":\"ok\",\"detail\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_DETAIL")}")
        else
            echo -e "  ${GREEN}ok${NC}   ${BOLD}$vendor${NC}  — $PROBE_DETAIL"
        fi
    else
        FAIL=1
        if [ "$JSON_OUT" = true ]; then
            JSON_PARTS+=("{\"vendor\":\"$vendor\",\"status\":\"$PROBE_STATUS\",\"detail\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_DETAIL"),\"fix\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_FIX")}")
        else
            echo -e "  ${RED}FAIL${NC} $vendor  [$PROBE_STATUS] — $PROBE_DETAIL"
            [ -n "$PROBE_FIX" ] && echo -e "        fix: ${YELLOW}$PROBE_FIX${NC}"
        fi
    fi
done

if [ "$WITH_GH" = true ]; then
    if run_check gh; then
        if [ "$JSON_OUT" = true ]; then
            JSON_PARTS+=("{\"vendor\":\"gh\",\"status\":\"ok\",\"detail\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_DETAIL")}")
        else
            echo -e "  ${GREEN}ok${NC}   ${BOLD}gh${NC}  — $PROBE_DETAIL"
        fi
    else
        FAIL=1
        if [ "$JSON_OUT" = true ]; then
            JSON_PARTS+=("{\"vendor\":\"gh\",\"status\":\"$PROBE_STATUS\",\"detail\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_DETAIL"),\"fix\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROBE_FIX")}")
        else
            echo -e "  ${RED}FAIL${NC} gh  [$PROBE_STATUS] — $PROBE_DETAIL"
            echo -e "        fix: ${YELLOW}$PROBE_FIX${NC}"
        fi
    fi
fi

if [ "$JSON_OUT" = true ]; then
    overall="ok"
    [ "$FAIL" -ne 0 ] && overall="fail"
    echo "{\"overall\":\"$overall\",\"results\":[$(IFS=,; echo "${JSON_PARTS[*]}")]}"
else
    if [ "$FAIL" -ne 0 ]; then
        echo ""
        echo -e "${RED}${BOLD}Preflight failed.${NC} Re-login on this machine, then re-run."
        echo "  make vendor-auth   # or: ./scripts/vendor-auth-check.sh"
        exit 1
    fi
    echo -e "${GREEN}All required vendor sessions OK.${NC}"
fi

exit "$FAIL"
