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

# get_model / get_provider / get_failover_chain come from the same library
# dispatch.sh and flow.sh use. This file used to carry a hand-rolled "mirror" of
# get_model, which meant the test could pass while dispatch resolved differently.
# shellcheck source=../scripts/config-lib.sh
source "$REPO_DIR/scripts/config-lib.sh"

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

echo "== cross-vendor critic seats (non-Anthropic by design) =="
check "devops-critic → grok" "grok" "$(get_provider devops-critic)"
check "devops-critic failover stays non-Anthropic" "grok kimi" "$(echo $(get_failover_chain devops-critic))"
check "devops-critic effective model (alias ignored)" "vendor-default" "$(effective_model grok "$(get_model devops-critic)")"
check "plan-critic → grok" "grok" "$(get_provider plan-critic)"
check "plan-critic never fails over to claude" "grok" "$(echo $(get_failover_chain plan-critic))"
check "devops producer stays on claude" "claude" "$(get_provider devops)"

echo "== kimi effective for routed web-frontend =="
req="$(get_model web-frontend)"
eff="$(effective_model kimi "$req")"
check "web-frontend requested sonnet → effective k3 default" "vendor-default-k3" "$eff"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
