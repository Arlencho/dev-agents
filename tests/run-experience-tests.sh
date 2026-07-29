#!/usr/bin/env bash
# Fleet Desk tests — data contract (JSON) first, HTML projection second.
#
#   Part A: deterministic fixture repo (tests/fixtures/experience-mini)
#           joins · wave field · PMI bands + Phase 0 cap · redaction
#   Part B: smoke build of this real repo through scripts/experience-build.sh
#
# Law: docs/proposals/experience-console-SYNTHESIS.md
# Schema: docs/experience-data.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/experience-mini"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# assert_json <name> <json file> <python expression over d/T/R/C/W>
assert_json() {
  local name="$1" file="$2" expr="$3"
  if python3 - "$file" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
T = {t["task_id"]: t for t in d["trails"]}
R = d["role_stats"]
C = {c["id"]: c for c in d["companies"]}
W = {(str(w["wave"]) if w["wave"] is not None else "none"): w for w in d["waves"]}
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

SECRET_SHAPES='gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|(api[_-]?key|password|secret|token)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]{16,}'
HOME_PATHS='/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/'

echo "== A. fixture repo (deterministic) =="
FIXOUT="$TMP/fixture-site"
python3 "$REPO_DIR/scripts/experience_data.py" --repo "$FIX" --out "$FIXOUT" >"$TMP/data.log" 2>&1 \
  && ok "experience_data.py builds fixture" || bad "experience_data.py builds fixture"
python3 "$REPO_DIR/scripts/experience_build.py" --repo "$FIX" --out "$FIXOUT" >"$TMP/html.log" 2>&1 \
  && ok "experience_build.py renders fixture" || bad "experience_build.py renders fixture"

FJ="$FIXOUT/data/index.json"
exists "fixture data/index.json" "$FJ"
assert_json "schema_version is pinned"            "$FJ" 'd["schema_version"] == 1'
assert_json "generated_at + law recorded"         "$FJ" 'd["generated_at"] and d["law"].endswith("experience-console-SYNTHESIS.md")'
assert_json "22 trails projected"                 "$FJ" 'len(d["trails"]) == 22 == d["counts"]["trails"]'

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
assert_json "PMI: P2 when n_done>=5 and success>=70%"  "$FJ" 'R["fixture-builder"]["pmi"]["band"] == "P2"'
assert_json "PMI: n_done<5 stays P1 even at 80%"       "$FJ" 'R["fixture-runner"]["pmi"]["band"] == "P1" and R["fixture-runner"]["n_done"] == 4'
assert_json "PMI: success<70% stays P1 with n_done>=5" "$FJ" 'R["fixture-flaky"]["pmi"]["band"] == "P1" and R["fixture-flaky"]["n_done"] == 5 and R["fixture-flaky"]["success_rate"] < 0.7'
assert_json "PMI: n<3 is P0"                           "$FJ" 'R["fixture-critic"]["pmi"]["band"] == "P0"'
assert_json "PMI: specialized pack alone never grants P2" "$FJ" \
  'all(s["pmi"]["band"] != "P2" or (s["n_done"] >= 5 and s["success_rate"] >= 0.7) for s in R.values())'
assert_json "PMI: Phase 0 cap is P2, no band above"    "$FJ" \
  'all(s["pmi"]["band"] in ("P0","P1","P2") and s["pmi"]["cap"] == "P2" for s in R.values())'
assert_json "PMI: inputs disclosed per role"           "$FJ" \
  'all({"n","n_done","n_fail","n_known","success_rate","packs","specialized_packs"} <= set(s["pmi"]["inputs"]) for s in R.values())'
assert_json "PMI: policy gates published"              "$FJ" \
  'd["pmi_policy"]["p2_min_done"] == 5 and d["pmi_policy"]["p2_min_success"] == 0.7 and d["pmi_policy"]["phase0_cap"] == "P2"'
if grep -R 'class="pmi">P3' "$FIXOUT" >/dev/null 2>&1; then
  bad "PMI: no P3 band rendered in HTML"
else
  ok "PMI: no P3 band rendered in HTML"
fi

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
assert_absent_html "no inline style= attributes in fixture HTML" "$FIXOUT" ' style="'
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
grep -q 'class="pmi band-p2">P2' "$FIXOUT/role/fixture-builder/index.html" && ok "PMI band rendered as badge" || bad "PMI band rendered as badge"
grep -q 'PMI inputs' "$FIXOUT/role/fixture-builder/index.html" && ok "PMI disclosure present" || bad "PMI disclosure present"

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
assert_absent_html "no inline styles in site HTML" "$SITE" ' style="|<style'

assert_json "real data parses with pinned schema" "$RJ" 'd["schema_version"] == 1 and isinstance(d["trails"], list)'
assert_json "real trails carry contract fields"   "$RJ" \
  'all({"task_id","agent","wave","status","branch","provenance","join_method","project_label","conductor","ts","base_sha","head_sha","handoff_sections"} <= set(t) for t in d["trails"])'
assert_json "real joins never invent companies"   "$RJ" 'all(t["company_id"] is None or t["company_id"] in C for t in d["trails"])'
assert_json "real PMI capped at P2"               "$RJ" 'all(s["pmi"]["band"] in ("P0","P1","P2") for s in R.values())'
assert_absent "no secret-shaped tokens in site"   "$SITE" "$SECRET_SHAPES"
assert_absent "no operator home paths in site"    "$SITE" "$HOME_PATHS"

if compgen -G "$SITE/trail/*/index.html" >/dev/null; then
  ok "trail pages generated"
else
  ok "trail pages (none — empty fleet ok)"
fi

for target in experience experience-open desk; do
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
  'd["generated_at"] != "STALE-STAMP" and d["schema_version"] == 1'
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
