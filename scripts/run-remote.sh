#!/bin/bash
set -euo pipefail

# Run a Claude agent on a remote machine via SSH
# Usage: ./scripts/run-remote.sh <host> <repo-url> <agent> <task> [branch]
#
# WARNING: This script uses --dangerously-skip-permissions for unattended
# execution. The agent can read/write/execute without prompts. Only run
# on trusted machines with trusted repos.
#
# Prerequisites on remote machine:
#   1. Claude Code installed (npm install -g @anthropic-ai/claude-code)
#   2. Agents bootstrapped (./scripts/bootstrap.sh claude)
#   3. GitHub SSH key configured
#
# Examples:
#   ./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/olympus-platform.git go-backend "fix auth bug #123"
#   ./scripts/run-remote.sh mac-mini-2 git@github.com:Arlencho/olympus-platform.git web-frontend "build settings page" feat/settings

HOST="${1:?Usage: run-remote.sh <host> <repo-url> <agent> <task> [branch] [--log-dir <dir>]}"
REPO_URL="${2:?Missing repo URL}"
AGENT="${3:?Missing agent name}"
TASK="${4:?Missing task description}"
BRANCH="${5:-fix/${AGENT}-$(date +%s)}"
shift 5 2>/dev/null || shift $#

# Parse optional flags
LOG_DIR="~/dev/agent-logs"
# Model tier or ID, set by dispatch.sh via AGENT_MODEL env var (e.g. opus,
# sonnet, haiku, or an explicit model ID). Empty means use the CLI default.
MODEL="${AGENT_MODEL:-}"
# Provider (CLI vendor) set by dispatch.sh via AGENT_PROVIDER (claude|kimi|grok).
# Selects which providers/<provider>/launch.sh runs the agent. All authenticate
# via subscription login on the worker — no API keys anywhere.
PROVIDER="${AGENT_PROVIDER:-claude}"
while [ $# -gt 0 ]; do
    case "$1" in
        --log-dir)
            LOG_DIR="${2:?--log-dir requires a path}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model requires a value}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_NAME=$(basename "$REPO_URL" .git)
