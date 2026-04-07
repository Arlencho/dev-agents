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

HOST="${1:?Usage: run-remote.sh <host> <repo-url> <agent> <task> [branch]}"
REPO_URL="${2:?Missing repo URL}"
AGENT="${3:?Missing agent name}"
TASK="${4:?Missing task description}"
BRANCH="${5:-fix/${AGENT}-$(date +%s)}"

REPO_NAME=$(basename "$REPO_URL" .git)
WORK_DIR="~/dev/$REPO_NAME"

echo "=== Remote Agent Execution ==="
echo "Host:   $HOST"
echo "Repo:   $REPO_NAME"
echo "Agent:  $AGENT"
echo "Branch: $BRANCH"
echo "Task:   $TASK"
echo ""

# Verify SSH connectivity
echo "Checking SSH connection..."
ssh -o ConnectTimeout=5 "$HOST" "echo 'Connected'" || {
    echo "ERROR: Cannot SSH to $HOST"
    echo "Make sure SSH key is configured: ssh-copy-id $HOST"
    exit 1
}

# Execute on remote
echo "Starting agent on $HOST..."
ssh "$HOST" bash -s <<REMOTE_SCRIPT
set -euo pipefail

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

# Verify claude is installed
command -v claude >/dev/null 2>&1 || {
    echo "ERROR: Claude Code not installed on $HOST"
    echo "Run: npm install -g @anthropic-ai/claude-code"
    exit 1
}

# Run the agent
echo "Starting claude --agent $AGENT..."
claude --agent "$AGENT" --dangerously-skip-permissions "$TASK"

# Push the branch
echo "Pushing branch $BRANCH..."
git push origin "$BRANCH" 2>/dev/null || echo "Nothing to push (no changes)"

echo "Done on $HOST"
REMOTE_SCRIPT

echo ""
echo "=== Agent completed on $HOST ==="
echo "Check: gh pr list -R $(echo $REPO_URL | sed 's/.*://' | sed 's/\.git//')"
