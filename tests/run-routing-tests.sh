#!/bin/bash
# Ground Truth: model routing + effective_model provenance.
# No network, no real vendor CLIs required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../providers/lib.sh
source "$REPO_DIR/providers/lib.sh"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %-60s → %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-60s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

# Mirror dispatch get_model (YAML model_routing)
get_model() {
    local agent="$1"
    local routing="$REPO_DIR/config/routing.yaml"
    local model
    model=$(grep -E "^\s+${agent}:" "$routing" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '[:space:]' | sed 's/#.*//')
    if [ -z "$model" ]; then
        model=$(grep -E "^\s+default:" "$routing" 2>/dev/null | head -1 | sed 's/.*:\s*//' | tr -d '[:space:]' | sed 's/#.*//')
    fi
    echo "${model:-sonnet}"
}

echo "== effective_model (provenance) =="
check "claude + opus" "opus" "$(effective_model claude opus)"
check "claude + empty" "default" "$(effective_model claude "")"
check "kimi + sonnet (ignored alias)" "vendor-default-k3" "$(effective_model kimi sonnet)"
check "kimi + opus (ignored alias)" "vendor-default-k3" "$(effective_model kimi opus)"
check "kimi + empty" "vendor-default-k3" "$(effective_model kimi "")"
check "kimi + native id" "kimi-for-coding" "$(effective_model kimi kimi-for-coding)"
check "grok + sonnet (ignored)" "vendor-default" "$(effective_model grok sonnet)"
check "grok + empty" "vendor-default" "$(effective_model grok "")"

echo "== routing.yaml quality-first seats =="
check "db-architect → opus" "opus" "$(get_model db-architect)"
check "test-engineer → opus" "opus" "$(get_model test-engineer)"
check "api-designer → opus" "opus" "$(get_model api-designer)"
check "devops → opus" "opus" "$(get_model devops)"
check "go-backend → sonnet" "sonnet" "$(get_model go-backend)"
check "web-frontend → sonnet (ignored by kimi)" "sonnet" "$(get_model web-frontend)"
check "backend-critic → opus" "opus" "$(get_model backend-critic)"
check "frontend-critic → opus" "opus" "$(get_model frontend-critic)"
check "security-reviewer → opus" "opus" "$(get_model security-reviewer)"
check "cto → opus" "opus" "$(get_model cto)"
check "docs-writer → claude-fable-5" "claude-fable-5" "$(get_model docs-writer)"
check "pr-sentinel → sonnet" "sonnet" "$(get_model pr-sentinel)"
check "unknown role → default sonnet" "sonnet" "$(get_model this-role-does-not-exist-xyz)"

echo "== kimi effective for routed web-frontend =="
req="$(get_model web-frontend)"
eff="$(effective_model kimi "$req")"
check "web-frontend requested sonnet → effective k3 default" "vendor-default-k3" "$eff"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
