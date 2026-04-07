#!/bin/bash
set -euo pipefail

# Bootstrap a new machine with Claude Code agent definitions
# Usage: ./scripts/bootstrap.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_DIR="$HOME/.claude"

echo "=== Claude Agents Bootstrap ==="
echo ""

# 1. Check prerequisites
echo "Checking prerequisites..."
command -v git >/dev/null 2>&1 || { echo "ERROR: git not installed"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not installed. Run: brew install node"; exit 1; }

# 2. Install Claude Code if missing
if ! command -v claude >/dev/null 2>&1; then
    echo "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    echo "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown')"
fi

# 3. Create ~/.claude directory structure
echo "Setting up ~/.claude..."
mkdir -p "$CLAUDE_DIR/agents"

# 4. Symlink agent definitions (so git pull updates them everywhere)
echo "Linking agent definitions..."
for agent in "$REPO_DIR/agents/"*.md; do
    name=$(basename "$agent")
    target="$CLAUDE_DIR/agents/$name"
    if [ -L "$target" ]; then
        rm "$target"
    elif [ -f "$target" ]; then
        echo "  WARNING: $target exists (not a symlink). Backing up to ${target}.bak"
        mv "$target" "${target}.bak"
    fi
    ln -s "$agent" "$target"
    echo "  Linked: $name"
done

# 5. Auth reminders
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Agent definitions linked to ~/.claude/agents/"
echo "Updates via 'git pull' in this repo will apply globally."
echo ""
echo "Next steps:"
echo "  1. Authenticate GitHub:  gh auth login"
echo "  2. Authenticate GCP:     gcloud auth login"
echo "  3. Clone your repos:     git clone git@github.com:Arlencho/<repo>.git"
echo "  4. Run Claude:           cd <repo> && claude 'do something'"
echo ""
echo "Available agents:"
for agent in "$REPO_DIR/agents/"*.md; do
    name=$(basename "$agent" .md)
    desc=$(grep "^description:" "$agent" | head -1 | sed 's/description: //')
    printf "  %-18s %s\n" "$name" "$desc"
done
