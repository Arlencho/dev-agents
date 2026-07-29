#!/usr/bin/env bash
# Fleet Desk tests — data contract (JSON) first, HTML projection second.
#
#   Part A: deterministic fixture repo (tests/fixtures/experience-mini)
#           joins · wave field · PMI bands + cap · redaction
#   Part A2: Phase 1 enrichment — skill git history, critic pairing, gh
#           degradation, snapshot (uses throwaway repos so git facts are real)
#   Part B: smoke build of this real repo through scripts/experience-build.sh
#
# Law: docs/proposals/experience-console-SYNTHESIS.md
# Schema: docs/experience-data.md
set -euo pipefail

# Phase 1 `gh` enrichment is optional and network-touching. Fixture builds pass
# --no-gh so Part A stays offline-deterministic; Part B exercises the real
# auto-detect path (and must pass with or without gh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/experience-mini"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# assert_json <name> <json file> <python expression over d/T/R/C/W/S/L>
assert_json() {
  local name="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
T = {t["task_id"]: t for t in d["trails"]}
R = d["role_stats"]
C = {c["id"]: c for c in d["companies"]}
W = {(str(w["wave"]) if w["wave"] is not None else "none"): w for w in d["waves"]}
S = {s["id"]: s for s in d["skills"]}
L = {l["slug"]: l for l in d["learnings"]}
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
  then ok "$name"; else bad "$name"; fi
}

# assert_absent <name> <dir> <ERE>
assert_absent() {
  local name="$1" dir="$2" pattern="$3"
  if grep -REl "$pattern" "$dir" >/dev/null 2>&1; then
    bad "$name (matched: $(grep -REl "$pattern" "$dir" | head -3 | tr '\n' ' '))"
  else
    ok "$name"
  fi
}

# assert_absent_html <name> <dir> <ERE> — HTML pages only (data/index.json may
# legitimately carry arbitrary handoff prose).
assert_absent_html() {
  local name="$1" dir="$2" pattern="$3"
  if grep -REl --include='*.html' "$pattern" "$dir" >/dev/null 2>&1; then
    bad "$name (matched: $(grep -REl --include='*.html' "$pattern" "$dir" | head -3 | tr '\n' ' '))"
  else
    ok "$name"
  fi
}

exists() { [ -f "$2" ] && ok "$1" || bad "$1"; }

# assert_links_resolve <name> <site dir> — crawl every relative href in built
# HTML and fail if any target is missing. A class="crumb" grep is satisfied by
# a 404; only resolving the link catches singular/plural crumb-depth bugs.
assert_links_resolve() {
  local name="$1" dir="$2"
  if python3 - "$dir" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
bad = []
for f in sorted(root.rglob("*.html")):
    for m in re.finditer(r'href="([^"]+)"', f.read_text()):
        u = m.group(1)
        if u.startswith(("http", "mailto:", "#")):
            continue
        p = (f.parent / u.split("#")[0]).resolve()
        if p.is_dir():
            p = p / "index.html"
        if not p.exists():
            bad.append(f"{f.relative_to(root)} -> {u}")
print(f"BROKEN: {len(bad)}")
for b in bad:
    print("  ", b)
sys.exit(1 if bad else 0)
PY
  then ok "$name"; else bad "$name"; fi
}

SECRET_SHAPES='gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|(api[_-]?key|password|secret|token)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]{16,}'
HOME_PATHS='/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/'

echo "== A. fixture repo (deterministic) =="
FIXOUT="$TMP/fixture-site"
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$FIX" --out "$FIXOUT" --no-gh >"$TMP/data.log" 2>&1 \
  && ok "experience_data.py builds fixture" || bad "experience_data.py builds fixture"
python3 "$REPO_DIR/scripts/experience_build.py" --repo "$FIX" --out "$FIXOUT" >"$TMP/html.log" 2>&1 \
  && ok "experience_build.py renders fixture" || bad "experience_build.py renders fixture"

FJ="$FIXOUT/data/index.json"
exists "fixture data/index.json" "$FJ"
assert_json "schema_version is pinned"            "$FJ" 'd["schema_version"] == 2'
assert_json "phase recorded as 1"                 "$FJ" 'd["phase"] == 1'
assert_json "generated_at + law recorded"         "$FJ" 'd["generated_at"] and d["law"].endswith("experience-console-SYNTHESIS.md")'
assert_json "32 trails projected"                 "$FJ" 'len(d["trails"]) == 32 == d["counts"]["trails"]'

# ── joins ────────────────────────────────────────────────────────────
assert_json "join: config_map (experience-joins.yaml)" "$FJ" \
  'T["1-fixture-builder-widget-x"]["join_method"] == "config_map" and T["1-fixture-builder-widget-x"]["company_id"] == "acme"'
assert_json "join: github_repo slug"                   "$FJ" \
  'T["1-fixture-builder-acme-app"]["join_method"] == "github_repo" and T["1-fixture-builder-acme-app"]["company_id"] == "acme"'
assert_json "join: company name token"                 "$FJ" \
  'T["2-fixture-builder-name-token"]["join_method"] == "name_token" and T["2-fixture-builder-name-token"]["company_id"] == "acme"'
assert_json "join: unlinked keeps project label only"  "$FJ" \
  'T["2-fixture-builder-gadget"]["join_method"] == "unlinked" and T["2-fixture-builder-gadget"]["company_id"] is None and T["2-fixture-builder-gadget"]["project_label"] == "gadget-lab"'
assert_json "join: no label invented when nothing matches" "$FJ" \
  'T["3-fixture-builder-plain"]["join_method"] == "unlinked" and T["3-fixture-builder-plain"]["project_label"] == ""'
assert_json "join: every company_id exists in companies/"  "$FJ" \
  'all(t["company_id"] is None or t["company_id"] in C for t in d["trails"])'
assert_json "join: unknown company in joins.yaml ignored + warned" "$FJ" \
  'any("nosuchcompany" in w for w in d["warnings"]) and all(t["company_id"] != "nosuchcompany" for t in d["trails"])'
assert_json "join: placeholder company gets no trails"     "$FJ" 'C["ghostco"]["trail_count"] == 0'
assert_json "join: every join_method is a known method"    "$FJ" \
  'set(t["join_method"] for t in d["trails"]) <= {"config_map","github_repo","repo_path","name_token","unlinked"}'
assert_json "join: join_evidence present when linked"      "$FJ" \
  'all(t["join_evidence"] for t in d["trails"] if t["company_id"])'
assert_json "join rules documented in payload"             "$FJ" 'len(d["join_rules"]) == 5'

