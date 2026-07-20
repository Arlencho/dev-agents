#!/usr/bin/env bash
# Assemble L2 skill pack text for a role (stdout). Does not touch preamble (L3).
#
# Usage: skill-inject.sh <role> [product-repo-path]
#
# Env (optional):
#   DEV_AGENTS_ROOT  — override path to this repo (default: parent of scripts/)
#   SKILLS_MAX_PACKS / SKILLS_MAX_LINES — override role-skills.yaml defaults
#
# Exit 0 always (missing config → empty / warning on stderr) so dispatch never blocks.

set -euo pipefail

ROLE="${1:?usage: skill-inject.sh <role> [product-repo-path]}"
PRODUCT_REPO="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEV_AGENTS_ROOT="${DEV_AGENTS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MAP_FILE="$DEV_AGENTS_ROOT/config/role-skills.yaml"
GLOBAL_SKILLS="$DEV_AGENTS_ROOT/skills"

if [ ! -f "$MAP_FILE" ]; then
    echo "skill-inject: no role-skills.yaml at $MAP_FILE" >&2
    exit 0
fi

# defaults
MAX_PACKS=$(grep -E '^[[:space:]]*max_packs:' "$MAP_FILE" | head -1 | awk '{print $2}')
MAX_LINES=$(grep -E '^[[:space:]]*max_total_lines:' "$MAP_FILE" | head -1 | awk '{print $2}')
MAX_PACKS="${SKILLS_MAX_PACKS:-${MAX_PACKS:-4}}"
MAX_LINES="${SKILLS_MAX_LINES:-${MAX_LINES:-400}}"

# packs line for role (space-separated after role:)
packs_line=$(grep -E "^[[:space:]]*${ROLE}:" "$MAP_FILE" | head -1 || true)
if [ -z "$packs_line" ]; then
    packs_line=$(grep -E '^[[:space:]]*default:' "$MAP_FILE" | head -1 || true)
fi
if [ -z "$packs_line" ]; then
    exit 0
fi

# strip "role:" prefix
packs="${packs_line#*:}"
packs="$(echo "$packs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

# truncate to max_packs
count=0
selected=()
for p in $packs; do
    count=$((count + 1))
    if [ "$count" -gt "$MAX_PACKS" ]; then
        break
    fi
    selected+=("$p")
done

if [ "${#selected[@]}" -eq 0 ]; then
    exit 0
fi

out="## Skill packs (L2)
# Source: config/role-skills.yaml + skills/*/SKILL.md (project overrides global by id)
# Authority: charter > project skill > global skill > case file (preamble) > task
"

total_lines=0
for id in "${selected[@]}"; do
    body_file=""
    scope="global"
    if [ -n "$PRODUCT_REPO" ] && [ -f "$PRODUCT_REPO/skills/$id/SKILL.md" ]; then
        body_file="$PRODUCT_REPO/skills/$id/SKILL.md"
        scope="project"
    elif [ -f "$GLOBAL_SKILLS/$id/SKILL.md" ]; then
        body_file="$GLOBAL_SKILLS/$id/SKILL.md"
        scope="global"
    else
        echo "skill-inject: WARNING missing pack '$id' for role $ROLE" >&2
        continue
    fi

    # strip YAML frontmatter (--- ... ---)
    body=$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm!=1' "$body_file")
    # optional max_lines from frontmatter
    pack_max=$(grep -E '^max_lines:' "$body_file" | head -1 | awk '{print $2}' || true)
    version=$(grep -E '^version:' "$body_file" | head -1 | awk '{print $2}' || echo "?")
    if [ -n "$pack_max" ] && [ "$pack_max" -gt 0 ] 2>/dev/null; then
        body=$(printf '%s\n' "$body" | head -n "$pack_max")
    fi

    blines=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
    if [ $((total_lines + blines)) -gt "$MAX_LINES" ]; then
        echo "skill-inject: WARNING budget $MAX_LINES lines hit; skipping remaining packs" >&2
        break
    fi
    total_lines=$((total_lines + blines))

    out+="
### ${id} v${version} [${scope}]

${body}
"
done

printf '%s\n' "$out"
exit 0
