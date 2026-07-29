#!/usr/bin/env bash
# Fleet Desk Phase 0 — build static site under site/experience/
# Law: docs/proposals/experience-console-SYNTHESIS.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"
python3 "$SCRIPT_DIR/experience_build.py"
echo ""
echo "Open:  file://$REPO_DIR/site/experience/index.html"
echo "Or:    make experience-open"
