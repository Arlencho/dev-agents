#!/usr/bin/env bash
#
# paperclip-down.sh — stop the local Paperclip server cleanly.
#
# Usage:
#   ./scripts/paperclip-down.sh
#
# Reference: dev-agents/PAPERCLIP.md

set -euo pipefail

log() { printf '[paperclip-down] %s\n' "$*" >&2; }

HEALTH_URL="http://127.0.0.1:3100/api/health"

if ! curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
  log "server not running"
  exit 0
fi

# Find PIDs listening on port 3100 (server) and 54329 (embedded postgres).
SERVER_PIDS=$(lsof -tiTCP:3100 -sTCP:LISTEN 2>/dev/null || true)
PG_PIDS=$(lsof -tiTCP:54329 -sTCP:LISTEN 2>/dev/null || true)

if [[ -n "$SERVER_PIDS" ]]; then
  log "stopping server (pids: $SERVER_PIDS)"
  # SIGTERM first, give it 5s, then SIGKILL.
  kill $SERVER_PIDS 2>/dev/null || true
  for _ in {1..5}; do
    sleep 1
    if ! curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
      log "server stopped"
      break
    fi
  done
  if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
    log "server didn't respond to SIGTERM, sending SIGKILL"
    kill -9 $SERVER_PIDS 2>/dev/null || true
  fi
fi

# Embedded postgres is managed by the server; if it's still up after server
# stops, let it shut itself down. Don't force-kill — risk of corruption.
if [[ -n "$PG_PIDS" ]]; then
  log "embedded postgres still running (pids: $PG_PIDS) — will exit on its own"
fi

log "done"
