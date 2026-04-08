#!/bin/bash
set -euo pipefail

# Full machine setup — run this ONCE on any new Mac (Mini or MacBook).
# Installs all dev tools, Claude Code, bootstraps agents, and configures auth.
# Tailors setup based on machine role (orchestrator vs worker).
#
# Usage:
#   ./scripts/setup-machine.sh
#
# Interactive: prompts for machine type, GitHub login, and GCP login.

echo "=========================================="
echo "  Dev Machine Setup"
echo "=========================================="
echo ""

# --------------------------------------------------
# 0. What kind of machine is this?
# --------------------------------------------------
echo "What type of machine is this?"
echo ""
echo "  1) MacBook Pro  — orchestrator: you sit here, plan work, review PRs, merge"
echo "  2) Mac Mini     — worker: receives tasks via SSH, runs agents unattended"
echo ""
read -p "Enter 1 or 2: " MACHINE_TYPE

case "$MACHINE_TYPE" in
    1)
        ROLE="orchestrator"
        echo ""
        echo "Setting up as ORCHESTRATOR (MacBook Pro)"
        echo "  - All 11 agents installed"
        echo "  - Interactive mode (you drive)"
        echo "  - Review + merge happens here"
        echo ""
        ;;
    2)
        ROLE="worker"
        read -p "Give this machine a name (e.g., mac-mini-1): " MACHINE_NAME
        MACHINE_NAME="${MACHINE_NAME:-mac-mini-$(hostname -s)}"
        echo ""
        echo "Setting up as WORKER: $MACHINE_NAME"
        echo "  - All 11 agents installed"
        echo "  - SSH access enabled for remote dispatch"
        echo "  - Runs agents unattended via run-remote.sh"
        echo ""
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

# --------------------------------------------------
# 1. Homebrew
# --------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    echo "[1/8] Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
else
    echo "[1/8] Homebrew already installed"
fi

# --------------------------------------------------
# 2. Core tools
# --------------------------------------------------
echo "[2/8] Installing core tools..."
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
echo "[3/8] Installing Claude Code..."
if ! command -v claude >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
else
    echo "  Claude Code already installed"
fi

# --------------------------------------------------
# 4. Clone dev-agents and bootstrap
# --------------------------------------------------
echo "[4/8] Setting up dev-agents..."
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
echo "[5/8] GitHub authentication"
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
echo "[6/8] GCP authentication"
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
echo "[7/8] Docker setup"
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
# 8. Machine-specific setup
# --------------------------------------------------
echo ""
echo "[8/8] Configuring for $ROLE role..."

if [ "$ROLE" = "worker" ]; then
    # Enable SSH for remote dispatch
    echo "  Checking SSH access..."
    if systemsetup -getremotelogin 2>/dev/null | grep -q "On"; then
        echo "  Remote Login (SSH) is already enabled"
    else
        echo "  Enabling Remote Login (SSH)..."
        echo "  (This may require your password)"
        sudo systemsetup -setremotelogin on 2>/dev/null || echo "  Could not enable SSH automatically. Please enable in System Settings > General > Sharing > Remote Login"
    fi

    # Create working directory
    mkdir -p "$HOME/dev"

    # Save machine config
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/machine-role.json" <<EOF
{
    "role": "worker",
    "name": "$MACHINE_NAME",
    "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname -s)",
    "ip": "$(ipconfig getifaddr en0 2>/dev/null || echo 'unknown')"
}
EOF
    echo "  Machine config saved to ~/.claude/machine-role.json"

elif [ "$ROLE" = "orchestrator" ]; then
    # Save machine config
    mkdir -p "$HOME/.claude"
    cat > "$HOME/.claude/machine-role.json" <<EOF
{
    "role": "orchestrator",
    "name": "macbook-pro",
    "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname -s)"
}
EOF
    echo "  Machine config saved to ~/.claude/machine-role.json"
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "=========================================="
echo "  Setup Complete! Role: $ROLE"
echo "=========================================="
echo ""
echo "  Tools installed:"
echo "    $(go version 2>/dev/null || echo 'Go: not found')"
echo "    Node $(node --version 2>/dev/null || echo 'not found')"
echo "    Claude Code $(claude --version 2>/dev/null || echo 'not found')"
echo "    $(gh --version 2>/dev/null | head -1 || echo 'gh: not found')"
echo ""
echo "  Agents bootstrapped (11):"
ls -1 ~/.claude/agents/*.md 2>/dev/null | while read f; do
    echo "    $(basename "$f" .md)"
done

echo ""
if [ "$ROLE" = "orchestrator" ]; then
    echo "  You are the ORCHESTRATOR. This is your command center."
    echo ""
    echo "  Start working:"
    echo "    cd <repo> && claude --agent orchestrator 'what should we work on?'"
    echo ""
    echo "  Dispatch to workers:"
    echo "    ./scripts/run-remote.sh <mac-mini-name> <repo-url> <agent> 'task'"
    echo ""
    echo "  Registered workers:"
    if [ -f "$HOME/.claude/workers.json" ]; then
        cat "$HOME/.claude/workers.json"
    else
        echo "    None yet. After setting up Mac Minis, add them:"
        echo "    ssh mac-mini-1 cat ~/.claude/machine-role.json"
    fi
elif [ "$ROLE" = "worker" ]; then
    echo "  This machine ($MACHINE_NAME) is ready to receive work."
    echo ""
    echo "  From your MacBook, dispatch tasks with:"
    echo "    ./scripts/run-remote.sh $MACHINE_NAME <repo-url> <agent> 'task'"
    echo ""
    echo "  Make sure your MacBook can SSH to this machine:"
    echo "    ssh $MACHINE_NAME 'echo connected'"
    echo ""
    echo "  If SSH doesn't work, add to your MacBook's ~/.ssh/config:"
    echo "    Host $MACHINE_NAME"
    echo "      HostName $(ipconfig getifaddr en0 2>/dev/null || echo '<this-machines-ip>')"
    echo "      User $(whoami)"
    echo ""
fi
