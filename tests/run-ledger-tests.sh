#!/bin/bash
# Fleet optimization W1: the ledger (scripts/ledger.py, docs/ledger.md).
# No network, no vendor CLIs, no gh: every fixture is a small file shaped
# like the real logs inventoried in docs/ledger.md (a first-party result
# line, a kimi text log, a grok text log, event streams, a dispatch run log,
# a dispatch with no run log whose seat_log names the later critic file, a
# shared critic log holding two result lines, plans that cite other rounds).
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
the seat quotes a result line it found while reviewing, which is narration, not a record:
{"duration_api_ms":420000,"session_id":"quoted-not-a-cost","total_cost_usd":9.99,"usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1},"modelUsage":{},"is_error":false,"num_turns":1,"subtype":"success","type":"result","duration_ms":60000}
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

# ── fixture (finding 1): no run log; the seat_log event names the later ──────
# critic seat's file; the result line lives in the seat's own log under the
# seat log directory. Shaped like dispatch 20260913-083601-dev-agents.
SEATLOGS="$SANDBOX/agent-logs"
mkdir -p "$SEATLOGS"

cat > "$PLANS/dev-agents/2026-09-13-no-runlog.plan" <<'EOF'
# No-run-log fixture for the ledger. Issue 998.
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/2026-09-13-no-runlog.plan --detach --retries 1

1 | devops | producer seat | feat/no-runlog
EOF

cat > "$LOGS/fleet-events/20260913-140000-dev-agents-7777.jsonl" <<'EOF'
{"schema":"fleet-events/1","seq":1,"ts":"2026-09-13T14:00:00Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"2026-09-13-no-runlog.plan"}
{"schema":"fleet-events/1","seq":2,"ts":"2026-09-13T14:00:10Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"wave_start","wave":1,"seats":1,"mode":"wave"}
{"schema":"fleet-events/1","seq":3,"ts":"2026-09-13T14:00:10Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/no-runlog","wave":1,"provider":"claude","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":4,"ts":"2026-09-13T14:26:08Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"seat_exit","task_id":"0","agent":"devops","branch":"feat/no-runlog","wave":1,"provider":"claude","status":"success","exit":0,"duration_s":1558,"attempt":1}
{"schema":"fleet-events/1","seq":5,"ts":"2026-09-13T14:26:08Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"seat_log","task_id":"0","log":"dev-agents-feat-no-runlog-20260913-142608.log"}
{"schema":"fleet-events/1","seq":6,"ts":"2026-09-13T14:26:08Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"wave_end","wave":1,"seats":1,"succeeded":1,"failed":0}
{"schema":"fleet-events/1","seq":7,"ts":"2026-09-13T14:26:10Z","dispatch_id":"20260913-140000-dev-agents-7777","event":"dispatch_end","status":"completed","total":1,"succeeded":1,"failed":0,"duration_s":1570}
EOF

# The file the seat_log event names is the later critic seat's: no result line.
cat > "$LOGS/dev-agents-feat-no-runlog-20260913-142608.log" <<'EOF'
prose from the critic seat, no cost anywhere
EOF

# The result line lives only in the seat's own log in the seat log directory
# (durations match the real seat: duration_s 1558, duration_ms 1551113).
cat > "$SEATLOGS/dev-agents-feat-no-runlog-20260913-140010.log" <<'EOF'
stream lines from the seat
{"duration_api_ms":876451,"session_id":"fixture-claude-seat-0002","total_cost_usd":8.221354,"usage":{"input_tokens":738,"cache_creation_input_tokens":183295,"cache_read_input_tokens":2793104,"output_tokens":76938},"modelUsage":{"claude-fable-5-1":{"inputTokens":738,"outputTokens":76938,"cacheReadInputTokens":2793104,"cacheCreationInputTokens":183295,"costUSD":8.221354,"provider":"firstParty"}},"is_error":false,"num_turns":52,"subtype":"success","type":"result","duration_ms":1551113}
EOF

# ── fixture (findings 1 and 5): two parallel first-party seats whose dispatch ──
# stamps the same later log onto every task_id; that log holds both result
# lines, so the seats are told apart by duration. Parallel seats also make
# seat hours pass wall hours, where the old work share passed 100%.
cat > "$PLANS/dev-agents/2026-09-13-shared-log.plan" <<'EOF'
# Shared-log fixture for the ledger. Issue 997.
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/2026-09-13-shared-log.plan --detach --retries 1

1 | devops | first seat | feat/shared-log
1 | devops | second seat | feat/shared-log
EOF

cat > "$LOGS/fleet-events/20260913-150000-dev-agents-6666.jsonl" <<'EOF'
{"schema":"fleet-events/1","seq":1,"ts":"2026-09-13T15:00:00Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"dispatch_start","mode":"wave","repo":"dev-agents","plan":"2026-09-13-shared-log.plan"}
{"schema":"fleet-events/1","seq":2,"ts":"2026-09-13T15:00:05Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"wave_start","wave":1,"seats":2,"mode":"wave"}
{"schema":"fleet-events/1","seq":3,"ts":"2026-09-13T15:00:05Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_dispatch","task_id":"0","agent":"devops","branch":"feat/shared-log","wave":1,"provider":"claude","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":4,"ts":"2026-09-13T15:00:05Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_dispatch","task_id":"1","agent":"devops","branch":"feat/shared-log","wave":1,"provider":"claude","model":"claude-fable-5-1","worker":"localhost","attempt":1}
{"schema":"fleet-events/1","seq":5,"ts":"2026-09-13T15:10:07Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_exit","task_id":"1","agent":"devops","branch":"feat/shared-log","wave":1,"provider":"claude","status":"success","exit":0,"duration_s":602,"attempt":1}
{"schema":"fleet-events/1","seq":6,"ts":"2026-09-13T15:21:36Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_exit","task_id":"0","agent":"devops","branch":"feat/shared-log","wave":1,"provider":"claude","status":"success","exit":0,"duration_s":1291,"attempt":1}
{"schema":"fleet-events/1","seq":7,"ts":"2026-09-13T15:21:36Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_log","task_id":"0","log":"dev-agents-feat-shared-log-20260913-152136.log"}
{"schema":"fleet-events/1","seq":8,"ts":"2026-09-13T15:21:36Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"seat_log","task_id":"1","log":"dev-agents-feat-shared-log-20260913-152136.log"}
{"schema":"fleet-events/1","seq":9,"ts":"2026-09-13T15:21:36Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"wave_end","wave":1,"seats":2,"succeeded":2,"failed":0}
{"schema":"fleet-events/1","seq":10,"ts":"2026-09-13T15:21:40Z","dispatch_id":"20260913-150000-dev-agents-6666","event":"dispatch_end","status":"completed","total":2,"succeeded":2,"failed":0,"duration_s":1300}
EOF

cat > "$LOGS/dev-agents-feat-shared-log-20260913-152136.log" <<'EOF'
{"duration_api_ms":700000,"session_id":"fixture-claude-seat-0003","total_cost_usd":4.02941825,"usage":{"input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":9000,"output_tokens":2000},"modelUsage":{"claude-fable-5-1":{"inputTokens":100,"outputTokens":2000,"cacheReadInputTokens":9000,"cacheCreationInputTokens":1000,"costUSD":4.02941825,"provider":"firstParty"}},"is_error":false,"num_turns":30,"subtype":"success","type":"result","duration_ms":1282044}
{"duration_api_ms":300000,"session_id":"fixture-claude-seat-0004","total_cost_usd":0.5,"usage":{"input_tokens":50,"cache_creation_input_tokens":500,"cache_read_input_tokens":4500,"output_tokens":1000},"modelUsage":{"claude-fable-5-1":{"inputTokens":50,"outputTokens":1000,"cacheReadInputTokens":4500,"cacheCreationInputTokens":500,"costUSD":0.5,"provider":"firstParty"}},"is_error":false,"num_turns":15,"subtype":"success","type":"result","duration_ms":602000}
EOF

# ── fixture (finding 2): round is the plan's own round, never the highest ────
# round number mentioned anywhere in the plan text.
cat > "$PLANS/dev-agents/p1-critic-round2.plan" <<'EOF'
# Critic round 2 fixture: the backend critic round 3 is SAFE.
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/p1-critic-round2.plan --detach

1 | plan-critic | READ-ONLY REVIEW ROUND 2 of the thing. | feat/x
EOF

cat > "$PLANS/dev-agents/p2-first-pass.plan" <<'EOF'
# First pass fixture, no round declared.
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/p2-first-pass.plan --detach

1 | devops | build the thing; the critic seat follows for round 2 | feat/y
EOF

cat > "$PLANS/dev-agents/p3-fix1.plan" <<'EOF'
# FIX-ROUND: 1 of wave-plans/dev-agents/p2-first-pass.plan
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/p3-fix1.plan --detach

1 | devops | fix every finding | feat/y
EOF

cat > "$PLANS/dev-agents/p4-fix1.plan" <<'EOF'
# FIX-ROUND: 2026-09-13-p2-first-pass.plan
# DISPATCH: ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git wave-plans/dev-agents/p4-fix1.plan --detach

1 | devops | fix every finding | feat/y
EOF

# ── build once ───────────────────────────────────────────────────────────────
python3 "$LEDGER" build --logs-dir "$LOGS" --wave-plans-dir "$PLANS" \
    --seat-logs-dir "$SEATLOGS" --no-gh >/dev/null 2>"$SANDBOX/build.err" \
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
D3=20260913-140000-dev-agents-7777
D4=20260913-150000-dev-agents-6666

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
check "a result line quoted in a kimi log is not a cost" "None" "$(read_record $D1 1 "r['session_id']")"

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

echo "== finding 1: the cost is read from wherever the result line is =="
check "run log missing, seat_log names a later file: cost found" "8.221354" "$(read_record $D3 0 "r['cost_usd']")"
check "that seat is cost known"              "True"    "$(read_record $D3 0 "r['cost_known']")"
check "shared log, two result lines: seat 0 matched by duration" "4.02941825" "$(read_record $D4 0 "r['cost_usd']")"
check "shared log, two result lines: seat 1 matched by duration" "0.5"  "$(read_record $D4 1 "r['cost_usd']")"
check "each seat keeps its own session"      "fixture-claude-seat-0003" "$(read_record $D4 0 "r['session_id']")"

echo "== finding 2: round is the plan's own round, never a text mention =="
plan_round() { # <plan path>
    python3 - "$REPO_DIR" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import ledger
print(ledger.plan_facts(sys.argv[2])["round"])
PY
}
check "round 2 plan citing round 3 records 2" "2" "$(plan_round "$PLANS/dev-agents/p1-critic-round2.plan")"
check "first pass citing round 2 records 1"   "1" "$(plan_round "$PLANS/dev-agents/p2-first-pass.plan")"
check "FIX-ROUND 1 header records 2"          "2" "$(plan_round "$PLANS/dev-agents/p3-fix1.plan")"
check "FIX-ROUND naming a path records 2, not 2027" "2" "$(plan_round "$PLANS/dev-agents/p4-fix1.plan")"

echo "== manual orchestrator reading, then a rebuild =="
python3 "$LEDGER" orchestrator --logs-dir "$LOGS" --date 2026-09-13 --usd 9.75 --note "fixture reading" 2>/dev/null
FIRST_SUM=$(md5 -q "$LOGS/fleet-ledger.jsonl" 2>/dev/null || md5sum < "$LOGS/fleet-ledger.jsonl")
python3 "$LEDGER" build --logs-dir "$LOGS" --wave-plans-dir "$PLANS" \
    --seat-logs-dir "$SEATLOGS" --no-gh >/dev/null 2>&1
SECOND_SUM=$(md5 -q "$LOGS/fleet-ledger.jsonl" 2>/dev/null || md5sum < "$LOGS/fleet-ledger.jsonl")
check "rebuild is byte-identical (no duplicates, manual kept)" "$FIRST_SUM" "$SECOND_SUM"
check "ledger holds exactly 6 seat records" "6" "$(grep -c '"kind": "seat"' "$LOGS/fleet-ledger.jsonl")"
check "manual reading survives the rebuild" "1" "$(grep -c '"source": "manual"' "$LOGS/fleet-ledger.jsonl")"

echo "== rollup: the manual reading is its own line, never a cap =="
ROLL=$(python3 "$LEDGER" rollup --logs-dir "$LOGS" 2>/dev/null)
check "manual line shown on its day" "1" "$(printf '%s' "$ROLL" | grep -c 'orchestrator session (manual): \$9.75')"
check "manual cost stays out of seat totals" "1" "$(printf '%s' "$ROLL" | grep -c 'TOTAL seats 6, cost \$14.25 + 2 unknown')"
check "unknown cost is said, not zeroed (initiative and round rows)" "2" "$(printf '%s' "$ROLL" | grep -c 'dev-agents #999 .*+ 1 unknown')"

echo "== finding 3: an all-unknown rollup prints cost unknown, never a zero =="
check "all-unknown initiative row says cost unknown" "1" "$(printf '%s' "$ROLL" | grep -cE '^dev-agents +1 +cost unknown ')"
check "all-unknown round row says cost unknown" "1" "$(printf '%s' "$ROLL" | grep -cE '^dev-agents +2 +1 +cost unknown ')"
check "no rollup prints \$0.00 for unknown seats" "0" "$(printf '%s' "$ROLL" | grep -c '\$0.00')"

echo "== finding 5: seat hours and wall hours, work share never over 100% =="
check "day rollup prints seat and wall columns" "1" "$(printf '%s' "$ROLL" | grep -cE '^day +seats +cost +active +seat +wall +work')"
check "parallel seats: 100% work, seat hours over wall hours" "ok" "$(python3 -c "
import json
d = json.load(open('$LOGS/ledger.json'))
i = next(x for x in d['initiatives'] if x['issue'] == 997)
assert i['active_s'] == 1893 and i['seat_elapsed_s'] == 1893 and i['elapsed_s'] == 1291, i
assert i['work_share'] == 1.0, i
print('ok')")"
check "no rollup work share above 100 percent" "0" "$(python3 -c "
import json
d = json.load(open('$LOGS/ledger.json'))
print(sum(1 for x in d['initiatives'] + d['days'] if (x['work_share'] or 0) > 1))")"
check "parallel initiative row shows 100% (old rule said 147%)" "1" "$(printf '%s' "$ROLL" | grep -c 'dev-agents #997 .*100%')"

echo "== finding 4: the docs name the file each traced line really comes from =="
check "8.22 example cites its own seat log" "1" "$(grep -c 'dev-agents-feat-detached-dispatch-20260913-103620.log' "$REPO_DIR/docs/ledger.md")"
check "no trace to the wrong dispatch run log" "0" "$(grep -c '20260913-132942-dev-agents-32845' "$REPO_DIR/docs/ledger.md")"

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