# ── wave field ───────────────────────────────────────────────────────
assert_json "wave: field present on every trail"       "$FJ" 'all("wave" in t and "wave_source" in t for t in d["trails"])'
assert_json "wave: from handoff jsonl field"           "$FJ" 'T["1-fixture-builder-widget-x"]["wave"] == 1 and T["1-fixture-builder-widget-x"]["wave_source"] == "handoff_field"'
assert_json "wave: falls back to plan directory"       "$FJ" 'T["2-fixture-builder-name-token"]["wave"] == 2 and T["2-fixture-builder-name-token"]["wave_source"] == "plan_directory"'
assert_json "wave: null when unknown (conductor)"      "$FJ" 'T["conductor-fixture-note"]["wave"] is None and T["conductor-fixture-note"]["conductor"] is True'
assert_json "wave: grouping matches trails"            "$FJ" 'sum(w["n"] for w in d["waves"]) == len(d["trails"]) and W["5"]["n"] == 8'

# ── PMI ──────────────────────────────────────────────────────────────
assert_json "PMI: P2 when n_done>=5 and success>=70%"  "$FJ" 'R["fixture-veteran"]["pmi"]["band"] == "P2" and R["fixture-veteran"]["n_done"] == 5'
assert_json "PMI: n_done<5 stays P1 even at 80%"       "$FJ" 'R["fixture-runner"]["pmi"]["band"] == "P1" and R["fixture-runner"]["n_done"] == 4'
assert_json "PMI: success<70% stays P1 with n_done>=5" "$FJ" 'R["fixture-flaky"]["pmi"]["band"] == "P1" and R["fixture-flaky"]["n_done"] == 5 and R["fixture-flaky"]["success_rate"] < 0.7'
assert_json "PMI: n<3 is P0"                           "$FJ" 'R["fixture-critic"]["pmi"]["band"] == "P0"'
assert_json "PMI: specialized pack alone never grants P2" "$FJ" \
  'all(s["pmi"]["band"] not in ("P2","P3") or (s["n_done"] >= 5 and s["success_rate"] >= 0.7) for s in R.values())'
assert_json "PMI: inputs disclosed per role"           "$FJ" \
  'all({"n","n_done","n_fail","n_known","success_rate","packs","specialized_packs","proven_loop","proven_loop_evidence"} <= set(s["pmi"]["inputs"]) for s in R.values())'
assert_json "PMI: policy gates published"              "$FJ" \
  'd["pmi_policy"]["p2_min_done"] == 5 and d["pmi_policy"]["p2_min_success"] == 0.7 and d["pmi_policy"]["display_cap"] == "P3"'

# P3 (Phase 1) — outcomes PLUS proven-loop evidence, never one or the other.
assert_json "PMI: P3 needs the P2 outcome bar too"     "$FJ" \
  'all(s["pmi"]["band"] != "P3" or (s["n_done"] >= 5 and s["success_rate"] >= 0.7) for s in R.values())'
assert_json "PMI: P3 needs proven-loop evidence"       "$FJ" \
  'all(s["pmi"]["band"] != "P3" or s["pmi"]["inputs"]["proven_loop_evidence"] for s in R.values())'
assert_json "PMI: P2 without proven loop stays P2"     "$FJ" \
  'R["fixture-veteran"]["pmi"]["inputs"]["proven_loop"] is False and "no P3 yet" in R["fixture-veteran"]["pmi"]["reason"]'

# The three clauses of the P3 gate, each pinned by a fixture that would flip
# band if the clause were dropped. Without these the gate is only asserted by
# roles that pass or fail it for other reasons (vacuous coverage).
#
# (a) shared default packs are excluded — `specialized`, not `packs`.
#     evidence-first is a DEFAULT pack shaped to qualify twice over (v2, and it
#     promotes lesson-default), held by fixture-veteran, who clears P2 on
#     outcomes. Counting default packs as evidence sends every role to P3.
assert_json "PMI: qualifying default pack is real (fixture not vacuous)" "$FJ" \
  '(S["evidence-first"]["version"] >= 2 and S["evidence-first"]["promotes"] == ["lesson-default"]
    and "evidence-first" in R["fixture-veteran"]["pmi"]["inputs"]["packs"]
    and R["fixture-veteran"]["pmi"]["inputs"]["specialized_packs"] == [])'
assert_json "PMI: shared default pack never grants P3"  "$FJ" \
  '(R["fixture-veteran"]["pmi"]["band"] == "P2"
    and R["fixture-veteran"]["pmi"]["inputs"]["proven_loop_evidence"] == []
    and R["fixture-veteran"]["n_done"] >= 5 and R["fixture-veteran"]["success_rate"] >= 0.7)'
assert_json "PMI: no role cites a default pack as evidence" "$FJ" \
  'all(not e.startswith(("evidence-first", "untrusted-prior", "git-ship"))
       for s in R.values() for e in s["pmi"]["inputs"]["proven_loop_evidence"])'

# (b) P3 additionally requires the P2 OUTCOME bar. fixture-runner holds the
#     evidence-bearing pack but has n_done=4, so only the outcome clause keeps
#     it down; dropping `p2_ok` from the P3 branch sends it straight to P3.
assert_json "PMI: evidence without the P2 outcome bar stays below P3" "$FJ" \
  '(R["fixture-runner"]["pmi"]["inputs"]["proven_loop_evidence"]
    and R["fixture-runner"]["n_done"] == 4 < 5 and R["fixture-runner"]["success_rate"] >= 0.7
    and R["fixture-runner"]["pmi"]["band"] == "P1")'

# (c) the version path requires revisions ≥ 2, not merely version ≥ 2.
#     fixture-solo-pack is born at v2, promotes nothing, and is never revised;
#     fixture-solo clears P2 on outcomes, so only that clause holds the band.
#     `revisions < 2` is asserted so fixture rot fails loudly instead of silently.
assert_json "PMI: pack born at v2 but never revised is not a proven loop" "$FJ" \
  '(S["fixture-solo-pack"]["version"] == 2 and S["fixture-solo-pack"]["revisions"] < 2
    and S["fixture-solo-pack"]["promotes"] == []
    and R["fixture-solo"]["pmi"]["inputs"]["specialized_packs"] == ["fixture-solo-pack"]
    and R["fixture-solo"]["n_done"] >= 5 and R["fixture-solo"]["success_rate"] >= 0.7
    and R["fixture-solo"]["pmi"]["band"] == "P2"
    and R["fixture-solo"]["pmi"]["inputs"]["proven_loop_evidence"] == [])'
assert_json "PMI: P3 via learning→skill promotion"     "$FJ" \
  '(R["fixture-builder"]["pmi"]["band"] == "P3"
    and any("promotes" in e for e in R["fixture-builder"]["pmi"]["inputs"]["proven_loop_evidence"]))'
assert_json "PMI: no band above P3"                    "$FJ" \
  'all(s["pmi"]["band"] in ("P0","P1","P2","P3") and s["pmi"]["cap"] == "P3" for s in R.values())'
assert_json "PMI: cap reason states the P3 gate"       "$FJ" \
  '"proven-loop" in d["pmi_policy"]["cap_reason"] and "P3" in d["pmi_policy"]["cap_reason"]'