WORK_DIR="~/dev/$REPO_NAME"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${REPO_NAME}-${BRANCH//\//-}-${TIMESTAMP}.log"

echo "=== Remote Agent Execution ==="
echo "Host:   $HOST"
echo "Repo:   $REPO_NAME"
echo "Agent:  $AGENT"
echo "Model:  ${MODEL:-default}"
echo "Branch: $BRANCH"
echo "Task:   $TASK"
echo "Log:    $LOG_DIR/$LOG_FILE"
echo ""

# Verify SSH connectivity
echo "Checking SSH connection..."
ssh -o ConnectTimeout=5 "$HOST" "echo 'Connected'" || {
    echo "ERROR: Cannot SSH to $HOST"
    echo "Make sure SSH key is configured: ssh-copy-id $HOST"
    exit 1
}

# Generate preamble (includes CLAUDE.md, learnings, parallel sessions, git state, issue context)
PREAMBLE=$("$SCRIPT_DIR/preamble.sh" "$WORK_DIR" "$AGENT" "$BRANCH" 2>/dev/null || true)
if [ -n "$PREAMBLE" ]; then
    FULL_TASK="$PREAMBLE

YOUR TASK: $TASK"
    echo "Injected session preamble into prompt"
else
    FULL_TASK="$TASK"
fi

# Copy guardrails to remote
GUARDRAILS_SCRIPT="$SCRIPT_DIR/guardrails.sh"
GUARDRAILS_CONFIG="$SCRIPT_DIR/../config/guardrails.yaml"
if [ -f "$GUARDRAILS_SCRIPT" ] && [ -f "$GUARDRAILS_CONFIG" ]; then
    echo "Copying guardrails to $HOST..."
    ssh "$HOST" "mkdir -p ~/dev/guardrails/config"
    scp -q "$GUARDRAILS_SCRIPT" "$HOST:~/dev/guardrails/guardrails.sh"
    scp -q "$GUARDRAILS_CONFIG" "$HOST:~/dev/guardrails/config/guardrails.yaml"
    ssh "$HOST" "chmod +x ~/dev/guardrails/guardrails.sh"
else
    echo "WARNING: Guardrails not found locally, skipping safety hooks"
fi

# Ship the provider launcher runtime to the worker (same scp precedent as
# guardrails above). lib.sh + the chosen provider's launch.sh land flat in
# ~/dev/agent-runtime/; non-claude providers also get the role charter, which
# their launcher injects into the prompt (claude resolves --agent natively).
PROVIDER_LAUNCHER="$SCRIPT_DIR/../providers/$PROVIDER/launch.sh"
PROVIDER_LIB="$SCRIPT_DIR/../providers/lib.sh"
RATECAP_CONF="$SCRIPT_DIR/../config/ratecap-patterns.conf"
if [ -f "$PROVIDER_LAUNCHER" ] && [ -f "$PROVIDER_LIB" ]; then
    echo "Shipping $PROVIDER launcher runtime to $HOST..."
    ssh "$HOST" "mkdir -p ~/dev/agent-runtime/roles"
    scp -q "$PROVIDER_LIB" "$HOST:~/dev/agent-runtime/lib.sh"
    scp -q "$PROVIDER_LAUNCHER" "$HOST:~/dev/agent-runtime/launch.sh"
    [ -f "$RATECAP_CONF" ] && scp -q "$RATECAP_CONF" "$HOST:~/dev/agent-runtime/ratecap-patterns.conf"
    if [ "$PROVIDER" != "claude" ] && [ -f "$SCRIPT_DIR/../roles/$AGENT.md" ]; then
        scp -q "$SCRIPT_DIR/../roles/$AGENT.md" "$HOST:~/dev/agent-runtime/roles/$AGENT.md"
    fi
else
    echo "ERROR: launcher runtime for provider '$PROVIDER' not found ($PROVIDER_LAUNCHER)" >&2
    exit 1
fi

# Execute on remote
echo "Starting agent on $HOST..."
ssh "$HOST" bash -s <<REMOTE_SCRIPT
set -euo pipefail

# Create log directory
mkdir -p $LOG_DIR

# Ensure repo exists
if [ ! -d "$WORK_DIR" ]; then
    echo "Cloning $REPO_URL..."
    mkdir -p ~/dev
    cd ~/dev
    git clone "$REPO_URL"
fi

cd "$WORK_DIR"

# Update and create branch
git fetch origin
git checkout main
git pull origin main
git checkout -b "$BRANCH"

# Install guardrails git hooks
if [ -x ~/dev/guardrails/guardrails.sh ]; then
    ~/dev/guardrails/guardrails.sh install "$WORK_DIR"
fi

# Run the agent through the provider launcher (it verifies its own CLI is
# installed + logged in, exiting 69 if not). $MODEL / $AGENT / $FULL_TASK
# expand dispatcher-side through the unquoted heredoc; the ~ paths expand here
# on the worker. set +e so a launcher exit (69/75/1) is captured, not aborted.
echo "Starting $PROVIDER launcher for agent $AGENT (model: ${MODEL:-default})..."
echo "Logging to: $LOG_DIR/$LOG_FILE"
set +e
AGENT_MODEL="$MODEL" ROLES_DIR=~/dev/agent-runtime/roles \
    RATECAP_PATTERNS=~/dev/agent-runtime/ratecap-patterns.conf \
    bash ~/dev/agent-runtime/launch.sh "$AGENT" "$FULL_TASK" 2>&1 | tee "$LOG_DIR/$LOG_FILE"
AGENT_EXIT=\${PIPESTATUS[0]}
set -e

# Push the branch
echo "Pushing branch $BRANCH..."
git push origin "$BRANCH" 2>/dev/null || echo "Nothing to push (no changes)"

echo ""
echo "Log saved: $LOG_DIR/$LOG_FILE"
echo "Done on $HOST"
exit \$AGENT_EXIT
REMOTE_SCRIPT

REMOTE_EXIT=$?
REMOTE_LOG_PATH="$LOG_DIR/$LOG_FILE"

# Rate-cap sentinel (exit 75): mark the vendor cooling, log the event, learn it.
# run-remote RECORDS; dispatch.sh REACTS (fails over per routing.yaml chain).
if [ "$REMOTE_EXIT" -eq 75 ]; then
    STATE_DIR="$SCRIPT_DIR/../logs/provider-state"
    mkdir -p "$STATE_DIR"
    date +%s > "$STATE_DIR/${PROVIDER}.cooldown"
    echo "$(date -u +%FT%TZ)|$PROVIDER|$AGENT|$HOST|ratecap" >> "$STATE_DIR/ratecap.log"
    [ -x "$SCRIPT_DIR/learnings.sh" ] && "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$PROVIDER" failure \
        "RATE_CAP: $PROVIDER consumer cap hit by $AGENT on $HOST" --severity high 2>/dev/null || true
    echo "RATE_CAP recorded for $PROVIDER — dispatch will fail over"
fi

# On other failures, auto-record a learning from the last 3 log lines
# (skip 75 — already logged high above).
if [ "$REMOTE_EXIT" -ne 0 ] && [ "$REMOTE_EXIT" -ne 75 ] && [ -x "$SCRIPT_DIR/learnings.sh" ]; then
    FAIL_TAIL=$(ssh "$HOST" "tail -3 $LOG_DIR/$LOG_FILE 2>/dev/null" || echo "no log available")
    "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$AGENT" failure \
        "Agent exited $REMOTE_EXIT. Last output: $FAIL_TAIL" \
        --severity medium 2>/dev/null || true
    echo "Recorded failure learning for $REPO_NAME/$AGENT"
fi

echo ""
echo "=== Agent completed on $HOST ==="
echo "Remote log: $HOST:$REMOTE_LOG_PATH"
echo "Check: gh pr list -R $(echo $REPO_URL | sed 's/.*://' | sed 's/\.git//')"
