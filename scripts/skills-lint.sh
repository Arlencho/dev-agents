#!/usr/bin/env bash
# Lint fleet skill packs (anti-confabulation + hygiene).
# Usage: skills-lint.sh [skills-root]
# Exit 1 on failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${1:-$REPO_ROOT/skills}"
FAIL=0

err() { echo "skills-lint: FAIL: $*" >&2; FAIL=1; }
ok()  { echo "skills-lint: ok: $*"; }

if [ ! -d "$ROOT" ]; then
    err "skills root missing: $ROOT"
    exit 1
fi

shopt -s nullglob
packs=("$ROOT"/*/SKILL.md)
if [ "${#packs[@]}" -eq 0 ]; then
    err "no SKILL.md packs under $ROOT"
    exit 1
fi

for f in "${packs[@]}"; do
    id=$(basename "$(dirname "$f")")
    [ "$id" = "_candidates" ] && continue

    if ! grep -qE '^id:' "$f"; then
        err "$id: missing frontmatter id:"
    fi
    if ! grep -qE '^version:[[:space:]]*[0-9]+' "$f"; then
        err "$id: version must be integer (version: N)"
    fi

    body=$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm!=1' "$f")
    lines=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
    maxl=$(grep -E '^max_lines:' "$f" | head -1 | awk '{print $2}' || true)
    maxl="${maxl:-120}"
    if [ "$lines" -gt "$maxl" ]; then
        err "$id: body $lines lines > max_lines $maxl"
    fi

    # Credential paths as instructions (allow "never invent Keychain/credentials" anti-patterns)
    while IFS= read -r line; do
        echo "$line" | grep -qiE '(\.credentials\.json|OPENAI_API_KEY|ANTHROPIC_API_KEY)' || continue
        echo "$line" | grep -qiE '(never|do not|don.t|invent|not |anti-pattern|forbidden)' && continue
        err "$id: appears to instruct a credential/auth path: $line"
    done <<< "$body"

    # Checklist items (- [ ] ...) should include [ev: ...]
    while IFS= read -r line; do
        case "$line" in
            "- [ ]"*|"- [x]"*|"- [X]"*)
                if ! echo "$line" | grep -q '\[ev:'; then
                    err "$id: checklist item missing [ev: …]: $line"
                fi
                ;;
        esac
    done <<< "$body"

    # Cited repo-relative paths must exist
    while IFS= read -r cite; do
        path=$(echo "$cite" | sed -n 's/.*\[ev: \([^]]*\)\].*/\1/p')
        path=$(echo "$path" | sed 's/[[:space:]]*§.*//;s/[[:space:]]*$//')
        [ -z "$path" ] && continue
        case "$path" in
            http*|learning*|SHA*|v[0-9]*) continue ;;
        esac
        # drop line anchors after #
        file_part="${path%%#*}"
        file_part=$(echo "$file_part" | sed 's/[[:space:]]*$//')
        # only check paths that look like repo files
        case "$file_part" in
            *.*)
                if [ ! -e "$REPO_ROOT/$file_part" ] && [ ! -e "$file_part" ]; then
                    err "$id: cited path not found: $file_part"
                fi
                ;;
        esac
    done < <(printf '%s\n' "$body" | grep -oE '\[ev: [^]]+\]' || true)

    ok "$id ($lines lines)"
done

if [ "$FAIL" -ne 0 ]; then
    echo "skills-lint: FAILED" >&2
    exit 1
fi
echo "skills-lint: all packs OK"
exit 0
