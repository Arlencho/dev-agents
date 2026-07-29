#!/usr/bin/env bash
# Fleet Desk — build the data contract, then the static site.
#   1. scripts/experience_data.py  → site/experience/data/index.json (schema: docs/experience-data.md)
#   2. scripts/experience_build.py → site/experience/**.html (reads ONLY that JSON)
# Law: docs/proposals/experience-console-SYNTHESIS.md
#
# Extra arguments are forwarded to the data step, e.g.
#   ./scripts/experience-build.sh --no-gh --snapshot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

OUT_DIR="${EXPERIENCE_OUT:-$REPO_DIR/site/experience}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found on PATH" >&2; exit 1; }

# 1) data first — rewrites data/ only, rendered HTML is left in place
python3 "$SCRIPT_DIR/experience_data.py" --repo "$REPO_DIR" --out "$OUT_DIR" "$@"

# 2) HTML second — pure projection of the JSON; clears stale pages, keeps data/
python3 "$SCRIPT_DIR/experience_build.py" --repo "$REPO_DIR" --out "$OUT_DIR"

echo ""
echo "Data:  file://$OUT_DIR/data/index.json"
echo "Open:  file://$OUT_DIR/index.html"
echo "Or:    make experience-open"
