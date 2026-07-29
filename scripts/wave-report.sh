#!/usr/bin/env bash
# Fleet Evidence Scorecard — read-only aggregation over existing artifacts.
# Usage:
#   ./scripts/wave-report.sh              # full report + write logs/evidence.csv
#   ./scripts/wave-report.sh --no-write   # stdout only
#   ./scripts/wave-report.sh --wave 11    # filter one wave directory
#
# Inputs (best-effort; missing fields → unknown / n=0):
#   wave-plans/*/handoffs/*.jsonl
#   wave-plans/*/handoffs/*.md          (do_not_repeat classes)
#   wave-plans/ab-metrics.csv
#   logs/provider-state/                (via note; rate-cap summary)
#
# Outputs:
#   terminal tables
#   logs/evidence.csv          (gitignored area under logs/)
#   logs/evidence-latest.txt   (last full text report)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WRITE=true
WAVE_FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-write) WRITE=false; shift ;;
        --wave) WAVE_FILTER="${2:?}"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

export REPO_DIR WAVE_FILTER
export EVIDENCE_WRITE=$([ "$WRITE" = true ] && echo 1 || echo 0)
OUT_DIR="$REPO_DIR/logs"
mkdir -p "$OUT_DIR"

python3 - <<'PY'
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

repo = Path(os.environ["REPO_DIR"])
wave_filter = os.environ.get("WAVE_FILTER") or ""
wp = repo / "wave-plans"
logs = repo / "logs"

# ── Collect JSONL task records (last line per file wins for same task_id) ──
tasks = {}  # task_id -> record
jsonl_files = sorted(wp.glob("*/handoffs/*.jsonl"))
if wave_filter:
    jsonl_files = [p for p in jsonl_files if p.parts[-3] == wave_filter or p.parent.parent.name == wave_filter]

for path in jsonl_files:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").strip().splitlines()
    except OSError:
        continue
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("event") == "failover":
            tid = obj.get("task_id", "")
            if tid not in tasks:
                tasks[tid] = {"task_id": tid, "failovers": []}
            tasks.setdefault(tid, {}).setdefault("failovers", []).append(obj)
            continue
        tid = obj.get("task_id") or path.stem
        # merge failovers if we saw events first
        prev_fo = tasks.get(tid, {}).get("failovers", [])
        tasks[tid] = obj
        if prev_fo:
            tasks[tid]["failovers"] = prev_fo + obj.get("failovers", [])
        # wave from path if missing
        if "wave" not in tasks[tid] or tasks[tid].get("wave") in (None, ""):
            parent_wave = path.parent.parent.name
            if parent_wave.isdigit():
                tasks[tid]["wave"] = int(parent_wave)
        tasks[tid]["_jsonl_path"] = str(path.relative_to(repo))

# ── Pair handoff.md do_not_repeat classes ──
dnr_by_task = {}
dnr_global = Counter()
for path in sorted(wp.glob("*/handoffs/*.md")):
    if wave_filter and path.parent.parent.name != wave_filter:
        continue
    tid = path.stem
    text = path.read_text(encoding="utf-8", errors="replace")
    # Section "## Do not repeat" until next ##
    m = re.search(r"(?is)##\s*do not repeat\s*\n(.*?)(?=\n##\s|\Z)", text)
    classes = []
    if m:
        body = m.group(1)
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("-"):
                item = re.sub(r"^-\s*", "", line).strip()
                if item:
                    # normalize for rework: lower, collapse space, first 80 chars
                    key = re.sub(r"\s+", " ", item.lower())[:80]
                    classes.append(key)
                    dnr_global[key] += 1
    dnr_by_task[tid] = classes

# Rework: class seen in more than one task
rework_classes = {k for k, c in dnr_global.items() if c > 1}

