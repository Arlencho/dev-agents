#!/bin/bash
set -euo pipefail

# Full machine setup — run this ONCE on any new Mac (Mini or MacBook).
# Installs all dev tools, Claude Code, bootstraps agents, and configures auth.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Arlencho/dev-agents/main/scripts/setup-machine.sh | bash
#   or:
#   ./scripts/setup-machine.sh
#
# Interactive: will prompt for GitHub and GCP login.

echo "=========================================="
echo "  Dev Machine Setup"
echo "  Installs: Homebrew, Go, Node, Docker,"
echo "  Claude Code, dev-agents, and authenticates"
echo "=========================================="
echo ""

# --------------------------------------------------
# 1. Homebrew
# --------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    echo "[1/7] Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
else
    echo "[1/7] Homebrew already installed"
fi

# --------------------------------------------------
# 2. Core tools
# --------------------------------------------------
echo "[2/7] Installing core tools..."
TOOLS="go node git gh docker colima"
for tool in $TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  Installing $tool..."
        brew install "$tool" 2>/dev/null || true
    else
        echo "  $tool already installed"
    fi
done

# Additional Go tools
echo "  Installing Go tools (sqlc, goose)..."
go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest 2>/dev/null || true
go install github.com/pressly/goose/v3/cmd/goose@latest 2>/dev/null || true

# --------------------------------------------------
# 3. Claude Code
# --------------------------------------------------
echo "[3/7] Installing Claude Code..."
if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
else
    echo "  Claude Code already installed"
fi

# --------------------------------------------------
# 4. Clone dev-agents and bootstrap
# --------------------------------------------------
echo "[4/7] Setting up dev-agents..."
DEV_AGENTS_DIR="$HOME/dev/dev-agents"
if [ ! -d "$DEV_AGENTS_DIR" ]; then
    mkdir -p "$HOME/dev"
    git clone git@github.com:Arlencho/dev-agents.git "$DEV_AGENTS_DIR"
else
    echo "  dev-agents already cloned, pulling latest..."
    git -C "$DEV_AGENTS_DIR" pull
fi

chmod +x "$DEV_AGENTS_DIR/scripts/"*.sh
"$DEV_AGENTS_DIR/scripts/bootstrap.sh" claude

# --------------------------------------------------
# 5. GitHub auth
# --------------------------------------------------
echo ""
echo "[5/7] GitHub authentication"
if gh auth status >/dev/null 2>&1; then
    echo "  Already authenticated with GitHub"
else
    echo "  Please log in to GitHub..."
    gh auth login
fi

# --------------------------------------------------
# 6. GCP auth
# --------------------------------------------------
echo ""
echo "[6/7] GCP authentication"
if gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | grep -q "@"; then
    echo "  Already authenticated with GCP: $(gcloud config get-value account 2>/dev/null)"
else
    echo "  Please log in to GCP..."
    gcloud auth login
    gcloud config set project safeplace-io 2>/dev/null || true
fi

# --------------------------------------------------
# 7. Docker
# --------------------------------------------------
echo ""
echo "[7/7] Docker setup"
if docker info >/dev/null 2>&1; then
    echo "  Docker is running"
else
    echo "  Starting Docker..."
    if command -v colima >/dev/null 2>&1; then
        colima start --memory 4 --cpu 2 2>/dev/null || true
    else
        echo "  Please start Docker Desktop manually"
    fi
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "  Tools installed:"
echo "    $(go version 2>/dev/null || echo 'Go: not found')"
echo "    Node $(node --version 2>/dev/null || echo 'not found')"
echo "    Claude Code $(claude --version 2>/dev/null || echo 'not found')"
echo "    $(gh --version 2>/dev/null | head -1 || echo 'gh: not found')"
echo ""
echo "  Agents bootstrapped:"
ls -1 ~/.claude/agents/*.md 2>/dev/null | while read f; do
    echo "    $(basename "$f" .md)"
done
echo ""
echo "  Next steps:"
echo "    1. Clone your project:  git clone git@github.com:Arlencho/<repo>.git"
echo "    2. Start working:       cd <repo> && claude --agent orchestrator 'what should we work on?'"
echo ""
echo "  To use this machine remotely from your MacBook:"
echo "    ./scripts/run-remote.sh $(hostname -s) git@github.com:Arlencho/<repo>.git go-backend 'task'"
echo ""
