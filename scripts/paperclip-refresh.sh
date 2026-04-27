#!/usr/bin/env bash
#
# paperclip-refresh.sh — fetch latest Paperclip releases and append a dated
# entry to learnings/paperclip-changelog.md. Run monthly (or on-demand) to
# keep the dossier current with Paperclip's release pace (~weekly).
#
# Usage:
#   ./scripts/paperclip-refresh.sh
#
# Reference: dev-agents/PAPERCLIP.md
#
# What it does:
#   1. Reads the currently-installed version from the running server (if up)
#      or from PAPERCLIP.md (pinned version).
#   2. Fetches the 5 most recent releases from github.com/paperclipai/paperclip.
#   3. Appends a dated entry to learnings/paperclip-changelog.md with:
#      - currently-installed version
#      - latest upstream release
#      - the gap (how many releases behind)
#      - notes from the latest release body, if any breaking-change keywords
#        are present (e.g. "BREAKING", "migrate", "deprecat")
#
# This is a deterministic shell script. For a full tech-scout analysis (with
# LLM-generated impact assessment), invoke the tech-scout role separately:
#   make dispatch REPO=paperclipai/paperclip PLAN=<scout-plan>

set -euo pipefail

log() { printf '[paperclip-refresh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$REPO_ROOT/learnings/paperclip-changelog.md"
HEALTH_URL="http://127.0.0.1:3100/api/health"

command -v gh >/dev/null 2>&1 || die "gh CLI not found"

# Ensure the changelog file exists.
if [[ ! -f "$CHANGELOG" ]]; then
  mkdir -p "$(dirname "$CHANGELOG")"
  cat >"$CHANGELOG" <<'EOF'
# Paperclip Changelog (local view)

Tracks the gap between our pinned version and upstream releases. Updated by `scripts/paperclip-refresh.sh`. Run monthly or before any Paperclip upgrade.

EOF
fi

# Detect installed version (prefer live server, fall back to PAPERCLIP.md).
INSTALLED=""
if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
  INSTALLED="$(curl -sf "$HEALTH_URL" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
fi
if [[ -z "$INSTALLED" ]]; then
  INSTALLED="$(grep -m1 'Pinned version' "$REPO_ROOT/PAPERCLIP.md" 2>/dev/null \
    | sed -n 's/.*Pinned version: *\(`*\)\([^`]*\).*/\2/p')"
fi
INSTALLED="${INSTALLED:-unknown}"

log "installed version: $INSTALLED"

# Fetch upstream releases.
RELEASES_JSON="$(gh api repos/paperclipai/paperclip/releases --paginate --jq '.[0:5] | map({tag_name, name, published_at, body})' 2>/dev/null \
  || echo '[]')"

if [[ "$RELEASES_JSON" == '[]' ]]; then
  log "could not fetch upstream releases — appending placeholder entry"
fi

LATEST_TAG="$(echo "$RELEASES_JSON" | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)"
LATEST_TAG="${LATEST_TAG:-unknown}"

# Append dated entry.
DATE="$(date -u +%Y-%m-%d)"
{
  echo ""
  echo "## $DATE"
  echo ""
  echo "- Installed: \`$INSTALLED\`"
  echo "- Latest upstream: \`$LATEST_TAG\`"
  if [[ "$INSTALLED" != "$LATEST_TAG" && "$INSTALLED" != "unknown" && "$LATEST_TAG" != "unknown" ]]; then
    echo "- **Gap detected** — review release notes before upgrading"
  fi
  echo ""
  echo "### Recent releases (5 most recent)"
  echo ""
  echo "$RELEASES_JSON" | python3 -c '
import json, sys, textwrap
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
breaking_keywords = ("BREAKING", "breaking", "migrate", "deprecat")
for r in data:
    tag = r.get("tag_name", "?")
    name = r.get("name") or ""
    when = (r.get("published_at") or "")[:10]
    body = (r.get("body") or "").strip()
    flagged = [kw for kw in breaking_keywords if kw in body]
    flag = " ⚠ flagged" if flagged else ""
    print(f"- `{tag}` ({when}) — {name}{flag}")
' 2>/dev/null || echo "- (could not parse releases — gh CLI auth or rate limit?)"
} >>"$CHANGELOG"

log "appended entry to $CHANGELOG"
log "review with: less $CHANGELOG"
