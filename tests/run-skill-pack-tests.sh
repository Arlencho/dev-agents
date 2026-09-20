#!/bin/bash
# Ground Truth: the skill packs a seat is listed for are the packs it receives.
#
# Runs scripts/skill-inject.sh for real roles against the real map and pack
# bodies. No network, no vendor CLIs, no dispatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INJECT="$REPO_DIR/scripts/skill-inject.sh"
MAP="$REPO_DIR/config/role-skills.yaml"

pass=0; fail=0
checkf() { # <name> <exit code: 0=pass>
    if [ "$2" -eq 0 ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$1"; fail=$((fail+1))
    fi
}
eq() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n       want=%s\n       got =%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

packs_for() { # <role> -> the packs the map lists, space separated
    grep -E "^[[:space:]]*$1:" "$MAP" | head -1 | sed 's/^[^:]*://' | xargs
}
inject() { # <role> -> the injected block on stdout, warnings on stderr
    DEV_AGENTS_ROOT="$REPO_DIR" "$INJECT" "$1" 2>/dev/null
}

echo "== every listed pack has a body =="
missing=0
for id in $(sed -n '/^roles:/,$p' "$MAP" | sed 's/^[^:]*://' | tr ' ' '\n' | sort -u | grep -v '^$'); do
    [ -f "$REPO_DIR/skills/$id/SKILL.md" ] || { echo "    no body: skills/$id/SKILL.md"; missing=1; }
done
checkf "every pack id in config/role-skills.yaml has a skills/<id>/SKILL.md" $missing

echo ""
echo "== a seat receives every pack it is listed for =="
for role in web-frontend go-backend docs-writer orchestrator; do
    listed=$(packs_for "$role")
    out=$(inject "$role")
    missed=""
    for id in $listed; do
        case "$out" in *"### ${id} v"*) ;; *) missed="$missed $id" ;; esac
    done
    [ -z "$missed" ]; checkf "$role receives all $(echo "$listed" | wc -w | xargs) listed packs (missing:${missed:- none})" $?
done

echo ""
echo "== the count cap does not silently swallow a pack =="
listed_max=0
for line in $(sed -n '/^roles:/,$p' "$MAP" | grep -E '^[[:space:]]+[a-z-]+:' | sed 's/:/ /'); do :; done
while IFS= read -r role; do
    n=$(packs_for "$role" | wc -w | xargs)
    [ "$n" -gt "$listed_max" ] && listed_max=$n
done < <(sed -n '/^roles:/,$p' "$MAP" | grep -E '^[[:space:]]+[a-z0-9-]+:' | sed 's/^[[:space:]]*//;s/:.*//')
cap=$(grep -E '^[[:space:]]*max_packs:' "$MAP" | head -1 | awk '{print $2}')
[ "$listed_max" -le "$cap" ]; checkf "the longest pack list ($listed_max) fits under max_packs ($cap)" $?

warn=$(DEV_AGENTS_ROOT="$REPO_DIR" SKILLS_MAX_PACKS=1 "$INJECT" web-frontend 2>&1 >/dev/null)
case "$warn" in *"more packs than max_packs"*) r=0 ;; *) r=1 ;; esac
checkf "truncating by count warns on stderr instead of dropping in silence" $r

echo ""
echo "== the test-quality pack reaches the seats that write tests =="
for role in web-frontend go-backend db-architect api-designer mobile devops test-engineer investigate; do
    out=$(inject "$role")
    case "$out" in *"### test-quality v"*) r=0 ;; *) r=1 ;; esac
    checkf "$role receives test-quality" $r
done
out=$(inject "backend-critic")
case "$out" in *"### test-quality v"*) r=1 ;; *) r=0 ;; esac
checkf "a critic does not receive it (critics judge tests, producers write them)" $r

echo ""
echo "== the line budget still binds =="
total=$(inject "web-frontend" | wc -l | xargs)
budget=$(grep -E '^[[:space:]]*max_total_lines:' "$MAP" | head -1 | awk '{print $2}')
[ "$total" -le "$budget" ]; checkf "the longest producer block ($total lines) fits the budget ($budget)" $?

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
