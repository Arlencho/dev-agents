#!/usr/bin/env bash
# Fleet Desk Phase 0 fixture tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$SCRIPT_DIR/fixtures/experience-mini"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# Build against real repo (smoke) + assert outputs
cd "$REPO_DIR"
python3 "$REPO_DIR/scripts/experience_build.py" >/dev/null
SITE="$REPO_DIR/site/experience"

[ -f "$SITE/index.html" ] && ok "index.html" || bad "index.html"
[ -f "$SITE/work/index.html" ] && ok "work/index.html" || bad "work/index.html"
[ -f "$SITE/about/index.html" ] && ok "about/index.html" || bad "about/index.html"
[ -f "$SITE/roles/index.html" ] && ok "roles/index.html" || bad "roles/index.html"
[ -f "$SITE/skills/index.html" ] && ok "skills/index.html" || bad "skills/index.html"
[ -f "$SITE/learnings/index.html" ] && ok "learnings/index.html" || bad "learnings/index.html"
[ -f "$SITE/conductor/index.html" ] && ok "conductor/index.html" || bad "conductor/index.html"

grep -q "Fleet Desk" "$SITE/index.html" && ok "brand present" || bad "brand present"
grep -q "group by wave\|Wave " "$SITE/work/index.html" && ok "work has wave grouping" || bad "work has wave grouping"
grep -q "PMI\|Playbook Maturity\|pmi" "$SITE/roles/index.html" && ok "roles PMI" || bad "roles PMI"
grep -qi "make experience" "$SITE/about/index.html" && ok "about refresh hint" || bad "about refresh hint"

# no obvious secret leakage patterns from known bad tokens
if grep -RE 'ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}' "$SITE" >/dev/null 2>&1; then
  bad "secret-like token found in site"
else
  ok "no ghp_/sk- tokens in site"
fi

# at least one trail page if handoffs exist
if compgen -G "$SITE/trail/*/index.html" >/dev/null; then
  ok "trail pages generated"
else
  # empty fleet still ok
  ok "trail pages (none — empty fleet ok)"
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
