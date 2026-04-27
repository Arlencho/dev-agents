#!/usr/bin/env bash
#
# paperclip-up.sh — idempotent local Paperclip startup.
#
# First run: invokes `npx paperclipai onboard --yes`, which installs Paperclip
# under ~/.paperclip/, applies migrations, and starts the server at localhost:3100.
# Subsequent runs: detects existing instance and just starts the server.
#
# Usage:
#   ./scripts/paperclip-up.sh            # foreground (use Ctrl-C to stop)
#   ./scripts/paperclip-up.sh --bg       # background (logs to ~/.paperclip/instances/default/logs/)
#
# Reference: dev-agents/PAPERCLIP.md

set -euo pipefail

log() { printf '[paperclip-up] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

INSTANCE_DIR="${HOME}/.paperclip/instances/default"
HEALTH_URL="http://127.0.0.1:3100/api/health"
BG=0

for arg in "$@"; do
  case "$arg" in
    --bg) BG=1 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: $arg" ;;
  esac
done

# Already running?
if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
  VERSION="$(curl -sf "$HEALTH_URL" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  log "already running: version=$VERSION at http://127.0.0.1:3100"
  exit 0
fi

# Onboard if first run.
if [[ ! -d "$INSTANCE_DIR" ]]; then
  log "first run — invoking npx paperclipai onboard --yes"
  npx --yes paperclipai onboard --yes
  exit 0
fi

# Existing instance — start the server.
log "existing instance found at $INSTANCE_DIR — starting server"
if [[ "$BG" == "1" ]]; then
  mkdir -p "$INSTANCE_DIR/logs"
  nohup npx --yes paperclipai start \
    >"$INSTANCE_DIR/logs/server.out.log" \
    2>"$INSTANCE_DIR/logs/server.err.log" \
    </dev/null &
  PID=$!
  log "started in background (pid=$PID, logs in $INSTANCE_DIR/logs/)"
  # Wait for health check to confirm startup.
  for _ in {1..30}; do
    sleep 1
    if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
      log "health check passed"
      exit 0
    fi
  done
  die "server did not become healthy within 30s — check $INSTANCE_DIR/logs/"
else
  exec npx --yes paperclipai start
fi