grep -q 'class="pmi band-p3">P3' "$FIXOUT/role/fixture-builder/index.html" \
  && ok "PMI: P3 band rendered with its own badge class" || bad "PMI: P3 band rendered with its own badge class"
grep -q 'band-p3' "$FIXOUT/assets/site.css" && ok "PMI: P3 badge is styled" || bad "PMI: P3 badge is styled"
if grep -R 'P3 Phase 1 only\|Phase 0 caps display' "$FIXOUT" >/dev/null 2>&1; then
  bad "PMI: Phase 0 caption retired now that P3 is real"
else
  ok "PMI: Phase 0 caption retired now that P3 is real"
fi

# ── Phase 1: skill git history ───────────────────────────────────────
assert_json "history: every skill carries the history fields" "$FJ" \
  'all({"git_history","revisions","history_available","history_depth","first_commit","last_commit","promotes"} <= set(s) for s in d["skills"])'
assert_json "history: projection publishes availability + depth" "$FJ" \
  'd["skill_history"]["depth"] == 20 and isinstance(d["skill_history"]["available"], bool)'
assert_json "history: commits carry sha + date + subject" "$FJ" \
  '(not d["skill_history"]["available"]
    or all({"sha","date","ts","subject"} <= set(c) and len(c["sha"]) <= 12 for s in d["skills"] for c in s["git_history"]))'
assert_json "history: depth is capped"                   "$FJ" \
  'all(len(s["git_history"]) <= s["history_depth"] for s in d["skills"])'
assert_json "history: promotion link is two-way"         "$FJ" \
  '("lesson-one" in [p for s in d["skills"] if s["id"] == "fixture-pack" for p in s["promotes"]]
    and "fixture-pack" in [x for l in d["learnings"] if l["slug"] == "lesson-one" for x in l["promoted_by"]])'

# ── Phase 1: critic pairing by branch ────────────────────────────────
assert_json "critic: pairs producer and critic on one branch" "$FJ" \
  '(d["counts"]["critic_pairs"] == 1
    and d["critic_pairs"][0]["branch"] == "feat/widget-x-alpha"
    and d["critic_pairs"][0]["producers"] == ["1-fixture-builder-widget-x"]
    and d["critic_pairs"][0]["critics"] == ["6-fixture-critic-1"])'
assert_json "critic: pairing recorded on both trails"    "$FJ" \
  '(T["1-fixture-builder-widget-x"]["reviewed_by"] == ["6-fixture-critic-1"]
    and T["6-fixture-critic-1"]["reviews"] == ["1-fixture-builder-widget-x"])'
assert_json "critic: unpaired critic stays unpaired"     "$FJ" \
  'T["6-fixture-critic-2"]["reviews"] == [] and T["6-fixture-critic-2"]["is_critic"] is True'
assert_json "critic: every trail carries pairing fields" "$FJ" \
  'all({"is_critic","reviewed_by","reviews"} <= set(t) for t in d["trails"])'
assert_json "critic: rate is branch pairing, not name-contains" "$FJ" \
  '(d["fleet"]["critic_rate_method"] == "branch_pairing"
    and d["fleet"]["critic_rate"] == round(1 / d["fleet"]["critic_rate_basis"]["producer_trails"], 4))'
assert_json "critic: rate basis published with its n"    "$FJ" \
  '{"pairs","producer_trails","paired_producer_trails","critic_trails","unpaired_critic_trails"} <= set(d["fleet"]["critic_rate_basis"])'
assert_json "critic: role_stats expose review counts"    "$FJ" \
  '(R["fixture-builder"]["n_reviewed"] == 1 and R["fixture-critic"]["n_reviews_given"] == 1
    and R["fixture-veteran"]["n_reviewed"] == 0)'

# ── Phase 1: gh enrichment (optional, never fatal) ───────────────────
assert_json "gh: fields exist on every trail even when off" "$FJ" \
  'all({"pr_url","pr_state","pr_number","issue_links_resolved"} <= set(t) for t in d["trails"])'
assert_json "gh: --no-gh is reported honestly"           "$FJ" \
  'd["gh_enrichment"]["status"] == "disabled" and d["gh_enrichment"]["trails_with_pr"] == 0'
assert_json "gh: no PR/issue values invented when off"   "$FJ" \
  'all(t["pr_url"] == "" and t["pr_state"] == "" and t["pr_number"] is None and t["issue_links_resolved"] == [] for t in d["trails"])'

# ── redaction / no secrets ───────────────────────────────────────────
assert_json "redaction: token-shaped strings replaced" "$FJ" \
  '"[redacted" in T["3-fixture-builder-secrets"]["handoff_markdown"] and "FIXTURE" not in T["3-fixture-builder-secrets"]["handoff_markdown"]'
assert_absent "no secret-shaped tokens in fixture JSON+HTML" "$FIXOUT" "$SECRET_SHAPES"
assert_absent "no operator home paths in fixture JSON+HTML"  "$FIXOUT" "$HOME_PATHS"

# ── agent transcripts (SYNTHESIS: "Still reject … transcript dumps") ──
# These assertions are only worth anything if the fixtures actually carry
# agent-log paths and a transcript body on disk. Guard that first — an empty
# `log` field made every check below silently vacuous before.
LOG_MARKER='FIXTURE_TRANSCRIPT_BODY_MUST_NOT_BE_INGESTED'
FIXTURE_LOG="$FIX/logs/dev-agents-feat-secrets-20260101-101112.log"
exists "fixture plants a real agent transcript on disk" "$FIXTURE_LOG"
grep -q "$LOG_MARKER" "$FIXTURE_LOG" 2>/dev/null \
  && ok "fixture transcript carries the marker (not vacuous)" \
  || bad "fixture transcript carries the marker (not vacuous)"
grep -REq "$SECRET_SHAPES" "$FIXTURE_LOG" 2>/dev/null \
  && ok "fixture transcript carries secret shapes (not vacuous)" \
  || bad "fixture transcript carries secret shapes (not vacuous)"
if grep -REl "$HOME_PATHS" "$FIX" >/dev/null 2>&1; then
  ok "fixture input carries operator home paths (not vacuous)"
else
  bad "fixture input carries operator home paths (not vacuous)"
fi
assert_json "fixtures supply absolute agent-log paths (not vacuous)" "$FJ" \
  'sum(1 for t in d["trails"] if t["source"]["log_name"]) >= 4'

# The contract: filename only, as a join hint. Directory, operator home and
# transcript body must never cross into the projection.
assert_json "agent log kept as filename only, directories stripped" "$FJ" \
  '(T["3-fixture-builder-secrets"]["source"]["log_name"] == "dev-agents-feat-secrets-20260101-101112.log"
    and all("/" not in t["source"]["log_name"] for t in d["trails"]))'
