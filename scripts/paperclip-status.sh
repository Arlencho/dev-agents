#!/usr/bin/env bash
#
# paperclip-status.sh — health + version + instance dir for the local Paperclip server.
#
# Usage:
#   ./scripts/paperclip-status.sh
#
# Reference: dev-agents/PAPERCLIP.md

set -euo pipefail

HEALTH_URL="http://127.0.0.1:3100/api/health"
INSTANCE_DIR="${HOME}/.paperclip/instances/default"

if ! curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
  echo "status:    NOT RUNNING"
  echo "instance:  $INSTANCE_DIR"
  if [[ -d "$INSTANCE_DIR" ]]; then
    echo "           (instance dir exists — run 'make paperclip-up' to start)"
  else
    echo "           (no instance dir — run 'make paperclip-up' to install + start)"
  fi
  exit 1
fi

# Pretty-print the health JSON.
HEALTH="$(curl -sf "$HEALTH_URL")"
VERSION=$(echo "$HEALTH" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
DEPLOY_MODE=$(echo "$HEALTH" | sed -n 's/.*"deploymentMode":"\([^"]*\)".*/\1/p')
EXPOSURE=$(echo "$HEALTH" | sed -n 's/.*"deploymentExposure":"\([^"]*\)".*/\1/p')
AUTH=$(echo "$HEALTH" | sed -n 's/.*"authReady":\([^,}]*\).*/\1/p')
BOOTSTRAP=$(echo "$HEALTH" | sed -n 's/.*"bootstrapStatus":"\([^"]*\)".*/\1/p')

echo "status:    OK"
echo "version:   $VERSION"
echo "url:       http://127.0.0.1:3100"
echo "deploy:    $DEPLOY_MODE ($EXPOSURE)"
echo "auth:      $AUTH"
echo "bootstrap: $BOOTSTRAP"
echo "instance:  $INSTANCE_DIR"
echo "logs:      $INSTANCE_DIR/logs"
echo "backups:   $INSTANCE_DIR/data/backups"
