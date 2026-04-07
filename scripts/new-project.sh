#!/bin/bash
set -euo pipefail

# Bootstrap a new project with AI agent infrastructure
# Usage: ./scripts/new-project.sh <template> <project-name> [github-org]
#
# Templates: go-nextjs, python-fastapi
# Examples:
#   ./scripts/new-project.sh go-nextjs my-saas-app
#   ./scripts/new-project.sh go-nextjs my-saas-app Arlencho
#   ./scripts/new-project.sh python-fastapi data-pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TEMPLATE="${1:?Usage: new-project.sh <template> <project-name> [github-org]}"
PROJECT_NAME="${2:?Missing project name}"
GITHUB_ORG="${3:-Arlencho}"
PROJECT_DIR="$(pwd)/$PROJECT_NAME"

echo "=== New Project: $PROJECT_NAME ==="
echo "Template: $TEMPLATE"
echo "Directory: $PROJECT_DIR"
echo ""

# Validate template
TEMPLATE_FILE="$REPO_DIR/templates/${TEMPLATE}.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Unknown template '$TEMPLATE'"
    echo "Available templates:"
    for t in "$REPO_DIR/templates/"*.md; do
        echo "  - $(basename "$t" .md)"
    done
    exit 1
fi

# Create project directory
if [ -d "$PROJECT_DIR" ]; then
    echo "ERROR: Directory already exists: $PROJECT_DIR"
    exit 1
fi

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Initialize git
git init
echo "# $PROJECT_NAME" > README.md

# Copy CLAUDE.md from template
cp "$TEMPLATE_FILE" CLAUDE.md
echo "Created CLAUDE.md from $TEMPLATE template"

# Create .gitignore
cat > .gitignore <<'GITIGNORE'
# Environment
.env
.env.*
!.env.example

# OS
.DS_Store
Thumbs.db

# Dependencies
node_modules/
vendor/

# Build
dist/
build/
.next/
out/

# IDE
.idea/
.vscode/
*.swp
*.swo
GITIGNORE

# Create .claude directory with agent link
mkdir -p .claude
cat > .claude/settings.json <<'SETTINGS'
{
  "permissions": {
    "allow": [],
    "deny": []
  }
}
SETTINGS

# Template-specific scaffolding
case "$TEMPLATE" in
    go-nextjs)
        mkdir -p apps/api/cmd/server apps/api/internal/{handler,service,provider,model,middleware,config} apps/api/db/{migrations,queries} apps/web/app apps/web/components apps/web/lib apps/mobile packages/api-client scripts .github/workflows
        echo "Created Go + Next.js monorepo structure"
        ;;
    python-fastapi)
        mkdir -p app/{api,models,services,db} tests scripts .github/workflows
        echo "Created Python FastAPI structure"
        ;;
esac

# Create Makefile
cat > Makefile <<'MAKEFILE'
.DEFAULT_GOAL := help

.PHONY: help dev test lint agents

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

dev: ## Start development environment
	@echo "TODO: Configure for your project"

test: ## Run all tests
	@echo "TODO: Configure for your project"

lint: ## Run linters
	@echo "TODO: Configure for your project"

agents: ## List available AI agents
	@echo "Available agents:"
	@for f in $(HOME)/.claude/agents/*.md; do \
		name=$$(basename "$$f" .md); \
		desc=$$(grep "^description:" "$$f" | head -1 | sed 's/description: //'); \
		printf "  %-18s %s\n" "$$name" "$$desc"; \
	done
MAKEFILE

# Initial commit
git add -A
git commit -m "Initial project scaffold from $TEMPLATE template"

echo ""
echo "=== Project Created ==="
echo ""
echo "Directory: $PROJECT_DIR"
echo "Template:  $TEMPLATE"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_NAME"
echo "  2. Edit CLAUDE.md with your project specifics"
echo "  3. Create GitHub repo: gh repo create $GITHUB_ORG/$PROJECT_NAME --private --source=. --push"
echo "  4. Start building: claude --agent go-backend 'scaffold the API'"
