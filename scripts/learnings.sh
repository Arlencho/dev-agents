#!/usr/bin/env bash
set -euo pipefail

# Learnings CLI -- persistent agent memory across sessions
# Storage: learnings/<project>.jsonl (one JSON object per line)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEARNINGS_DIR="$SCRIPT_DIR/../learnings"
CONFIG="$SCRIPT_DIR/../config/learnings.yaml"

# Defaults from config (parsed with grep, no yaml lib needed)
MAX_INJECT=$(grep 'max_inject:' "$CONFIG" 2>/dev/null | awk '{print $2}' || echo 10)
MAX_AGE_DAYS=$(grep 'max_age_days:' "$CONFIG" 2>/dev/null | awk '{print $2}' || echo 90)
MIN_SEVERITY=$(grep 'min_severity:' "$CONFIG" 2>/dev/null | awk '{print $2}' || echo "low")

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
    add <project> <agent> <type> <summary>   Add a learning
    query <project> [--agent X] [--limit N]  Query learnings for a project
    prune [--older-than 90d]                 Remove stale entries
    stats                                    Show learnings stats

Types: failure, discovery, pattern
Severity: --severity high|medium|low (default: medium)
EOF
    exit 1
}

# --- Helpers ---

severity_rank() {
    case "$1" in
        high)   echo 3 ;;
        medium) echo 2 ;;
        low)    echo 1 ;;
        *)      echo 0 ;;
    esac
}

now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_from_iso() {
    local ts="$1"
    if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null; then
        return
    fi
    # GNU date fallback
    date -d "$ts" +%s 2>/dev/null || echo 0
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

build_json_line() {
    local ts="$1" project="$2" agent="$3" type="$4" summary="$5" severity="$6"
    summary=$(json_escape "$summary")
    printf '{"ts":"%s","project":"%s","agent":"%s","type":"%s","summary":"%s","severity":"%s"}\n' \
        "$ts" "$project" "$agent" "$type" "$summary" "$severity"
}

# --- Commands ---

cmd_add() {
    local project="" agent="" type="" summary="" severity="medium"

    # Parse positional + flags
    local positionals=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --severity)
                severity="${2:?--severity requires a value}"
                shift 2
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    project="${positionals[0]:?Missing project}"
    agent="${positionals[1]:?Missing agent}"
    type="${positionals[2]:?Missing type (failure|discovery|pattern)}"
    summary="${positionals[3]:?Missing summary}"

    # Validate type
    case "$type" in
        failure|discovery|pattern) ;;
        *) echo "ERROR: type must be failure, discovery, or pattern"; exit 1 ;;
    esac

    # Validate severity
    case "$severity" in
        high|medium|low) ;;
        *) echo "ERROR: severity must be high, medium, or low"; exit 1 ;;
    esac

    local file="$LEARNINGS_DIR/${project}.jsonl"
    local line
    line=$(build_json_line "$(now_iso)" "$project" "$agent" "$type" "$summary" "$severity")
    echo "$line" >> "$file"
    echo "Added $type learning for $project/$agent [$severity]"
}

