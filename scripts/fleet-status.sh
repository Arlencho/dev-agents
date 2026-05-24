#!/usr/bin/env bash
#
# fleet-status.sh — Unified visibility for the Olympus AI agent fleet.
#
# Shows at a glance:
#   - Paperclip server health
#   - Which agents have heartbeat ON vs OFF (the expensive ones)
#   - Local Ollama / olympus-coder status
#   - Sentinel activity (Paperclip + local if present)
#   - Recommended autonomy posture
#
# Usage:
#   ./scripts/fleet-status.sh
#   ./scripts/fleet-status.sh --watch          # refresh every 10s
#   make fleet-status
#
# This is the single command you run to answer "what is actually running right now?"
#
set -euo pipefail

API="http://127.0.0.1:3100/api"
COMPANY_ID="${COMPANY_ID:-ec35552a-a808-46f3-acbe-4e6dec4969f1}"
OLLAMA_URL="http://localhost:11434"
WATCH=${1:-}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }

refresh() {
if [[ "$WATCH" == "--watch" ]]; then
    clear
fi
echo -e "${BLUE}Olympus Fleet Status — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo "Repo: dev-agents | Company: Olympus | Goal: Quality-first autonomous fleet"
echo

# 1. Paperclip server
header "Paperclip Control Plane"
if curl -sf "$API/health" >/dev/null 2>&1; then
    HEALTH=$(curl -sf "$API/health")
    VERSION=$(echo "$HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo "?")
    echo -e "  ${GREEN}RUNNING${NC}   v$VERSION   $API"
else
    echo -e "  ${RED}NOT RUNNING${NC}   (run 'make paperclip-up' to start governance layer)"
fi

# 2. Agent heartbeat state (the expensive frontier agents)
header "Frontier Agents (Grok / Claude) — Heartbeat State"
if curl -sf "$API/companies/$COMPANY_ID/agents" >/dev/null 2>&1; then
    AGENTS=$(curl -sf "$API/companies/$COMPANY_ID/agents")
    echo "$AGENTS" | python3 -c '
import json, sys
from datetime import datetime, timezone
agents = json.loads(sys.stdin.read())
now = datetime.now(timezone.utc)

def age(iso):
    if not iso: return "-"
    try:
        d = datetime.fromisoformat(iso.replace("Z","+00:00"))
        s = (now - d).total_seconds()
        if s < 60: return f"{int(s)}s"
        if s < 3600: return f"{int(s/60)}m"
        if s < 86400: return f"{int(s/3600)}h"
        return f"{int(s/86400)}d"
    except: return "?"

GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
NC = "\033[0m"

print(f"  {\"STATE\":<6} {\"AGENT\":<24} {\"MODEL\":<10} {\"BUDGET €\":<10} {\"LAST HB\":<8}")
print("  " + "-"*68)
on = 0
for a in sorted(agents, key=lambda x: x.get("name","")):
    hb = a.get("runtimeConfig",{}).get("heartbeat",{})
    enabled = hb.get("enabled", False)
    if enabled: on += 1
    state = f"{GREEN}ON {NC}" if enabled else f"{YELLOW}off{NC}"
    model = a.get("adapterConfig",{}).get("model", "-")[:9]
    cap = a.get("budgetMonthlyCents", 0) / 100
    last = age(a.get("lastHeartbeatAt"))
    print(f"  {state:<6} {a[\"name\"]:<24} {model:<10} €{cap:<8.2f} {last:<8}")
print(f"\n  {on} of {len(agents)} frontier agents have heartbeat=ON (these cost real tokens when active)")
' 2>/dev/null || echo "  (could not render agent table — Paperclip may be down or agents not loaded)"
else
    echo "  (Paperclip not reachable — cannot show agent heartbeats)"
fi

# 3. Local Ollama / project-specific model
header "Local Specialist (Ollama — zero token cost)"
if curl -sf "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    MODELS=$(curl -sf "$OLLAMA_URL/api/tags" | python3 -c '
import sys, json
data = json.load(sys.stdin)
names = [m["name"] for m in data.get("models",[])]
print("  " + ", ".join(names) if names else "  (no models)")
' 2>/dev/null || echo "  (Ollama responding but parse failed)")
    echo -e "  ${GREEN}RUNNING${NC}   $OLLAMA_URL"
    echo "  Models: $MODELS"
    # Quick probe of olympus-coder
    if curl -sf -X POST "$OLLAMA_URL/api/show" -d '{"name":"olympus-coder:latest"}' >/dev/null 2>&1; then
        echo -e "  ${GREEN}olympus-coder:latest${NC} is available and project-tuned"
    fi
else
    echo -e "  ${YELLOW}NOT RUNNING${NC}   (Ollama not reachable — local cheap agents unavailable)"
fi

# 4. Sentinel status (the main pulse / discovery layer)
header "PR Sentinel (Discovery & Routing)"

# Local Sentinel status (preferred cheap path)
if [[ -f "logs/local-sentinel-status.json" ]]; then
    python3 -c '
import json, sys
from datetime import datetime, timezone
s = json.load(open("logs/local-sentinel-status.json"))
last = s.get("last_run", "")
try:
    d = datetime.fromisoformat(last.replace("Z","+00:00"))
    age = (datetime.now(timezone.utc) - d).total_seconds()
    if age < 3600: age_str = f"{int(age/60)}m ago"
    else: age_str = f"{int(age/3600)}h ago"
except:
    age_str = last[:16]
print(f"  Local Sentinel: last run {age_str} | PRs: {s.get(\"prs_scanned\",0)} | Tasks filed: {s.get(\"tasks_filed\",0)} | Model: {s.get(\"model\",\"?\")}")
' 2>/dev/null
else
    echo "  Local Sentinel: never run (run 'make local-sentinel-dry' first)"
fi

# Background Service (launchd) status
LAUNCHD_LABEL="com.arlen.local-pr-sentinel"
if launchctl list "$LAUNCHD_LABEL" >/dev/null 2>&1; then
    PID=$(launchctl list "$LAUNCHD_LABEL" 2>/dev/null | awk 'NR==2 {print $1}' || echo "?")
    if [[ "$PID" != "-" && "$PID" != "" ]]; then
        echo -e "  Background Service: ${GREEN}RUNNING${NC} (launchd, PID $PID)"
    else
        echo -e "  Background Service: ${YELLOW}LOADED${NC} (launchd, not currently running)"
    fi
else
    echo -e "  Background Service: ${YELLOW}NOT LOADED${NC} (run 'make local-sentinel-install' to enable automatic runs)"
fi

# Paperclip Sentinel (if any)
if curl -sf "$API/companies/$COMPANY_ID/agents" >/dev/null 2>&1; then
    SENTINEL=$(curl -sf "$API/companies/$COMPANY_ID/agents" | python3 -c '
import sys, json
agents = json.loads(sys.stdin.read())
s = next((a for a in agents if "sentinel" in a.get("name","").lower()), None)
if s:
    hb = s.get("runtimeConfig",{}).get("heartbeat",{})
    state = "ON" if hb.get("enabled") else "OFF"
    print(f"  Paperclip Sentinel: {state} (heartbeat)")
else:
    print("  Paperclip Sentinel: not hired or heartbeat off")
' 2>/dev/null || echo "  Paperclip Sentinel: (query failed)")
    echo "$SENTINEL"
fi

# Show recent errors from Local Sentinel (if any)
if [[ -f "logs/local-sentinel-status.json" ]]; then
    python3 -c '
import json, sys
try:
    s = json.load(open("logs/local-sentinel-status.json"))
    errs = s.get("errors", [])
    if errs:
        print("  Recent errors:")
        for e in errs[-3:]:
            if isinstance(e, dict):
                cat = e.get("category", "general")
                msg = e.get("message", str(e))
                print(f"    - [{cat}] {msg}")
            else:
                print(f"    - {e}")
except:
    pass
' 2>/dev/null
fi

# One-line Local Sentinel Health summary (new in Tier 3 polish)
if [[ -f "logs/local-sentinel-status.json" ]]; then
    python3 -c '
import json, sys
from datetime import datetime, timezone
try:
    s = json.load(open("logs/local-sentinel-status.json"))
    last = s.get("last_run", "")
    errs = s.get("errors", [])
    has_errors = len(errs) > 0

    # Compute age
    try:
        d = datetime.fromisoformat(last.replace("Z","+00:00"))
        age = (datetime.now(timezone.utc) - d).total_seconds()
        if age < 3600:
            age_str = f"{int(age/60)}m ago"
        else:
            age_str = f"{int(age/3600)}h ago"
    except:
        age_str = "?"

    # Color and status
    if has_errors:
        color = "\033[1;33m"  # yellow
        status = "DEGRADED"
        detail = f"{len(errs)} recent error(s)"
    else:
        color = "\033[0;32m"  # green
        status = "OK"
        detail = "no recent errors"

    print(f"  Local Sentinel Health: {color}{status}\033[0m  (last run {age_str}, {detail})")
except:
    print("  Local Sentinel Health: ? (could not read status)")
' 2>/dev/null
else
    echo "  Local Sentinel Health: UNKNOWN (never run)"
fi

# Digest
DIGEST=$(curl -sf "$API/companies/$COMPANY_ID/issues?status=in_progress&limit=20" 2>/dev/null | python3 -c '
import sys, json
try:
    issues = json.load(sys.stdin)
    d = next((i for i in issues if "merge queue digest" in i.get("title","").lower()), None)
    if d:
        print(f"  Merge Queue Digest: {d.get(\"title\")} (updated {d.get(\"updatedAt\",\"\")[:16]})")
    else:
        print("  Merge Queue Digest: none active")
except:
    print("  Merge Queue Digest: (Paperclip not reachable)")
' 2>/dev/null || echo "  Merge Queue Digest: (unavailable)")
echo "$DIGEST"

echo
echo -e "${YELLOW}Current posture:${NC} Safe-by-default (most frontier heartbeats OFF)."
echo "  Expensive agents wake only when you (or a Grok-orchestrated wave) explicitly need them."
echo "  Recommendation: Run local PR Sentinel via cron for background discovery (zero marginal cost)."
echo
echo "Quick commands:"
echo "  make paperclip-agent-status --recent     # detailed agent view"
echo "  make paperclip-agent-on AGENT=\"PR Sentinel\"   # temporary wake (remember to turn off)"
echo "  ollama run olympus-coder:latest          # talk to local specialist directly"
echo
}

if [[ "$WATCH" == "--watch" ]]; then
    while true; do
        refresh
        sleep 10
    done
else
    refresh
fi
