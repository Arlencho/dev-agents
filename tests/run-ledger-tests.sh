#!/bin/bash
# Fleet optimization W1: the ledger (scripts/ledger.py, docs/ledger.md).
# No network, no vendor CLIs, no gh: every fixture is a small file shaped
# like the real logs inventoried in docs/ledger.md (a first-party result
# line, a kimi text log, a grok text log, event streams, a dispatch run log).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LEDGER="$REPO_DIR/scripts/ledger.py"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-56s -> %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-56s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

LOGS="$SANDBOX/logs"
PLANS="$SANDBOX/wave-plans"
mkdir -p "$LOGS/fleet-events" "$LOGS/dispatch-runs" "$PLANS/dev-agents"

# ── fixture: a plan naming an issue and a tier ───────────────────────────────
cat > "$PLANS/dev-agents/2026-09-13-two-wave.plan" <<'EOF'
# Two wave fixture for the ledger. Issue 999.
# TIER: C
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/2026-09-13-two-wave.plan --detach --retries 1

1 | devops | producer seat | feat/two-wave
2 | web-frontend | critic seat | feat/two-wave
EOF

cat > "$PLANS/dev-agents/2026-09-13-grok-fix.plan" <<'EOF'
# Grok fix-round fixture for the ledger.
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/2026-09-13-grok-fix.plan --detach --retries 1

1 | plan-critic | critic seat | feat/grok-seat
EOF