assert_absent "no agent transcript bodies in fixture JSON+HTML" "$FIXOUT" "$LOG_MARKER|FIXTURELOG"
assert_absent "no agent-log directory dumps in fixture JSON+HTML" "$FIXOUT" 'agent-logs/|dev/agent-logs'

# ── HTML projection ──────────────────────────────────────────────────
for page in index work/index roles/index skills/index learnings/index conductor/index about/index \
            company/acme/index company/acme/work/index trail/1-fixture-builder-widget-x/index \
            role/fixture-builder/index skill/fixture-pack/index learning/lesson-one/index; do
  exists "fixture page $page.html" "$FIXOUT/$page.html"
done
grep -q "Wave 5" "$FIXOUT/work/index.html" && ok "work groups by wave" || bad "work groups by wave"
grep -q "Unlinked / no wave" "$FIXOUT/work/index.html" && ok "work shows no-wave group" || bad "work shows no-wave group"
grep -q "config_map" "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" && ok "trail shows join method" || bad "trail shows join method"
grep -q "data/index.json" "$FIXOUT/index.html" && ok "pages link the data contract" || bad "pages link the data contract"
grep -q "No handoffs joined to ghostco" "$FIXOUT/company/ghostco/index.html" && ok "empty company state teaches" || bad "empty company state teaches"

# ── Wave 2 UI craft (fixture) ─────────────────────────────────────────
exists "fixture stylesheet assets/site.css"   "$FIXOUT/assets/site.css"
exists "fixture flat work page"               "$FIXOUT/work/flat/index.html"
exists "fixture company flat work page"       "$FIXOUT/company/acme/work/flat/index.html"
grep -q 'rel="stylesheet" href="assets/site.css"' "$FIXOUT/index.html" \
  && ok "pages link the external stylesheet" || bad "pages link the external stylesheet"
grep -q "prefers-color-scheme" "$FIXOUT/assets/site.css" \
  && ok "stylesheet honors prefers-color-scheme" || bad "stylesheet honors prefers-color-scheme"
assert_absent_html "no inline <style> blocks in fixture HTML"  "$FIXOUT" '<style'
assert_absent_html "no inline style= attributes in fixture HTML" "$FIXOUT" '[[:space:]]style='
grep -q 'class="seg"' "$FIXOUT/work/index.html" && ok "work has group-by segmented control" || bad "work has group-by segmented control"
grep -q 'aria-current="true"' "$FIXOUT/work/flat/index.html" && ok "flat view marks current segment" || bad "flat view marks current segment"
grep -q 'class="st st-done">done' "$FIXOUT/work/index.html" \
  && ok "status is text AND color (pill carries the word)" || bad "status is text AND color (pill carries the word)"
grep -q 'class="skip"' "$FIXOUT/index.html" && ok "skip link present (a11y)" || bad "skip link present (a11y)"
grep -q 'aria-current="page"' "$FIXOUT/index.html" && ok "nav marks current page (a11y)" || bad "nav marks current page (a11y)"
grep -q 'aria-current="true"' "$FIXOUT/company/acme/index.html" && ok "scope chip marks active company" || bad "scope chip marks active company"
grep -q 'class="crumb"' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" && ok "trail has breadcrumb" || bad "trail has breadcrumb"
grep -q 'Base → head' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" && ok "trail shows base→head SHAs" || bad "trail shows base→head SHAs"
grep -q 'Raw handoff record (audit, redacted)' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" \
  && ok "trail has raw-record disclosure" || bad "trail has raw-record disclosure"
grep -q 'make experience' "$FIXOUT/company/ghostco/index.html" && ok "empty company teaches make experience" || bad "empty company teaches make experience"
grep -q 'class="pmi band-p2">P2' "$FIXOUT/role/fixture-veteran/index.html" && ok "PMI band rendered as badge" || bad "PMI band rendered as badge"
grep -q 'PMI inputs' "$FIXOUT/role/fixture-builder/index.html" && ok "PMI disclosure present" || bad "PMI disclosure present"
grep -q 'class="chip dim"' "$FIXOUT/index.html" \
  && grep -q 'chipmark">placeholder' "$FIXOUT/index.html" \
  && ok "dim chip marks placeholder status as visible text" || bad "dim chip marks placeholder status as visible text"
assert_links_resolve "fixture: every relative href resolves (BROKEN: 0)" "$FIXOUT"

# ── Phase 1 UI bind (fixture) ───────────────────────────────────────
grep -q '<dt>Reviewed by</dt>' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" \
  && grep -q 'trail/6-fixture-critic-1/index.html' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html" \
  && ok "trail detail links its critic (reviewed_by)" || bad "trail detail links its critic (reviewed_by)"
grep -q '<dt>Reviews</dt>' "$FIXOUT/trail/6-fixture-critic-1/index.html" \
  && grep -q 'trail/1-fixture-builder-widget-x/index.html' "$FIXOUT/trail/6-fixture-critic-1/index.html" \
  && ok "critic trail links the producer it reviewed" || bad "critic trail links the producer it reviewed"
if grep -q '<dt>Reviewed by</dt>' "$FIXOUT/trail/3-fixture-builder-plain/index.html"; then
  bad "unpaired trail invents no review row"
else
  ok "unpaired trail invents no review row"
fi
grep -q 'Proven loop evidence (P3 gate)' "$FIXOUT/role/fixture-builder/index.html" \
  && grep -q 'fixture-pack promotes lesson-one' "$FIXOUT/role/fixture-builder/index.html" \
  && ok "P3 role shows its proven-loop evidence" || bad "P3 role shows its proven-loop evidence"
grep -q 'Proven loop evidence: none recorded' "$FIXOUT/role/fixture-veteran/index.html" \
  && ok "P2 role states honestly why P3 is not met" || bad "P2 role states honestly why P3 is not met"
# C1: a sub-P3 role carrying evidence must not read as if the P3 gate passed
grep -q 'class="pmi band-p1">P1' "$FIXOUT/role/fixture-runner/index.html" \
  && ok "precondition: fixture-runner is P1" || bad "precondition: fixture-runner is P1"
grep -q 'Proven loop evidence (P3 gate)' "$FIXOUT/role/fixture-runner/index.html" \
  && ok "precondition: P1 role renders the P3-gate evidence list" \
  || bad "precondition: P1 role renders the P3-gate evidence list"
grep -q 'P3 gate is not met\|does not meet the P3 gate\|not met' \
     "$FIXOUT/role/fixture-runner/index.html" \
  && ok "P1 role with evidence states the P3 gate is still unmet" \
  || bad "P1 role with evidence states the P3 gate is still unmet"
grep -q '<h2>Git history</h2>' "$FIXOUT/skill/fixture-pack/index.html" \
  && grep -q 'First → last commit' "$FIXOUT/skill/fixture-pack/index.html" \
  && ok "skill detail shows git history + first/last commit" || bad "skill detail shows git history + first/last commit"
