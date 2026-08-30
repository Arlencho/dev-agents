#!/bin/bash
# Failover decision tests (rows 16-17) — exercises dispatch.sh's provider
# resolution + cooldown logic without the ssh transport (Remote Login off here;
# the transport itself is unchanged plumbing already covered by the retry loop).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_DIR/config/workers.yaml"
ROUTING_CONFIG="$REPO_DIR/config/routing.yaml"
STATE_DIR="$REPO_DIR/logs/provider-state"

# get_provider / get_failover_chain are shared with flow.sh and sync-providers.sh.
# CONFIG and ROUTING_CONFIG are set above, so the library uses this repo's config.
# shellcheck source=../scripts/config-lib.sh
source "$REPO_DIR/scripts/config-lib.sh"

# The cooldown + resolution logic is still dispatch-specific; pull those three
# straight out of dispatch.sh.
eval "$(sed -n '/^get_cooldown_minutes() {/,/^}/p;/^provider_cooling() {/,/^}/p;/^resolve_provider() {/,/^}/p' "$REPO_DIR/scripts/dispatch.sh")"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %-48s (%s)\n' "$1" "$3"; pass=$((pass+1)); else printf '  FAIL %-48s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# Clean slate
rm -f "$STATE_DIR"/*.cooldown 2>/dev/null

echo "== row 16: kimi capped -> task fails over to claude =="
# Emulate dispatch_task's per-task provider progression across a rate-cap retry.
tried=""
p1=$(resolve_provider web-frontend "$tried")
check "first dispatch picks primary" "kimi" "$p1"

# run-remote records a cap on exit 75: cooldown file + ratecap.log (mirror it here)
mkdir -p "$STATE_DIR"
date +%s > "$STATE_DIR/${p1}.cooldown"
echo "$(date -u +%FT%TZ)|$p1|web-frontend|localhost|ratecap" >> "$STATE_DIR/ratecap.log"
tried="$tried $p1"   # dispatch appends the capped vendor to the task's tried-set

p2=$(resolve_provider web-frontend "$tried")
check "retry fails over to next provider" "claude" "$p2"
check "cooldown file was written" "yes" "$([ -f "$STATE_DIR/kimi.cooldown" ] && echo yes || echo no)"
check "kimi now reads as cooling" "yes" "$(provider_cooling kimi && echo yes || echo no)"

# notify.sh ratecap path fires without error and stays stdout-only under the
# silent switch — `make test` must never pop "Provider Rate-Capped" toasts.
export FLEET_NOTIFY_SILENT=1
notify_out=$("$REPO_DIR/scripts/notify.sh" web-frontend localhost feat/x ratecap kimi 2>/dev/null) \
    && notify_rc=ok || notify_rc=err
check "notify ratecap path" "ok" "$notify_rc"
case "$notify_out" in
    *"[notify] Provider Rate-Capped:"*) check "notify ratecap stdout fallback" "ok" "ok" ;;
    *) check "notify ratecap stdout fallback" "ok" "missing" ;;
esac

# The silent switch must gate osascript itself: shim it on PATH and prove it is
# NOT invoked while silenced and IS invoked on macOS when not silenced.
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/osascript" <<'EOF'
#!/bin/sh
echo called >> "$OSASCRIPT_CALLS"
EOF
chmod +x "$SHIM_DIR/osascript"
export OSASCRIPT_CALLS="$SHIM_DIR/calls"
: > "$OSASCRIPT_CALLS"
PATH="$SHIM_DIR:$PATH" "$REPO_DIR/scripts/notify.sh" web-frontend localhost feat/x ratecap kimi >/dev/null 2>&1
check "silent: osascript not invoked" "0" "$(wc -l < "$OSASCRIPT_CALLS" | tr -d ' ')"
if [ "$(uname)" = "Darwin" ]; then
    PATH="$SHIM_DIR:$PATH" env -u FLEET_NOTIFY_SILENT "$REPO_DIR/scripts/notify.sh" web-frontend localhost feat/x ratecap kimi >/dev/null 2>&1
    check "unsilenced on macOS: osascript invoked" "1" "$(wc -l < "$OSASCRIPT_CALLS" | tr -d ' ')"
fi
rm -rf "$SHIM_DIR"

echo "== row 17: all chain vendors cooling -> primary anyway (never deadlock) =="
date +%s > "$STATE_DIR/claude.cooldown"
p_all=$(resolve_provider web-frontend "")   # kimi+claude both cooling
check "returns primary despite all cooling" "kimi" "$p_all"

# Cleanup
rm -f "$STATE_DIR"/*.cooldown "$STATE_DIR/ratecap.log" 2>/dev/null

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
