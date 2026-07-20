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

# Source the resolver/cooldown functions straight out of dispatch.sh.
eval "$(sed -n '/^get_provider() {/,/^}/p;/^get_failover_chain() {/,/^}/p;/^get_cooldown_minutes() {/,/^}/p;/^provider_cooling() {/,/^}/p;/^resolve_provider() {/,/^}/p' "$REPO_DIR/scripts/dispatch.sh")"

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

# notify.sh ratecap path fires without error
if "$REPO_DIR/scripts/notify.sh" web-frontend localhost feat/x ratecap kimi >/dev/null 2>&1; then
    check "notify ratecap path" "ok" "ok"
else
    check "notify ratecap path" "ok" "err"
fi

echo "== row 17: all chain vendors cooling -> primary anyway (never deadlock) =="
date +%s > "$STATE_DIR/claude.cooldown"
p_all=$(resolve_provider web-frontend "")   # kimi+claude both cooling
check "returns primary despite all cooling" "kimi" "$p_all"

# Cleanup
rm -f "$STATE_DIR"/*.cooldown "$STATE_DIR/ratecap.log" 2>/dev/null

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