grep -q 'critic pairs' "$FIXOUT/index.html" && ok "home stat strip shows critic pairs" || bad "home stat strip shows critic pairs"
grep -q 'branch_pairing' "$FIXOUT/about/index.html" && ok "about declares the critic rate method" || bad "about declares the critic rate method"
grep -q 'gh enrichment: <span class="mono">disabled' "$FIXOUT/about/index.html" \
  && ok "about reports gh enrichment status honestly (--no-gh)" || bad "about reports gh enrichment status honestly (--no-gh)"
if grep -q '<dt>PR</dt>' "$FIXOUT/trail/1-fixture-builder-widget-x/index.html"; then
  bad "no PR row invented when gh enrichment is off"
else
  ok "no PR row invented when gh enrichment is off"
fi

# HTML must refuse a data contract it does not understand
python3 - "$FJ" "$TMP/bad.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["schema_version"] = 999
json.dump(d, open(sys.argv[2], "w"))
PY
if python3 "$REPO_DIR/scripts/experience_build.py" --repo "$FIX" --out "$TMP/badsite" --data "$TMP/bad.json" >/dev/null 2>&1; then
  bad "renderer rejects unknown schema_version"
else
  ok "renderer rejects unknown schema_version"
fi

echo ""
echo "== A2. Phase 1 enrichment against real git (throwaway repos) =="

# A2.1 — projection of a tree with NO git: history must degrade honestly, and
# the promotion path to P3 must still work (it reads files, not git).
NOGIT="$TMP/nogit-repo"
cp -R "$FIX" "$NOGIT"
if git -C "$NOGIT" rev-parse --show-toplevel >/dev/null 2>&1; then
  bad "no-git case is genuinely outside a work tree (not vacuous)"
else
  ok "no-git case is genuinely outside a work tree (not vacuous)"
fi
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$NOGIT" --out "$TMP/nogit-site" --no-gh >"$TMP/nogit.log" 2>&1 \
  && ok "build succeeds without git" || bad "build succeeds without git"
NJ="$TMP/nogit-site/data/index.json"
assert_json "no git: history marked unavailable, not faked" "$NJ" \
  '(d["skill_history"]["available"] is False
    and all(s["git_history"] == [] and s["revisions"] == 0 and s["history_available"] is False for s in d["skills"]))'
assert_json "no git: warning explains the gap"              "$NJ" 'any("skill version history" in w for w in d["warnings"])'
assert_json "no git: cap reason says only promotion was evaluable" "$NJ" \
  '"git history unavailable" in d["pmi_policy"]["cap_reason"] and d["pmi_policy"]["history_available"] is False'
assert_json "no git: P3 still reachable through promotion"  "$NJ" 'R["fixture-builder"]["pmi"]["band"] == "P3"'
# …but the promotion path must still exclude default packs, with git out of the
# picture entirely (promotion reads files, so this is the git-free half of B1).
assert_json "no git: default pack promotion still grants no P3" "$NJ" \
  '(S["evidence-first"]["promotes"] == ["lesson-default"]
    and R["fixture-veteran"]["pmi"]["band"] == "P2"
    and R["fixture-veteran"]["pmi"]["inputs"]["proven_loop_evidence"] == [])'
python3 "$REPO_DIR/scripts/experience_build.py" --repo "$NOGIT" --out "$TMP/nogit-site" >"$TMP/nogit-html.log" 2>&1 \
  && ok "renderer succeeds without git" || bad "renderer succeeds without git"
grep -q 'git history unavailable' "$TMP/nogit-site/skill/fixture-pack/index.html" \
  && ok "no git: skill detail says history unavailable, not zero" || bad "no git: skill detail says history unavailable, not zero"
if grep -q '<h2>Git history</h2>' "$TMP/nogit-site/skill/fixture-pack/index.html"; then
  bad "no git: no history card invented"
else
  ok "no git: no history card invented"
fi

# A2.2 — real commits: the version-history path to P3 is proven with actual
# `git log` output, never a hand-written fixture of fake commits.
GITREPO="$TMP/git-repo"
cp -R "$FIX" "$GITREPO"
(
  cd "$GITREPO"
  git init -q .
  git config user.email fixture@example.invalid
  git config user.name "Fixture Operator"
  git add -A
  git commit -qm "seed fixture repo"
  printf '\n- [ ] Second revision of the fixture pack.\n' >>skills/fixture-pack/SKILL.md
  git add skills/fixture-pack/SKILL.md
  git commit -qm "skills: revise fixture pack to v2"
  # A shared DEFAULT pack that also clears the version path (v2 + 2 commits).
  # Deliberately over-qualified: it must still grant nobody P3.
  printf '\n- [ ] Second revision of the default pack.\n' >>skills/evidence-first/SKILL.md
  git add skills/evidence-first/SKILL.md
  git commit -qm "skills: revise default pack"
  # A pack with MORE commits than the published depth, so the cap is measurable
  # rather than merely declared. Assigned to no role, so it cannot move a band.
  mkdir -p skills/fixture-deep-pack
  printf -- '---\nid: fixture-deep-pack\nversion: 2\nscope: project\nsummary: Depth-cap fixture.\n---\n\n# Fixture deep pack\n' \
    >skills/fixture-deep-pack/SKILL.md
  git add skills/fixture-deep-pack/SKILL.md
  git commit -qm "skills: add deep pack"
  i=2
  while [ "$i" -le 23 ]; do
    printf -- '- [ ] revision %s\n' "$i" >>skills/fixture-deep-pack/SKILL.md
    git add skills/fixture-deep-pack/SKILL.md
    git commit -qm "skills: deep pack revision $i"
    i=$((i+1))
  done
) >"$TMP/gitrepo-init.log" 2>&1 \
  && ok "throwaway git repo seeded with real commits on SKILL.md files" \
  || bad "throwaway git repo seeded with real commits on SKILL.md files"
DEEP_COMMITS=$(git -C "$GITREPO" log --oneline -- skills/fixture-deep-pack/SKILL.md | wc -l | tr -d ' ')
if [ "$DEEP_COMMITS" -gt 20 ]; then
  ok "deep pack really has more commits than the depth cap ($DEEP_COMMITS > 20)"
else
  bad "deep pack really has more commits than the depth cap (got $DEEP_COMMITS)"
fi
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$GITREPO" --out "$TMP/gitrepo-site" --no-gh >"$TMP/gitrepo.log" 2>&1 \
  && ok "build succeeds with git history" || bad "build succeeds with git history"
GJ="$TMP/gitrepo-site/data/index.json"
assert_json "git: history available and counted"        "$GJ" \
  '(d["skill_history"]["available"] is True
    and [s for s in d["skills"] if s["id"] == "fixture-pack"][0]["revisions"] == 2)'
assert_json "git: newest commit first, subject recorded" "$GJ" \
  '[s for s in d["skills"] if s["id"] == "fixture-pack"][0]["git_history"][0]["subject"] == "skills: revise fixture pack to v2"'
