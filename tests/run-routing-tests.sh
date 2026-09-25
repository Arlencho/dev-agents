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
check "codex + claude-opus-5 (ignored pin)" "vendor-default" "$(effective_model codex claude-opus-5)"
check "codex + empty" "vendor-default" "$(effective_model codex "")"
check "codex + native id" "codex-native-model" "$(effective_model codex codex-native-model)"

echo "== routing.yaml: build and gate seats run claude-opus-5 (owner decision 2026-09-14) =="
for role in db-architect test-engineer api-designer devops go-backend web-frontend \
            cto docs-writer pr-sentinel; do
  check "$role → claude-opus-5" "claude-opus-5" "$(get_model "$role")"
done

echo "== routing.yaml: judgment seats run claude-fable-5-1 (owner decision 2026-09-16) =="
for role in security-reviewer backend-critic frontend-critic database-critic api-critic; do
  check "$role → claude-fable-5-1" "claude-fable-5-1" "$(get_model "$role")"
done
check "unknown role → default claude-opus-5" "claude-opus-5" "$(get_model this-role-does-not-exist-xyz)"

echo "== cross-vendor critic seats (non-Anthropic by design) =="
check "devops-critic → grok" "grok" "$(get_provider devops-critic)"
check "devops-critic failover stays non-Anthropic" "grok kimi" "$(echo $(get_failover_chain devops-critic))"
check "devops-critic effective model (alias ignored)" "vendor-default" "$(effective_model grok "$(get_model devops-critic)")"
check "plan-critic → grok" "grok" "$(get_provider plan-critic)"
check "plan-critic never fails over to claude" "grok" "$(echo $(get_failover_chain plan-critic))"

echo "== routing trial 2026-09-13: no producer primary is claude =="
# web-frontend is the kimi seat; every other producer is a grok trial seat.
check "web-frontend primary" "kimi" "$(get_provider web-frontend)"
for role in go-backend db-architect api-designer devops test-engineer mobile investigate docs-writer; do
  check "$role primary" "grok" "$(get_provider "$role")"
done

echo "== producer failover (owner 2026-09-25): primary, other non-Anthropic seat, codex, claude last =="
check "web-frontend failover chain" "kimi grok codex claude" "$(get_failover_chain web-frontend | xargs)"
for role in go-backend db-architect api-designer devops test-engineer mobile investigate docs-writer; do
  check "$role failover chain" "grok kimi codex claude" "$(get_failover_chain "$role" | xargs)"
done
# claude is the last resort only: never a primary, never ahead of codex.
for role in web-frontend go-backend db-architect api-designer devops test-engineer mobile investigate docs-writer; do
  chain="$(get_failover_chain "$role" | xargs)"
  check "$role chain ends with claude" "claude" "${chain##* }"
  check "$role primary is not claude" "no" "$([ "$(get_provider "$role")" = "claude" ] && echo yes || echo no)"
done

echo "== every discipline critic primary is claude, failover claude then grok =="
for role in backend-critic frontend-critic database-critic api-critic; do
  check "$role primary" "claude" "$(get_provider "$role")"
  check "$role failover chain" "claude grok" "$(echo $(get_failover_chain "$role"))"
done

echo "== trust seats carry no failover entry (fall through to default) =="
for role in security-reviewer cto orchestrator; do
  if sed -n '/^provider_failover:/,/^rate_caps:/p' "$ROUTING_CONFIG" \
       | grep -q "^[[:space:]]*${role}:"; then
    got="has entry"
  else
    got="no entry"
  fi
  check "$role failover entry" "no entry" "$got"
done
check "security-reviewer primary stays claude" "claude" "$(get_provider security-reviewer)"

echo "== role charters: model line agrees with workers.yaml + routing.yaml =="
# grok-primary seats pin model: grok (CLI default, like plan-critic already did).
# Every other seat's charter frontmatter matches the model_routing column.
for role_file in "$REPO_DIR"/roles/*.md; do
  role=$(basename "$role_file" .md)
  fm=$(grep -m1 '^model:' "$role_file" | sed 's/model: *//')
  if [ "$(get_provider "$role")" = "grok" ]; then
    want="grok"
  else
    want="$(get_model "$role")"
  fi
  check "$role charter model line" "$want" "$fm"
done

echo "== kimi effective for routed web-frontend =="
req="$(get_model web-frontend)"
eff="$(effective_model kimi "$req")"
check "web-frontend requested claude pin → effective k3 default" "vendor-default-k3" "$eff"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
