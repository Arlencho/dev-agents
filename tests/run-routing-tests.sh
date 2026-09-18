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
web_primary=$(get_provider web-frontend)
check "web-frontend primary is kimi or grok" "yes" "$(if [ "$web_primary" = kimi ] || [ "$web_primary" = grok ]; then echo yes; else echo no; fi)"
for role in go-backend db-architect api-designer devops test-engineer mobile investigate docs-writer; do
  check "$role primary" "grok" "$(get_provider "$role")"
done

echo "== routing trial 2026-09-13: no producer failover chain contains claude =="
for role in web-frontend go-backend db-architect api-designer devops test-engineer mobile investigate docs-writer; do
  chain="$(get_failover_chain "$role")"
  case " $chain " in
    *" claude "*) got="contains claude: $chain" ;;
    *)            got="claude-free" ;;
  esac
  check "$role failover chain" "claude-free" "$got"
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