assert_json "git: first/last commit dates published"    "$GJ" \
  '[s for s in d["skills"] if s["id"] == "fixture-pack"][0]["last_commit"] >= [s for s in d["skills"] if s["id"] == "fixture-pack"][0]["first_commit"] != ""'
assert_json "git: P3 evidence cites the revision count"  "$GJ" \
  'any("recorded revisions" in e for e in R["fixture-builder"]["pmi"]["inputs"]["proven_loop_evidence"])'
# B1, version path with real commits: the default pack now clears BOTH proofs
# (v2 with 2 recorded revisions, and a promotion) and must still grant no P3.
assert_json "git: over-qualified default pack still grants no P3" "$GJ" \
  '(S["evidence-first"]["version"] >= 2 and S["evidence-first"]["revisions"] == 2
    and S["evidence-first"]["promotes"] == ["lesson-default"]
    and R["fixture-veteran"]["pmi"]["band"] == "P2"
    and R["fixture-veteran"]["pmi"]["inputs"]["proven_loop_evidence"] == []
    and all("evidence-first" not in e for s in R.values() for e in s["pmi"]["inputs"]["proven_loop_evidence"]))'
# B3 with a deterministic revision count: exactly 1 commit, so "born at v2" is
# isolated from "actually revised" without depending on this repo's own history.
assert_json "git: v2 pack with exactly 1 commit is not a proven loop" "$GJ" \
  '(S["fixture-solo-pack"]["version"] == 2 and S["fixture-solo-pack"]["revisions"] == 1
    and S["fixture-solo-pack"]["promotes"] == []
    and R["fixture-solo"]["pmi"]["band"] == "P2"
    and R["fixture-solo"]["pmi"]["inputs"]["proven_loop_evidence"] == [])'
# B4: the cap is enforced, not just declared. 23 commits exist (asserted above
# from git itself); the projection must publish exactly `history_depth` of them.
assert_json "git: history is truncated AT the published depth" "$GJ" \
  '(S["fixture-deep-pack"]["history_depth"] == 20
    and len(S["fixture-deep-pack"]["git_history"]) == 20
    and S["fixture-deep-pack"]["revisions"] == 20
    and S["fixture-deep-pack"]["history_truncated"] is True)'
assert_json "git: an untruncated pack is not falsely flagged" "$GJ" \
  '(S["fixture-pack"]["history_truncated"] is False
    and len(S["fixture-pack"]["git_history"]) < S["fixture-pack"]["history_depth"])'
python3 "$REPO_DIR/scripts/experience_build.py" --repo "$GITREPO" --out "$TMP/gitrepo-site" >"$TMP/gitrepo-html.log" 2>&1 \
  && ok "renderer succeeds on the git-history projection" || bad "renderer succeeds on the git-history projection"
grep -q 'skills: revise fixture pack to v2' "$TMP/gitrepo-site/skill/fixture-pack/index.html" \
  && ok "skill detail lists real commit subjects" || bad "skill detail lists real commit subjects"
grep -q 'Revisions</dt><dd class="mono">2' "$TMP/gitrepo-site/skill/fixture-pack/index.html" \
  && ok "skill detail shows the real revision count" || bad "skill detail shows the real revision count"
grep -q '(newest 20 shown)' "$TMP/gitrepo-site/skill/fixture-deep-pack/index.html" \
  && ok "truncated history says so on the page" || bad "truncated history says so on the page"
assert_absent "no secret shapes in git-repo projection"  "$TMP/gitrepo-site" "$SECRET_SHAPES"

# A2.3 — env kill switch must work the same as the flag
FLEET_DESK_NO_GH=1 python3 "$REPO_DIR/scripts/experience_data.py" --repo "$FIX" --out "$TMP/envoff" >"$TMP/envoff.log" 2>&1 \
  && ok "FLEET_DESK_NO_GH=1 build succeeds" || bad "FLEET_DESK_NO_GH=1 build succeeds"
assert_json "gh: env kill switch reported"  "$TMP/envoff/data/index.json" 'd["gh_enrichment"]["status"] == "disabled"'

# A2.3b — gh mapping is unit-tested offline: no network, no invented links.
if python3 - "$REPO_DIR" <<'PY'
import sys
from pathlib import Path
repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
import experience_data as ed

index = {
    "repo": "acme/widget",
    "pr_by_branch": {
        "feat/x": {
            "number": 7, "url": "https://github.com/acme/widget/pull/7",
            "state": "MERGED", "title": "a title", "updated_at": "2026-01-01T00:00:00Z",
        }
    },
    "issue_by_number": {
        "12": {"number": 12, "url": "https://github.com/acme/widget/issues/12",
               "state": "OPEN", "title": "an issue", "kind": "issue"},
    },
}
trails = [
    {"branch": "feat/x", "issue_links": ["#12", "https://github.com/other/repo/issues/12"]},
    {"branch": "feat/elsewhere", "issue_links": ["#12"]},
]
ed.apply_gh(trails, index)
assert trails[0]["pr_number"] == 7 and trails[0]["pr_state"] == "MERGED"
assert trails[0]["pr_url"].endswith("/pull/7")
assert [x["number"] for x in trails[0]["issue_links_resolved"]] == [12], "foreign-repo URL must not resolve"
# a trail that is not this repo's work keeps its bare #ref unresolved
assert trails[1]["pr_url"] == "" and trails[1]["pr_number"] is None
assert trails[1]["issue_links_resolved"] == []
# non-root projection never calls gh at all
out = ed.gh_index(repo / "tests" / "fixtures" / "experience-mini", repo, True)
assert out["status"] == "skipped" and "work-tree root" in out["reason"], out
# PR/issue titles go through the same redactor before they enter the JSON
red = ed.redact("ghp_" + "A" * 24)
assert "ghp_" not in red and "redacted" in red, red
PY
then ok "gh: mapping resolves only this repo's PR/issues (offline unit)"; else bad "gh: mapping resolves only this repo's PR/issues (offline unit)"; fi

# A2.3c — gh-enriched fields render on trail detail: inject them into the
# fixture contract (offline, no network) and check the HTML projection.
python3 - "$FJ" "$TMP/gh.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["trails"]:
    if t["task_id"] == "1-fixture-builder-widget-x":
        t["pr_url"] = "https://github.com/acme/widget/pull/7"
        t["pr_state"] = "MERGED"
        t["pr_number"] = 7
        t["issue_links"] = ["#12", "https://github.com/other/product/issues/9", "#77"]
        t["issue_links_resolved"] = [
            {"ref": "#12", "number": 12, "url": "https://github.com/acme/widget/issues/12",
             "state": "OPEN", "title": "an issue", "kind": "issue"}
        ]
