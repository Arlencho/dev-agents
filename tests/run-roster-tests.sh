#!/bin/bash
# Ground Truth: roster integrity: producer/critic pairing, the heterogeneity
# invariant, and vendor ownership of provider agent copies.
# No network, no vendor CLIs, no writes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/config-lib.sh
source "$REPO_DIR/scripts/config-lib.sh"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %-58s → %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-58s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}
checkf() { # <name> <condition-already-evaluated: 0=pass>
    if [ "$2" -eq 0 ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$1"; fail=$((fail+1))
    fi
}

# ----------------------------------------------------------------------
# The pairing map is read out of flow.sh rather than restated here, so this
# test cannot drift from the script that actually dispatches the critic.
# ----------------------------------------------------------------------
PAIRS=$(sed -n '/^declare -A CRITIC_OF=(/,/^)/p' "$REPO_DIR/scripts/flow.sh" \
        | sed -n 's/^[[:space:]]*\[\([a-z-]*\)\]=\([a-z-]*\).*/\1 \2/p')

echo "== pairing map (from scripts/flow.sh CRITIC_OF) =="
[ -n "$PAIRS" ] || { echo "  FAIL could not parse CRITIC_OF"; exit 1; }
while read -r producer critic; do
    [ -n "$producer" ] || continue
    [ -f "$REPO_DIR/roles/$producer.md" ]; checkf "producer '$producer' has a charter in roles/" $?
    [ -f "$REPO_DIR/roles/$critic.md" ];   checkf "critic   '$critic' has a charter in roles/" $?
done <<< "$PAIRS"

# ----------------------------------------------------------------------
# Heterogeneity invariant (docs/org-chart.md § Heterogeneity invariant):
# "Every Critic uses a different model from its paired producer."
#
# A pair is heterogeneous if the VENDOR differs or the model TIER differs.
# Anything else is a same-seat pair and must be listed here with a reason, so
# that an exception is a deliberate, visible decision rather than a silent one.
# ----------------------------------------------------------------------
exception_reason() { # <producer>
    case "$1" in
        db-architect)
            # docs/org-chart.md § Database exception: irreversibility premium on
            # migrations buys reasoning depth at the cost of cross-model checking.
            echo "DOCUMENTED: DB exception, org-chart.md" ;;
        api-designer)
            # Not covered by any documented exception. org-chart.md states the DB
            # exception "applies only to the Database pair. All other
            # producer-critic pairs MUST cross models."
            echo "UNRESOLVED: undocumented same-seat pair" ;;
        *) echo "" ;;
    esac
}

echo ""
echo "== heterogeneity invariant =="
exceptions_seen=""
while read -r producer critic; do
    [ -n "$producer" ] || continue
    pv=$(get_provider "$producer"); cv=$(get_provider "$critic")
    pm=$(get_model "$producer");    cm=$(get_model "$critic")
    reason=$(exception_reason "$producer")
    if [ "$pv" != "$cv" ] || [ "$pm" != "$cm" ]; then
        if [ -n "$reason" ]; then
            printf '  FAIL %s x %s is heterogeneous but still listed as an exception: remove it\n' "$producer" "$critic"
            fail=$((fail+1))
        else
            printf '  ok   %-14s(%s/%s) x %-16s(%s/%s)\n' "$producer" "$pv" "$pm" "$critic" "$cv" "$cm"
            pass=$((pass+1))
        fi
    elif [ -n "$reason" ]; then
        printf '  ok   %-14s(%s/%s) x %-16s(%s/%s)  [%s]\n' "$producer" "$pv" "$pm" "$critic" "$cv" "$cm" "$reason"
        pass=$((pass+1))
        exceptions_seen="$exceptions_seen$producer x $critic: $reason"$'\n'
    else
        printf '  FAIL %-14s(%s/%s) x %-16s(%s/%s)  same vendor AND same tier, with no recorded exception\n' \
            "$producer" "$pv" "$pm" "$critic" "$cv" "$cm"
        fail=$((fail+1))
    fi
done <<< "$PAIRS"

# ----------------------------------------------------------------------
# Vendor ownership: providers/claude/agents/<role>.md exists if and only if
# claude can actually run that role. A copy for a vendor that cannot run the
# seat registers an agent pinned to a model that vendor cannot resolve.
# ----------------------------------------------------------------------
echo ""
echo "== vendor ownership of providers/claude/agents =="
for role_file in "$REPO_DIR"/roles/*.md; do
    role=$(basename "$role_file" .md)
    providers=$(role_providers "$role")
    copy="$REPO_DIR/providers/claude/agents/$role.md"
    if echo " $providers " | grep -q " claude "; then
        [ -f "$copy" ]; checkf "$role runs on claude → has a provider copy" $?
    else
        [ ! -f "$copy" ]; checkf "$role runs on [$providers] → has NO claude copy" $?
    fi
done

# ----------------------------------------------------------------------
# Charter frontmatter vs routing.yaml. `claude --agent <role>` reads the tier
# out of the charter's own frontmatter, while dispatch.sh passes the tier from
# routing.yaml. When they disagree the same seat runs on two different models
# depending on which entry point fired. docs-writer was live on haiku this way,
# a tier routing.yaml itself calls "not used for fleet seats".
# ----------------------------------------------------------------------
echo ""
echo "== charter frontmatter agrees with routing.yaml =="
for role_file in "$REPO_DIR"/roles/*.md; do
    role=$(basename "$role_file" .md)
    [ "$(get_provider "$role")" = "claude" ] || continue
    fm=$(grep -m1 '^model:' "$role_file" | sed 's/model: *//')
    check "$role frontmatter matches routing.yaml" "$(get_model "$role")" "$fm"
done

# ----------------------------------------------------------------------
echo ""
echo "== cross-vendor critic seats keep a non-Anthropic failover =="
for critic in devops-critic plan-critic; do
    chain=$(role_providers "$critic")
    if echo " $chain " | grep -q " claude "; then
        printf '  FAIL %s may fall back to claude (chain: %s), a same-vendor pair\n' "$critic" "$chain"
        fail=$((fail+1))
    else
        printf '  ok   %-16s chain stays non-Anthropic: %s\n' "$critic" "$chain"; pass=$((pass+1))
    fi
done

if [ -n "$exceptions_seen" ]; then
    echo ""
    echo "== recorded heterogeneity exceptions (these are NOT passing pairs) =="
    printf '%s' "$exceptions_seen" | sed 's/^/  /'
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
