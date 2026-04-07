#!/bin/bash
set -euo pipefail

# Bootstrap a new machine with AI coding agent definitions
# Usage: ./scripts/bootstrap.sh [provider]
# Providers: claude (default), openai, cursor, grok

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PROVIDER="${1:-claude}"

echo "=== Dev Agents Bootstrap ==="
echo "Provider: $PROVIDER"
echo ""

case "$PROVIDER" in
  claude)
    AGENT_SOURCE="$REPO_DIR/providers/claude/agents"
    TARGET_DIR="$HOME/.claude/agents"

    # Check prerequisites
    command -v git >/dev/null 2>&1 || { echo "ERROR: git not installed"; exit 1; }
    command -v node >/dev/null 2>&1 || { echo "ERROR: node not installed. Run: brew install node"; exit 1; }

    # Install Claude Code if missing
    if ! command -v claude >/dev/null 2>&1; then
        echo "Installing Claude Code..."
        npm install -g @anthropic-ai/claude-code
    else
        echo "Claude Code already installed"
    fi

    # Create target directory
    mkdir -p "$TARGET_DIR"

    # Symlink agent definitions
    echo "Linking agent definitions to $TARGET_DIR..."
    for agent in "$AGENT_SOURCE"/*.md; do
        name=$(basename "$agent")
        target="$TARGET_DIR/$name"
        if [ -L "$target" ]; then
            rm "$target"
        elif [ -f "$target" ]; then
            echo "  WARNING: $target exists (not a symlink). Backing up to ${target}.bak"
            mv "$target" "${target}.bak"
        fi
        ln -s "$agent" "$target"
        echo "  Linked: $name"
    done
    ;;

  openai|cursor|grok)
    echo "Provider '$PROVIDER' is not yet supported."
    echo "Placeholder exists at providers/$PROVIDER/"
    echo "Contributions welcome!"
    exit 0
    ;;

  *)
    echo "Unknown provider: $PROVIDER"
    echo "Available: claude, openai, cursor, grok"
    exit 1
    ;;
esac

# Auth reminders
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Agent definitions linked. Updates via 'git pull' apply globally."
echo ""
echo "Next steps:"
echo "  1. Authenticate GitHub:  gh auth login"
echo "  2. Authenticate GCP:     gcloud auth login"
echo "  3. Clone your repos:     git clone git@github.com:Arlencho/<repo>.git"
echo "  4. Run an agent:         cd <repo> && claude --agent go-backend 'do something'"
echo ""
echo "Available agents:"
for agent in "$REPO_DIR/roles/"*.md; do
    name=$(basename "$agent" .md)
    desc=$(grep "^description:" "$agent" | head -1 | sed 's/description: //')
    printf "  %-18s %s\n" "$name" "$desc"
done
