#!/usr/bin/env bash
#
# paperclip-agent.sh — selective per-agent heartbeat control.
#
# After paperclip-up.sh applies safe defaults (heartbeat=OFF for all 14),
# use this to temporarily wake a specific agent for active work, then turn
# it back off when done.
#
# Usage:
#   ./scripts/paperclip-agent.sh on  "Frontend Engineer"
#   ./scripts/paperclip-agent.sh off "Frontend Engineer"
#   ./scripts/paperclip-agent.sh status
#   ./scripts/paperclip-agent.sh status --recent          # also show last heartbeat
#
# Reference: dev-agents/PAPERCLIP.md § 6.1 Budget guidance

set -euo pipefail

log() { printf '[paperclip-agent] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

OLYMPUS_COMPANY_ID="ec35552a-a808-46f3-acbe-4e6dec4969f1"
COMPANY_ID="${COMPANY_ID:-$OLYMPUS_COMPANY_ID}"
API="http://127.0.0.1:3100/api"

if ! curl -sf "$API/health" >/dev/null 2>&1; then
  die "Paperclip server not running at 127.0.0.1:3100 — run 'make paperclip-up' first"
fi

CMD="${1:-status}"
TARGET_NAME="${2:-}"

case "$CMD" in
  on|off)
    [[ -z "$TARGET_NAME" ]] && die "usage: $0 $CMD <agent-name>"
    ENABLED=$([[ "$CMD" == "on" ]] && echo true || echo false)

    AGENTS_JSON="$(curl -sf "$API/companies/$COMPANY_ID/agents")" \
      || die "failed to list agents for $COMPANY_ID"

    AGENTS_JSON="$AGENTS_JSON" TARGET="$TARGET_NAME" ENABLED="$ENABLED" \
      python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

API = "http://127.0.0.1:3100/api"
agents = json.loads(os.environ['AGENTS_JSON'])
target = os.environ['TARGET']
enabled = os.environ['ENABLED'] == "true"

match = next((a for a in agents if a['name'].lower() == target.lower()), None)
if not match:
    available = ", ".join(sorted(a['name'] for a in agents))
    sys.stderr.write(f"no agent named {target!r}\n")
    sys.stderr.write(f"available: {available}\n")
    sys.exit(2)

body = {"runtimeConfig": {"heartbeat": {
    "enabled": enabled,
    "cooldownSec": 10,
    "intervalSec": 1800,
    "wakeOnDemand": True,
    "maxConcurrentRuns": 2,
}}}
req = urllib.request.Request(
    f"{API}/agents/{match['id']}",
    data=json.dumps(body).encode(),
    method="PATCH",
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=5) as r:
    if r.status != 200:
        sys.exit(f"PATCH failed: HTTP {r.status}")

state = "ON " if enabled else "OFF"
print(f"  {state}  {match['name']}  (id={match['id']})")
if enabled:
    print()
    print("  REMINDER: turn it back OFF when done:")
    print(f"    ./scripts/paperclip-agent.sh off {match['name']!r}")
PYEOF
    ;;

  status)
    AGENTS_JSON="$(curl -sf "$API/companies/$COMPANY_ID/agents")" \
      || die "failed to list agents for $COMPANY_ID"
    SHOW_RECENT=$([[ "${2:-}" == "--recent" ]] && echo 1 || echo 0)
    AGENTS_JSON="$AGENTS_JSON" SHOW_RECENT="$SHOW_RECENT" \
      python3 - <<'PYEOF'
import json, os
from datetime import datetime, timezone

agents = json.loads(os.environ['AGENTS_JSON'])
show_recent = os.environ.get('SHOW_RECENT') == '1'
now = datetime.now(timezone.utc)

def fmt_age(iso):
    if not iso: return "-"
    try:
        d = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        secs = (now - d).total_seconds()
        if secs < 60:   return f"{int(secs)}s ago"
        if secs < 3600: return f"{int(secs/60)}m ago"
        if secs < 86400: return f"{int(secs/3600)}h ago"
        return f"{int(secs/86400)}d ago"
    except Exception:
        return iso[:10]

header = f"{'STATE':<6} {'AGENT':<22} {'MODEL':<8} {'BUDGET':<10}"
if show_recent: header += f" {'LAST_HEARTBEAT'}"
print(header)
print("-" * (len(header) + 4))

on_count = 0
for a in sorted(agents, key=lambda x: x['name']):
    hb = a.get('runtimeConfig', {}).get('heartbeat', {})
    enabled = hb.get('enabled', False)
    if enabled: on_count += 1
    state = "ON " if enabled else "off"
    model = a.get('adapterConfig', {}).get('model', '-')
    cap = a.get('budgetMonthlyCents', 0)
    line = f"{state:<6} {a['name']:<22} {model:<8} €{cap/100:<8.2f}"
    if show_recent:
        line += f" {fmt_age(a.get('lastHeartbeatAt'))}"
    print(line)

print()
print(f"  {on_count} of {len(agents)} agents have heartbeat=ON")
PYEOF
    ;;

  *)
    die "unknown command: $CMD (use: on, off, status)"
    ;;
esac