# ── fixture: event streams (waiting: wave 2 starts 120 s after wave 1 ends) ──
cat > "$LOGS/fleet-events/20260913-120000-dev-agents-9999.jsonl" <<'EOF'
{"schema":"fleet-events/1","seq":1,"ts":"2026-09-13T12:00:00Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"2026-09-13-two-wave.plan"}
{"schema":"fleet-events/1","seq":2,"ts":"2026-09-13T12:00:00Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"dispatch_plan","waves":2,"seats":2,"format":"wave"}
{"schema":"fleet-events/1","seq":3,"ts":"2026-09-13T12:00:10Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"wave_start","wave":1,"seats":1,"mode":"wave"}
{"schema":"fleet-events/1","seq":4,"ts":"2026-09-13T12:00:10Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/two-wave","wave":1,"provider":"claude","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":5,"ts":"2026-09-13T12:10:10Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"seat_exit","task_id":"0","agent":"devops","branch":"feat/two-wave","wave":1,"provider":"claude","status":"success","exit":0,"duration_s":600,"attempt":1}
{"schema":"fleet-events/1","seq":6,"ts":"2026-09-13T12:10:15Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"wave_end","wave":1,"seats":1,"succeeded":1,"failed":0}
{"schema":"fleet-events/1","seq":7,"ts":"2026-09-13T12:12:15Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"wave_start","wave":2,"seats":1,"mode":"wave"}
{"schema":"fleet-events/1","seq":8,"ts":"2026-09-13T12:12:15Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"seat_dispatch","task_id":"1","agent":"web-frontend","branch":"feat/two-wave","wave":2,"provider":"kimi","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":9,"ts":"2026-09-13T12:22:15Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"seat_exit","task_id":"1","agent":"web-frontend","branch":"feat/two-wave","wave":2,"provider":"kimi","status":"success","exit":0,"duration_s":600,"attempt":1}
{"schema":"fleet-events/1","seq":10,"ts":"2026-09-13T12:22:15Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"wave_end","wave":2,"seats":1,"succeeded":1,"failed":0}
{"schema":"fleet-events/1","seq":11,"ts":"2026-09-13T12:22:20Z","dispatch_id":"20260913-120000-dev-agents-9999","event":"dispatch_end","status":"completed","total":2,"succeeded":2,"failed":0,"duration_s":1340}
EOF

cat > "$LOGS/fleet-events/20260913-130000-dev-agents-8888.jsonl" <<'EOF'
{"schema":"fleet-events/1","seq":1,"ts":"2026-09-13T13:00:00Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"2026-09-13-grok-fix.plan"}
{"schema":"fleet-events/1","seq":2,"ts":"2026-09-13T13:00:05Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"wave_start","wave":1,"seats":1,"mode":"wave"}
{"schema":"fleet-events/1","seq":3,"ts":"2026-09-13T13:00:05Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"seat_dispatch","task_id":"0","agent":"plan-critic","branch":"feat/grok-seat","wave":1,"provider":"grok","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":4,"ts":"2026-09-13T13:01:05Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"seat_exit","task_id":"0","agent":"plan-critic","branch":"feat/grok-seat","wave":1,"provider":"grok","status":"failed","exit":1,"duration_s":60,"attempt":1}
{"schema":"fleet-events/1","seq":5,"ts":"2026-09-13T13:01:05Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"wave_end","wave":1,"seats":1,"succeeded":0,"failed":1}
{"schema":"fleet-events/1","seq":6,"ts":"2026-09-13T13:01:05Z","dispatch_id":"20260913-130000-dev-agents-8888","event":"dispatch_end","status":"failed","total":1,"succeeded":0,"failed":1,"duration_s":65}
EOF

# ── fixture: the dispatch run logs, seat sections shaped like the real ones ──
# The result line keeps the exact key set a real first-party seat writes
# (docs/ledger.md), with the prose field dropped.
cat > "$LOGS/dispatch-runs/20260913-120000-dev-agents-9999.log" <<'EOF'
Detached dispatch 20260913-120000-dev-agents-9999: pid 9999, session leader, started 2026-09-13T12:00:00Z
Repo: git@github.com:Arlencho/dev-agents.git
Starting claude launcher for agent devops (model: claude-fable-5-1)...
Logging to: /nonexistent/dev-agents-feat-two-wave-20260913-120010.log
{"duration_api_ms":420000,"stop_reason":"end_turn","session_id":"fixture-claude-seat-0001","total_cost_usd":1.5,"usage":{"input_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000,"output_tokens":4000},"modelUsage":{"claude-fable-5-1":{"inputTokens":100,"outputTokens":4000,"cacheReadInputTokens":30000,"cacheCreationInputTokens":2000,"costUSD":1.5,"provider":"firstParty"}},"is_error":false,"num_turns":12,"subtype":"success","type":"result","duration_ms":600000}
=== Agent completed on localhost ===
Starting kimi launcher for agent web-frontend (model: claude-fable-5-1)...
Logging to: /nonexistent/dev-agents-feat-two-wave-20260913-121215.log
kimi version 0.42.0
prose from the seat, no cost anywhere
To resume this session: kimi -r session_fixture
=== Agent completed on localhost ===
EOF

cat > "$LOGS/dispatch-runs/20260913-130000-dev-agents-8888.log" <<'EOF'
Detached dispatch 20260913-130000-dev-agents-8888: pid 8888, session leader, started 2026-09-13T13:00:00Z
Repo: git@github.com:Arlencho/dev-agents.git
Starting grok launcher for agent plan-critic (model: claude-fable-5-1)...
Logging to: /nonexistent/dev-agents-feat-grok-seat-20260913-130005.log
prose from the seat
Memory flush written: /Users/x/.grok/memory/y/sessions/z.md
=== Agent completed on localhost ===
EOF

# ── build once ───────────────────────────────────────────────────────────────
python3 "$LEDGER" build --logs-dir "$LOGS" --wave-plans-dir "$PLANS" --no-gh >/dev/null 2>"$SANDBOX/build.err" \
    || { echo "  FAIL build exited nonzero: $(cat "$SANDBOX/build.err")"; exit 1; }

read_record() { # <dispatch> <task> <python expr on r>
    python3 - "$LOGS/fleet-ledger.jsonl" "$1" "$2" "$3" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    r = json.loads(line)
    if r.get("dispatch_id") == sys.argv[2] and r.get("task_id") == sys.argv[3] and r.get("kind") == "seat":
        print(eval(sys.argv[4]))
        break
PY
}

D1=20260913-120000-dev-agents-9999
D2=20260913-130000-dev-agents-8888

echo "== first-party seat: cost and tokens from the result line =="
check "cost is the recorded 1.50"            "1.5"     "$(read_record $D1 0 "r['cost_usd']")"
check "cost_known true"                      "True"    "$(read_record $D1 0 "r['cost_known']")"
check "input tokens"                         "100"     "$(read_record $D1 0 "r['input_tokens']")"
check "output tokens"                        "4000"    "$(read_record $D1 0 "r['output_tokens']")"
check "cache read tokens"                    "30000"   "$(read_record $D1 0 "r['cache_read_tokens']")"
check "turns"                                "12"      "$(read_record $D1 0 "r['num_turns']")"
check "outcome success"                      "success" "$(read_record $D1 0 "r['outcome']")"
check "active time from seat_exit"           "600"     "$(read_record $D1 0 "r['active_s']")"
check "model recorded"                       "claude-fable-5-1" "$(read_record $D1 0 "r['model']")"
check "session id kept for dedupe"           "fixture-claude-seat-0001" "$(read_record $D1 0 "r['session_id']")"

echo "== kimi seat: no cost recorded, never zero =="
check "kimi cost_known false"                "False"   "$(read_record $D1 1 "r['cost_known']")"
check "kimi cost is null"                    "None"    "$(read_record $D1 1 "r['cost_usd']")"
check "kimi tokens null"                     "None"    "$(read_record $D1 1 "r['input_tokens']")"

echo "== grok seat: no cost recorded, failed outcome =="
check "grok cost_known false"                "False"   "$(read_record $D2 0 "r['cost_known']")"
check "grok cost is null"                    "None"    "$(read_record $D2 0 "r['cost_usd']")"
check "grok outcome failed"                  "failed"  "$(read_record $D2 0 "r['outcome']")"

echo "== plan headers: initiative, issue, tier, round =="
check "initiative from plan directory"       "dev-agents" "$(read_record $D1 0 "r['initiative']")"
check "issue from the header"                "999"     "$(read_record $D1 0 "r['issue']")"
check "tier from the TIER header"            "C"       "$(read_record $D1 0 "r['tier']")"
check "round defaults to 1"                  "1"       "$(read_record $D1 0 "r['round']")"
check "round from the plan name (-fix = 2)"  "2"       "$(read_record $D2 0 "r['round']")"
check "tier unknown when no header"          "unknown" "$(read_record $D2 0 "r['tier']")"
check "repository from the stream"           "dev-agents" "$(read_record $D1 0 "r['repository']")"
check "pr lookup skipped under --no-gh"      "skipped" "$(read_record $D1 0 "r['pr_lookup']")"

echo "== two-wave dispatch: waiting time between waves =="
check "wave 1 seat waits from dispatch start" "10"     "$(read_record $D1 0 "r['waiting_s']")"
check "wave 2 seat waits 120 s after wave 1"  "120"    "$(read_record $D1 1 "r['waiting_s']")"
check "waiting is not counted as active"      "600"    "$(read_record $D1 1 "r['active_s']")"

echo "== manual orchestrator reading, then a rebuild =="
python3 "$LEDGER" orchestrator --logs-dir "$LOGS" --date 2026-09-13 --usd 9.75 --note "fixture reading" 2>/dev/null
FIRST_SUM=$(md5 -q "$LOGS/fleet-ledger.jsonl" 2>/dev/null || md5sum < "$LOGS/fleet-ledger.jsonl")
python3 "$LEDGER" build --logs-dir "$LOGS" --wave-plans-dir "$PLANS" --no-gh >/dev/null 2>&1
SECOND_SUM=$(md5 -q "$LOGS/fleet-ledger.jsonl" 2>/dev/null || md5sum < "$LOGS/fleet-ledger.jsonl")
check "rebuild is byte-identical (no duplicates, manual kept)" "$FIRST_SUM" "$SECOND_SUM"
check "ledger holds exactly 3 seat records" "3" "$(grep -c '"kind": "seat"' "$LOGS/fleet-ledger.jsonl")"
check "manual reading survives the rebuild" "1" "$(grep -c '"source": "manual"' "$LOGS/fleet-ledger.jsonl")"

echo "== rollup: the manual reading is its own line, never a cap =="
ROLL=$(python3 "$LEDGER" rollup --logs-dir "$LOGS" 2>/dev/null)
check "manual line shown on its day" "1" "$(printf '%s' "$ROLL" | grep -c 'orchestrator session (manual): \$9.75')"
check "manual cost stays out of seat totals" "1" "$(printf '%s' "$ROLL" | grep -c 'TOTAL seats 3, cost \$1.50 + 2 unknown')"
check "unknown cost is said, not zeroed (initiative and round rows)" "2" "$(printf '%s' "$ROLL" | grep -c 'dev-agents #999 .*+ 1 unknown')"

echo "== ledger.json the desk reads =="
check "ledger.json written" "fleet-ledger-rollup/1" "$(python3 -c "import json; print(json.load(open('$LOGS/ledger.json'))['schema'])")"
check "initiative cost known flag" "False" "$(python3 -c "
import json
d = json.load(open('$LOGS/ledger.json'))
print(next(i['cost_known'] for i in d['initiatives'] if i['initiative'] == 'dev-agents' and i['issue'] == 999))")"
check "manual reading in ledger.json" "9.75" "$(python3 -c "
import json
d = json.load(open('$LOGS/ledger.json'))
print(d['orchestrator_manual'][0]['usd'])")"

echo "== the desk attaches the ledger line to an initiative row =="
check "desk joins on plan basenames, skips cleanly" "desk-attach-ok" "$(python3 - "$LOGS/ledger.json" "$REPO_DIR" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2] + "/scripts")
import desk_live
proj = {"view": "live",
        "initiatives": [{"repo": "dev-agents", "title": "X", "plans": ["2026-09-13-two-wave.plan"]},
                        {"repo": "dev-agents", "title": "Y", "plans": ["not-in-the-ledger.plan"]}],
        "initiatives_meta": {"count": 2}}
desk_live.attach_ledger(proj, ledger_file=sys.argv[1])
row, other = proj["initiatives"]
assert row["ledger"] and row["ledger"]["cost_usd"] == 1.5, row
assert row["ledger"]["cost_known"] is False and row["ledger"]["cost_unknown_seats"] == 1, row
assert other["ledger"] is None, other
assert proj["initiatives_meta"]["ledger"]["lookup"] == "ok"
desk_live.attach_ledger(proj, ledger_file=sys.argv[1] + ".missing")
assert proj["initiatives_meta"]["ledger"]["lookup"] == "skipped", proj["initiatives_meta"]
assert all(r["ledger"] is None for r in proj["initiatives"]), proj["initiatives"]
print("desk-attach-ok")
PY
)"

echo "----------------------------------------"
printf '  passed: %d   failed: %d\n' "$pass" "$fail"
echo "----------------------------------------"
[ "$fail" -eq 0 ]