# ── ab-metrics.csv ──
ab_rows = []
ab_path = wp / "ab-metrics.csv"
if ab_path.is_file():
    with ab_path.open(encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ab_rows.append(row)

# ── Aggregate ──
by_vendor = Counter()
by_vendor_ok = Counter()
by_agent = Counter()
by_status = Counter()
pair_counts = Counter()  # (producer_agent, vendor) 
# critic verdicts: from ab-metrics notes or agent name containing critic
critic_pass = 0
critic_block = 0

records = []
for tid, t in sorted(tasks.items()):
    if t.get("event") == "failover" and "agent" not in t:
        continue
    prov = t.get("provenance") or {}
    vendor = prov.get("vendor") or "unknown"
    requested = prov.get("requested_model") or ""
    effective = prov.get("effective_model") or ""
    legacy_model = prov.get("model") or ""
    # Backfill Ground Truth semantics for pre-#35 ledgers
    if not requested:
        requested = legacy_model
    if not effective:
        if vendor in ("kimi", "grok") and legacy_model in ("", "opus", "sonnet", "haiku"):
            effective = "vendor-default-k3" if vendor == "kimi" else "vendor-default"
            if legacy_model in ("opus", "sonnet", "haiku"):
                effective = f"legacy-mislabel:{legacy_model}"
        else:
            effective = legacy_model or requested or "unknown"
    agent = t.get("agent") or "unknown"
    status = t.get("status") or "unknown"
    exit_code = (t.get("orchestrator_fields") or {}).get("agent_exit", "")
    fo = len(t.get("failovers") or [])
    dnr = dnr_by_task.get(tid, [])
    rework = sum(1 for c in dnr if c in rework_classes)

    by_vendor[vendor] += 1
    if status == "done" or str(exit_code) == "0":
        by_vendor_ok[vendor] += 1
    by_agent[agent] += 1
    by_status[status] += 1
    pair_counts[(agent, vendor)] += 1

    records.append({
        "task_id": tid,
        "wave": t.get("wave", ""),
        "agent": agent,
        "vendor": vendor,
        "requested_model": requested,
        "effective_model": effective,
        "status": status,
        "agent_exit": exit_code,
        "failovers": fo,
        "dnr_count": len(dnr),
        "rework_hits": rework,
        "branch": t.get("branch", ""),
    })

for row in ab_rows:
    try:
        cb = int(row.get("critic_block") or 0)
    except ValueError:
        cb = 0
    if cb:
        critic_block += 1
    else:
        critic_pass += 1

# ── Print report ──
lines = []
def out(s=""):
    lines.append(s)
    print(s)

out("=" * 60)
out("  Fleet Evidence Scorecard")
out("=" * 60)
out()
out(f"JSONL task records: {len(records)}  (from wave-plans/*/handoffs/*.jsonl)")
out(f"Handoff MD files with DNR parse: {len(dnr_by_task)}")
out(f"ab-metrics rows: {len(ab_rows)}")
if wave_filter:
    out(f"Wave filter: {wave_filter}")
out()

out("Status counts")
for s, n in by_status.most_common():
    out(f"  {s:12} {n}")
out()

out("Per vendor (n + success)")
out(f"  {'vendor':8} {'n':>5} {'ok':>5} {'ok%':>6}")
for v in sorted(by_vendor.keys()):
    n = by_vendor[v]
    ok = by_vendor_ok[v]
    pct = f"{100*ok/n:.0f}%" if n else "n/a"
    out(f"  {v:8} {n:5} {ok:5} {pct:>6}")
out()

out("Per agent × vendor (n)")
out(f"  {'agent':20} {'vendor':8} {'n':>5}")
for (agent, vendor), n in sorted(pair_counts.items(), key=lambda x: (-x[1], x[0][0], x[0][1])):
    out(f"  {agent:20} {vendor:8} {n:5}")
out()

out("Provenance sanity (kimi must not look like Claude tier alone)")
kimi_rows = [r for r in records if r["vendor"] == "kimi"]
fake = [r for r in kimi_rows if r["effective_model"] in ("sonnet", "opus", "haiku")]
# Old ledgers only had model=sonnet without effective_model
legacy_kimi = [r for r in kimi_rows if r["effective_model"] == "sonnet" and not r.get("requested_model")]
out(f"  kimi tasks: {len(kimi_rows)}")
out(f"  kimi with effective=sonnet/opus/haiku (legacy or bug): {len(fake)}")
if legacy_kimi and not any(r.get("requested_model") for r in kimi_rows):
    out("  note: pre-Ground-Truth ledgers stored model=sonnet for kimi; re-run waves after #35 for effective_model")
out()

out("ab-metrics critic_block (when CSV present)")
if ab_rows:
    out(f"  rows={len(ab_rows)}  critic_block=0: {critic_pass}  critic_block>0: {critic_block}")
    by_arm = Counter(r.get("arm", "?") for r in ab_rows)
    out(f"  arms: {dict(by_arm)}")
else:
    out("  (no wave-plans/ab-metrics.csv)")
out()

out("Do-not-repeat rework signal (heuristic)")
out(f"  unique DNR classes: {len(dnr_global)}")
out(f"  classes appearing in >1 task (rework candidates): {len(rework_classes)}")
if rework_classes:
    out("  top repeated classes:")
    for k, c in dnr_global.most_common(8):
        if c > 1:
            out(f"    n={c}  {k[:70]}")
out()

out("Kimi frontend seat gate (informational)")
kimi_fe = [r for r in records if r["agent"] == "web-frontend" and r["vendor"] == "kimi"]
out(f"  web-frontend×kimi tasks in ledger: n={len(kimi_fe)}")
if len(kimi_fe) < 5:
    out("  bar: need ~5–10 tasks of evidence before keep/revert (README gate)")
else:
    ok = sum(1 for r in kimi_fe if r["status"] == "done" or str(r["agent_exit"]) == "0")
    out(f"  done/success: {ok}/{len(kimi_fe)}")
out()

out("Notes")
out("  - Percentages without n are noise; n is shown above.")
out("  - Verdict extraction for critics is incomplete unless ab-metrics or future structured fields exist.")
out("  - Raw agent logs stay in logs/ + ~/dev/agent-logs (not committed).")
out("=" * 60)

report_text = "\n".join(lines) + "\n"

# CSV for trends (no secrets — task ids, vendors, statuses only)
csv_path = logs / "evidence.csv"
write = os.environ.get("EVIDENCE_WRITE", "1") == "1"
if write:
    logs.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "task_id", "wave", "agent", "vendor", "requested_model", "effective_model",
        "status", "agent_exit", "failovers", "dnr_count", "rework_hits", "branch",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in records:
            w.writerow({k: r.get(k, "") for k in fieldnames})
    (logs / "evidence-latest.txt").write_text(report_text, encoding="utf-8")
    print(f"\nWrote {csv_path.relative_to(repo)}")
    print(f"Wrote logs/evidence-latest.txt")
PY