json.dump(d, open(sys.argv[2], "w"))
PY
python3 "$REPO_DIR/scripts/experience_build.py" --repo "$FIX" --out "$TMP/ghsite" --data "$TMP/gh.json" >"$TMP/gh-html.log" 2>&1 \
  && ok "renderer succeeds with gh-enriched fields" || bad "renderer succeeds with gh-enriched fields"
GHT="$TMP/ghsite/trail/1-fixture-builder-widget-x/index.html"
grep -q 'href="https://github.com/acme/widget/pull/7"' "$GHT" \
  && grep -q 'pill">merged' "$GHT" \
  && ok "trail detail renders PR link + state when present" || bad "trail detail renders PR link + state when present"
grep -q 'href="https://github.com/acme/widget/issues/12"' "$GHT" \
  && grep -q '(open · an issue)' "$GHT" \
  && ok "trail detail renders resolved issue title + state" || bad "trail detail renders resolved issue title + state"
# C2: partial gh resolution must not drop the refs that stayed unresolved
for ref in '#12' 'other/product/issues/9' '#77'; do
  grep -qF "$ref" "$GHT" \
    && ok "Links row still shows cited ref $ref" || bad "Links row still shows cited ref $ref"
done
if grep -q '<dt>PR</dt>' "$TMP/ghsite/trail/2-fixture-builder-gadget/index.html"; then
  bad "trail without a PR keeps the PR row absent"
else
  ok "trail without a PR keeps the PR row absent"
fi

# A2.3d — gh non-JSON honesty: a fake `gh` on PATH that exits 0 but prints
# garbage must yield status bad_payload with a clear reason — never status ok
# with garbage in gh_enrichment. Still never fatal, still offline.
if python3 - "$REPO_DIR" "$GITREPO" "$TMP" <<'PY'
import os, stat, sys
from pathlib import Path

repo_dir, gitrepo, tmp = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(repo_dir / "scripts"))
import experience_data as ed

toplevel = ed.git_toplevel(gitrepo)
assert toplevel is not None and toplevel.resolve() == gitrepo.resolve(), "fixture git repo must be a work-tree root"

def fake_gh(name, repo_view="", pr_list="", issue_list=""):
    d = tmp / f"fakegh-{name}"
    d.mkdir(exist_ok=True)
    script = d / "gh"
    script.write_text(
        "#!/bin/sh\n"
        "case \"$1 $2\" in\n"
        "  'auth status') exit 0;;\n"
        f"  'repo view') printf '%s\\n' '{repo_view}';;\n"
        f"  'pr list') printf '%s\\n' '{pr_list}';;\n"
        f"  'issue list') printf '%s\\n' '{issue_list}';;\n"
        "esac\n"
        "exit 0\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    os.environ["PATH"] = f"{d}{os.pathsep}{os.environ['PATH']}"
    return ed.gh_index(gitrepo, toplevel, True)

# exit 0 + non-slug repo payload -> bad_payload, repo stays empty
r = fake_gh("badslug", repo_view="not json")
assert r["status"] == "bad_payload" and "repo view" in r["reason"] and r["repo"] == "", r

# valid slug, exit 0 + non-JSON pr list -> bad_payload, honest reason, repo kept
r = fake_gh("badpr", repo_view="acme/widget", pr_list="not json")
assert r["status"] == "bad_payload" and "pr list" in r["reason"] and r["repo"] == "acme/widget", r
assert r["pr_by_branch"] == {} and r["issue_by_number"] == {}, r

# valid pr list, exit 0 + non-JSON issue list -> bad_payload (ok would silently
# drop every issue)
r = fake_gh("badissue", repo_view="acme/widget", pr_list="[]", issue_list="not json")
assert r["status"] == "bad_payload" and "issue list" in r["reason"], r

# JSON that is valid but not an array is also bad_payload
r = fake_gh("notlist", repo_view="acme/widget", pr_list="{}")
assert r["status"] == "bad_payload" and "pr list" in r["reason"], r

# happy path through the same harness — proves the fake-gh rig is not vacuous
PRS = '[{"number":7,"url":"https://github.com/acme/widget/pull/7","state":"OPEN","headRefName":"feat/x","title":"t","updatedAt":"2026-01-01T00:00:00Z"}]'
r = fake_gh("happy", repo_view="acme/widget", pr_list=PRS, issue_list="[]")
assert r["status"] == "ok" and r["repo"] == "acme/widget" and r["prs_indexed"] == 1, r
PY
then ok "gh: exit-0 garbage is bad_payload, never ok (fake gh on PATH)"; else bad "gh: exit-0 garbage is bad_payload, never ok (fake gh on PATH)"; fi


# A2.4 — optional snapshot: redacted rollup, no bodies, small enough to commit
SNAP="$TMP/snapshot"
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$FIX" --out "$TMP/snapsite" --no-gh --snapshot-dir "$SNAP" \
  >"$TMP/snap.log" 2>&1 && ok "snapshot build succeeds" || bad "snapshot build succeeds"
exists "snapshot summary.json"  "$SNAP/summary.json"
exists "snapshot README.md"     "$SNAP/README.md"
if python3 - "$SNAP/summary.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if (
    d["counts"]["trails"] == 32
    and d["schema_version"] == 2
    and d["roles"]["fixture-builder"]["pmi_band"] == "P3"
    and len(d["critic_pairs"]) == 1
    and all({"task_id", "status", "handoff_summary"} <= set(t) for t in d["trails"])
) else 1)
PY
then ok "snapshot: keeps the rollup numbers"; else bad "snapshot: keeps the rollup numbers"; fi
if python3 - "$SNAP/summary.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
banned = ("handoff_markdown", "handoff_sections", '"body"', "body_truncated", "git_history")
sys.exit(1 if any(b in raw for b in banned) else 0)
PY
then ok "snapshot: drops every free-text body"; else bad "snapshot: drops every free-text body"; fi
assert_absent "no secret shapes in snapshot"      "$SNAP" "$SECRET_SHAPES"
assert_absent "no operator home paths in snapshot" "$SNAP" "$HOME_PATHS"
SNAP_KB=$(( $(wc -c <"$SNAP/summary.json") / 1024 ))
if [ "$SNAP_KB" -lt 512 ]; then ok "snapshot stays small (${SNAP_KB} KiB < 512 KiB)"; else bad "snapshot stays small (${SNAP_KB} KiB)"; fi

echo ""
echo "== B. real repo smoke =="
cd "$REPO_DIR"
./scripts/experience-build.sh >"$TMP/build.log" 2>&1 && ok "scripts/experience-build.sh (JSON then HTML)" || bad "scripts/experience-build.sh (JSON then HTML)"
SITE="$REPO_DIR/site/experience"
RJ="$SITE/data/index.json"
exists "data/index.json"       "$RJ"
exists "index.html"            "$SITE/index.html"
exists "work/index.html"       "$SITE/work/index.html"
exists "about/index.html"      "$SITE/about/index.html"
exists "roles/index.html"      "$SITE/roles/index.html"
exists "skills/index.html"     "$SITE/skills/index.html"
exists "learnings/index.html"  "$SITE/learnings/index.html"
exists "conductor/index.html"  "$SITE/conductor/index.html"
exists "assets/site.css"       "$SITE/assets/site.css"
exists "work/flat/index.html"  "$SITE/work/flat/index.html"