cmd_query() {
    local project="${1:?Missing project}"; shift
    local agent_filter="" limit="$MAX_INJECT"

    while [ $# -gt 0 ]; do
        case "$1" in
            --agent)
                agent_filter="${2:?--agent requires a value}"
                shift 2
                ;;
            --limit)
                limit="${2:?--limit requires a number}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local file="$LEARNINGS_DIR/${project}.jsonl"
    if [ ! -f "$file" ]; then
        return 0
    fi

    local min_rank
    min_rank=$(severity_rank "$MIN_SEVERITY")

    # Filter and format using jq if available, otherwise python3
    if command -v jq >/dev/null 2>&1; then
        local jq_filter="."
        if [ -n "$agent_filter" ]; then
            jq_filter="$jq_filter | select(.agent == \"$agent_filter\")"
        fi
        # Severity filter
        jq_filter="$jq_filter | select(
            (.severity == \"high\") or
            ($min_rank <= 2 and .severity == \"medium\") or
            ($min_rank <= 1 and .severity == \"low\")
        )"

        jq -r "$jq_filter | \"[\(.ts | split(\"T\")[0])] [\(.severity)] [\(.type)] \(.agent): \(.summary)\"" "$file" \
            | tail -n "$limit"
    else
        python3 -c "
import json, sys

min_rank = $min_rank
agent_filter = '$agent_filter'
limit = $limit
severity_map = {'high': 3, 'medium': 2, 'low': 1}
results = []

for line in open('$file'):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if agent_filter and obj.get('agent') != agent_filter:
        continue
    rank = severity_map.get(obj.get('severity', 'low'), 0)
    if rank < min_rank:
        continue
    ts_date = obj['ts'].split('T')[0]
    results.append(f'[{ts_date}] [{obj[\"severity\"]}] [{obj[\"type\"]}] {obj[\"agent\"]}: {obj[\"summary\"]}')

for line in results[-limit:]:
    print(line)
"
    fi
}

cmd_prune() {
    local max_age="$MAX_AGE_DAYS"

    while [ $# -gt 0 ]; do
        case "$1" in
            --older-than)
                max_age="${2:?--older-than requires a value like 90d}"
                max_age="${max_age%d}"  # strip trailing 'd'
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local now_epoch
    now_epoch=$(date +%s)
    local cutoff_epoch=$((now_epoch - max_age * 86400))
    local total_pruned=0

    for file in "$LEARNINGS_DIR"/*.jsonl; do
        [ -f "$file" ] || continue
        local tmp="${file}.tmp"
        local before after

        before=$(wc -l < "$file" | tr -d ' ')

        if command -v jq >/dev/null 2>&1; then
            while IFS= read -r line; do
                ts=$(echo "$line" | jq -r '.ts')
                entry_epoch=$(epoch_from_iso "$ts")
                if [ "$entry_epoch" -ge "$cutoff_epoch" ]; then
                    echo "$line"
                fi
            done < "$file" > "$tmp"
        else
            python3 -c "
import json, sys
from datetime import datetime, timezone

cutoff_epoch = $cutoff_epoch
for line in open('$file'):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    ts = obj.get('ts', '')
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        if dt.timestamp() >= cutoff_epoch:
            print(line)
    except:
        print(line)  # keep unparseable entries
" > "$tmp"
        fi

        after=$(wc -l < "$tmp" | tr -d ' ')
        local pruned=$((before - after))
        total_pruned=$((total_pruned + pruned))
        mv "$tmp" "$file"

        if [ "$pruned" -gt 0 ]; then
            echo "Pruned $pruned entries from $(basename "$file")"
        fi
    done

    echo "Total pruned: $total_pruned entries (older than ${max_age} days)"
}

cmd_stats() {
    local has_data=false

    printf "%-20s %-15s %-10s %-10s %-10s %-10s\n" "PROJECT" "AGENT" "FAILURES" "DISCOVERS" "PATTERNS" "TOTAL"
    printf "%-20s %-15s %-10s %-10s %-10s %-10s\n" "-------" "-----" "--------" "---------" "--------" "-----"

    for file in "$LEARNINGS_DIR"/*.jsonl; do
        [ -f "$file" ] || continue
        has_data=true
        local project
        project=$(basename "$file" .jsonl)

        if command -v jq >/dev/null 2>&1; then
            jq -rs "group_by(.agent) | .[] |
                {agent: .[0].agent,
                 f: [.[] | select(.type==\"failure\")] | length,
                 d: [.[] | select(.type==\"discovery\")] | length,
                 p: [.[] | select(.type==\"pattern\")] | length} |
                \"$project\" + \"\t\" + .agent + \"\t\" + (.f|tostring) + \"\t\" + (.d|tostring) + \"\t\" + (.p|tostring) + \"\t\" + ((.f+.d+.p)|tostring)" \
                "$file" | while IFS=$'\t' read -r proj ag f d p t; do
                printf "%-20s %-15s %-10s %-10s %-10s %-10s\n" "$proj" "$ag" "$f" "$d" "$p" "$t"
            done
        else
            python3 -c "
import json
from collections import defaultdict

counts = defaultdict(lambda: defaultdict(int))
for line in open('$file'):
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    agent = obj.get('agent', 'unknown')
    typ = obj.get('type', 'unknown')
    counts[agent][typ] += 1

for agent, types in sorted(counts.items()):
    f = types.get('failure', 0)
    d = types.get('discovery', 0)
    p = types.get('pattern', 0)
    t = f + d + p
    print(f'$project'.ljust(20) + agent.ljust(15) + str(f).ljust(10) + str(d).ljust(10) + str(p).ljust(10) + str(t).ljust(10))
"
        fi
    done

    if [ "$has_data" = false ]; then
        echo "(no learnings recorded yet)"
    fi
}

# --- Main ---

[ $# -ge 1 ] || usage

COMMAND="$1"; shift

case "$COMMAND" in
    add)    cmd_add "$@" ;;
    query)  cmd_query "$@" ;;
    prune)  cmd_prune "$@" ;;
    stats)  cmd_stats ;;
    *)      usage ;;
esac
