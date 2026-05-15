#!/usr/bin/env bash
#
# paperclip-apply-safe-defaults.sh — apply cost-safe per-agent config to a
# Paperclip company. Idempotent. Called automatically by paperclip-up.sh
# after the server boots.
#
# Why: on 2026-05-13 → 2026-05-15 the Olympus 14-agent fleet ran with
# heartbeat=true 24/7 and budgetMonthlyCents=0 (unlimited). Result: a
# whole month of Anthropic spend in ~3 days. This script enforces:
#
#   • heartbeat.enabled        = false   (wake only on explicit assignment)
#   • heartbeat.intervalSec    = 1800    (30 min — not 5 min — when enabled)
#   • heartbeat.maxConcurrentRuns = 2    (was 5)
#   • budgetMonthlyCents       = per-agent cap based on role + model
#
# Total ceiling across the Olympus fleet: €200/mo (≈ what a solo dev should
# spend on background agent work).
#
# Usage:
#   ./scripts/paperclip-apply-safe-defaults.sh                     # Olympus company
#   ./scripts/paperclip-apply-safe-defaults.sh <company-id>        # other company
#
# Reference: dev-agents/PAPERCLIP.md § 6.1 Budget guidance

set -euo pipefail

log() { printf '[safe-defaults] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

OLYMPUS_COMPANY_ID="ec35552a-a808-46f3-acbe-4e6dec4969f1"
COMPANY_ID="${1:-$OLYMPUS_COMPANY_ID}"
API="http://127.0.0.1:3100/api"

# Pre-flight.
if ! curl -sf "$API/health" >/dev/null 2>&1; then
  die "Paperclip server not running at 127.0.0.1:3100 — run 'make paperclip-up' first"
fi

# Per-agent budget cap in cents (EUR). Conservative defaults; raise via
# explicit PATCH after this script runs if a specific agent legitimately
# needs more headroom.
#
# Total: 21,500 cents = €215/month if every agent hits cap simultaneously.
# Realistic monthly spend at these caps: €30–€80/mo across the fleet.
declare -A BUDGET=(
  ["Orchestrator"]=0           # no LLM — coordinator only
  ["CTO"]=3000                 # Opus, gates everything → €30/mo
  ["Backend Engineer"]=1500    # Sonnet → €15
  ["Frontend Engineer"]=1500   # Sonnet → €15
  ["DevOps Engineer"]=1000     # Sonnet → €10
  ["Database Engineer"]=1000   # Sonnet → €10
  ["API Designer"]=1000        # Sonnet → €10
  ["Backend Critic"]=2000      # Opus → €20
  ["Frontend Critic"]=2000     # Opus → €20
  ["Database Critic"]=1500     # Opus → €15
  ["API Critic"]=1500          # Opus → €15
  ["QA Engineer"]=2000         # Opus → €20
  ["Security Engineer"]=2000   # Opus → €20
  ["PR Sentinel"]=500          # Sonnet, sweeps frequently → €5
)

# Get the live agent list.
AGENTS_JSON="$(curl -sf "$API/companies/$COMPANY_ID/agents")" \
  || die "failed to list agents for company $COMPANY_ID"

# Iterate via python3 (avoids requiring jq).
python3 - <<PYEOF >/tmp/paperclip-safe-defaults.plan
import json, os, sys, urllib.request

agents = json.loads(os.environ.get('AGENTS_JSON', '[]'))
budget = {
    "Orchestrator": 0, "CTO": 3000,
    "Backend Engineer": 1500, "Frontend Engineer": 1500,
    "DevOps Engineer": 1000, "Database Engineer": 1000, "API Designer": 1000,
    "Backend Critic": 2000, "Frontend Critic": 2000,
    "Database Critic": 1500, "API Critic": 1500,
    "QA Engineer": 2000, "Security Engineer": 2000,
    "PR Sentinel": 500,
}
plan = []
for a in agents:
    name = a.get("name", "?")
    aid = a["id"]
    cap = budget.get(name, 1000)  # default €10 for unknown agent
    plan.append({"id": aid, "name": name, "cap_cents": cap})
print(json.dumps(plan))
PYEOF

AGENTS_JSON="$AGENTS_JSON" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error

API = "http://127.0.0.1:3100/api"
agents = json.loads(os.environ['AGENTS_JSON'])
budget = {
    "Orchestrator": 0, "CTO": 3000,
    "Backend Engineer": 1500, "Frontend Engineer": 1500,
    "DevOps Engineer": 1000, "Database Engineer": 1000, "API Designer": 1000,
    "Backend Critic": 2000, "Frontend Critic": 2000,
    "Database Critic": 1500, "API Critic": 1500,
    "QA Engineer": 2000, "Security Engineer": 2000,
    "PR Sentinel": 500,
}

total = 0
print(f"{'AGENT':<22} {'MODEL':<8} {'HEARTBEAT':<10} {'INTERVAL':<10} {'MAX_CONC':<9} {'BUDGET (EUR/mo)':<16}")
print("-" * 80)

for a in sorted(agents, key=lambda x: x["name"]):
    aid = a["id"]
    name = a["name"]
    model = a.get("adapterConfig", {}).get("model", "n/a")
    cap_cents = budget.get(name, 1000)
    total += cap_cents

    body = {
        "runtimeConfig": {
            "heartbeat": {
                "enabled": False,         # OFF by default — wake only on demand
                "cooldownSec": 10,
                "intervalSec": 1800,       # if later enabled, default to 30 min
                "wakeOnDemand": True,      # still respond to explicit assignment
                "maxConcurrentRuns": 2     # was 5 — caps simultaneous LLM calls
            }
        },
        "budgetMonthlyCents": cap_cents
    }
    req = urllib.request.Request(
        f"{API}/agents/{aid}",
        data=json.dumps(body).encode(),
        method="PATCH",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            ok = r.status == 200
    except urllib.error.HTTPError as e:
        ok = False
        sys.stderr.write(f"  ERROR PATCH {name}: HTTP {e.code} {e.reason}\n")
    except Exception as e:
        ok = False
        sys.stderr.write(f"  ERROR PATCH {name}: {e}\n")

    mark = "✓" if ok else "✗"
    print(f"{mark} {name:<20} {model:<8} {'OFF':<10} {'1800s':<10} {2:<9} €{cap_cents/100:>14.2f}")

print("-" * 80)
print(f"  {'TOTAL MONTHLY CAP':<53} €{total/100:>14.2f}")
print()
print("Defaults applied. Heartbeat is OFF for ALL agents — they will wake")
print("only when explicitly assigned a task (wakeOnDemand=true).")
print()
print("To temporarily enable an agent for active work:")
print("    ./scripts/paperclip-agent.sh on \"Frontend Engineer\"")
print("    ./scripts/paperclip-agent.sh off \"Frontend Engineer\"   # turn it back off")
print("    ./scripts/paperclip-agent.sh status                       # see what's enabled")
PYEOF