grep -q "Fleet Desk" "$SITE/index.html" && ok "brand present" || bad "brand present"
grep -qi "make experience" "$SITE/about/index.html" && ok "about refresh hint" || bad "about refresh hint"
grep -q "group by wave\|Wave " "$SITE/work/index.html" && ok "work has wave grouping" || bad "work has wave grouping"
grep -q "Playbook Maturity\|PMI" "$SITE/roles/index.html" && ok "roles PMI" || bad "roles PMI"
grep -q 'rel="stylesheet"' "$SITE/index.html" && ok "site links external stylesheet" || bad "site links external stylesheet"
grep -q 'class="seg"' "$SITE/work/index.html" && ok "site work has group toggle" || bad "site work has group toggle"
assert_absent_html "no inline styles in site HTML" "$SITE" '[[:space:]]style=|<style'
assert_links_resolve "site: every relative href resolves (BROKEN: 0)" "$SITE"

# Phase 1 UI bind on the real projection
grep -q 'critic pairs' "$SITE/index.html" && ok "site home shows critic pairs" || bad "site home shows critic pairs"
grep -q 'Critic pairing' "$SITE/about/index.html" && ok "site about has critic pairing section" || bad "site about has critic pairing section"
grep -q 'gh enrichment:' "$SITE/about/index.html" && ok "site about reports gh status" || bad "site about reports gh status"
grep -qE '· [0-9]+ rev' "$SITE/skills/index.html" && ok "site skills index shows revision counts" || bad "site skills index shows revision counts"
grep -q '<h2>Git history</h2>' "$SITE/skill/git-ship/index.html" \
  && ok "site skill detail shows git history" || bad "site skill detail shows git history"
if grep -rlq '<dt>Reviewed by</dt>' "$SITE/trail" 2>/dev/null; then
  ok "site trail details show review pairing"
else
  bad "site trail details show review pairing"
fi

assert_json "real data parses with pinned schema" "$RJ" 'd["schema_version"] == 2 and isinstance(d["trails"], list)'
assert_json "real trails carry contract fields"   "$RJ" \
  'all({"task_id","agent","wave","status","branch","provenance","join_method","project_label","conductor","ts","base_sha","head_sha","handoff_sections","is_critic","reviewed_by","reviews","pr_url","pr_state","issue_links_resolved"} <= set(t) for t in d["trails"])'
assert_json "real joins never invent companies"   "$RJ" 'all(t["company_id"] is None or t["company_id"] in C for t in d["trails"])'
assert_json "real PMI capped at P3"               "$RJ" 'all(s["pmi"]["band"] in ("P0","P1","P2","P3") for s in R.values())'
assert_json "real skill history collected"        "$RJ" \
  '(d["skill_history"]["available"] is True and d["skill_history"]["skills_with_history"] >= 1
    and all(len(s["git_history"]) <= 20 for s in d["skills"]))'
assert_json "real critic rate declares its method" "$RJ" \
  'd["fleet"]["critic_rate_method"] in ("branch_pairing", "role_name_fallback") and "critic_rate_basis" in d["fleet"]'
# gh may be missing, logged out or offline on any machine — the only contract is
# that the build survived and said what happened.
assert_json "real gh enrichment never fails the build" "$RJ" \
  '(d["gh_enrichment"]["status"] in ("ok","skipped","disabled","unavailable","unauthenticated","error","bad_payload")
    and (d["gh_enrichment"]["status"] == "ok" or d["gh_enrichment"]["reason"]))'
assert_json "real gh PR fields stay consistent"   "$RJ" \
  'all((t["pr_url"] and t["pr_state"]) or (not t["pr_url"] and t["pr_number"] is None) for t in d["trails"])'
assert_json "real gh never stores issue bodies"   "$RJ" \
  'all(set(x) <= {"ref","number","url","state","title","kind","updated_at"} for t in d["trails"] for x in t["issue_links_resolved"])'
assert_absent "no secret-shaped tokens in site"   "$SITE" "$SECRET_SHAPES"
assert_absent "no operator home paths in site"    "$SITE" "$HOME_PATHS"

if compgen -G "$SITE/trail/*/index.html" >/dev/null; then
  ok "trail pages generated"
else
  ok "trail pages (none — empty fleet ok)"
fi

for target in experience experience-open desk experience-snapshot; do
  make -n "$target" >/dev/null 2>&1 && ok "make $target resolves" || bad "make $target resolves"
done

echo ""
echo "== C. make experience-data must not wipe the rendered site =="
# Regression: experience_data.py used to rmtree the whole out dir, so a data
# refresh deleted every HTML page built moments earlier.
make experience >"$TMP/mk-exp.log" 2>&1 && ok "make experience" || bad "make experience"
exists "HTML index built"        "$SITE/index.html"
exists "trail-level page built"  "$SITE/work/index.html"
# Stamp the JSON so a genuine refresh is provable, and mark HTML we expect to survive.
python3 -c "import json,sys;p=sys.argv[1];d=json.load(open(p));d['generated_at']='STALE-STAMP';json.dump(d,open(p,'w'))" "$RJ"
sleep 1
make experience-data >"$TMP/mk-data.log" 2>&1 && ok "make experience-data" || bad "make experience-data"

exists "index.html survives experience-data"      "$SITE/index.html"
exists "work/index.html survives experience-data" "$SITE/work/index.html"
exists "about/index.html survives experience-data" "$SITE/about/index.html"
exists "data/index.json still present"            "$RJ"
assert_json "data/index.json refreshed (stale stamp gone)" "$RJ" \
  'd["generated_at"] != "STALE-STAMP" and d["schema_version"] == 2'
if compgen -G "$SITE/*/index.html" >/dev/null; then
  ok "sub-page tree survives experience-data"
else
  bad "sub-page tree survives experience-data"
fi

# The renderer, not the data step, owns stale-page cleanup.
mkdir -p "$SITE/trail/zz-ghost-trail"
echo "<html>stale</html>" >"$SITE/trail/zz-ghost-trail/index.html"
make experience-data >>"$TMP/mk-data.log" 2>&1
[ -f "$SITE/trail/zz-ghost-trail/index.html" ] \
  && ok "experience-data leaves unrelated HTML alone" \
  || bad "experience-data leaves unrelated HTML alone"
make experience >>"$TMP/mk-exp.log" 2>&1
[ -e "$SITE/trail/zz-ghost-trail" ] \
  && bad "make experience prunes stale rendered pages" \
  || ok "make experience prunes stale rendered pages"
exists "data/index.json survives HTML clean" "$RJ"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
