#!/bin/bash
# Ground Truth: the critic verdict rule is one block, byte for byte, in every
# critic charter, in CLAUDE.md and in docs/org-chart.md. The block's four words
# are the ones scripts/desk_live.py actually parses, and the block carries no
# long dash and no vendor name. No network, no vendor CLIs, no writes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RULE="$REPO_DIR/tests/fixtures/critic-verdict-rule.md"

CRITICS="backend-critic frontend-critic api-critic database-critic plan-critic devops-critic security-reviewer"
COPIES="CLAUDE.md docs/org-chart.md"

pass=0; fail=0
checkf() { # <name> <exit code: 0=pass>
    if [ "$2" -eq 0 ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$1"; fail=$((fail+1))
    fi
}

# contains <file> <rule> [mutate]: exit 0 when the rule block (trailing newline
# stripped) is a substring of the file. With "mutate", one word of the block is
# changed first; that copy must NOT be found, which proves the match is real.
contains() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import sys
path, rule, mutate = sys.argv[1], sys.argv[2], sys.argv[3]
block = open(rule, encoding="utf-8").read().rstrip("\n")
if mutate:
    block = block.replace("never BLOCK-FIX", "never BLOCK-CLOSE", 1)
text = open(path, encoding="utf-8").read()
sys.exit(0 if block in text else 1)
PY
}

echo "== the fixture itself =="
[ -s "$RULE" ]; checkf "fixture exists and is not empty: tests/fixtures/critic-verdict-rule.md" $?

for word in BLOCK-FIX BLOCK-ESCALATE BLOCK-CLOSE SAFE-TO-MERGE; do
    grep -q -- "\*\*$word\*\*" "$RULE"; checkf "fixture defines $word" $?
done
for reason in "scope grew" "PRD is wrong or silent" "pre-existing defect found" "cheaper path exists" "security judgment"; do
    grep -q -- "\`$reason\`" "$RULE"; checkf "fixture lists escalation reason: $reason" $?
done
grep -q "posts BLOCK-ESCALATE, never BLOCK-FIX" "$RULE"
checkf "fixture states: fixable defect plus judgment case is BLOCK-ESCALATE, never BLOCK-FIX" $?

python3 -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(1 if any(ord(c) in (0x2013, 0x2014, 0x2015) for c in t) else 0)' "$RULE"
checkf "fixture carries no long dash (U+2013, U+2014, U+2015)" $?

# The block must read the same on every seat, so it names no vendor and no
# model. The forbidden words are read out of the repo (providers/<vendor>/ and
# every model: value in roles/*.md front matter), never spelled here.
python3 - "$REPO_DIR" "$RULE" <<'PY'
import glob, os, re, sys
repo, rule = sys.argv[1], sys.argv[2]
words = set()
for d in glob.glob(os.path.join(repo, "providers", "*", "")):
    words.add(os.path.basename(d.rstrip("/")).lower())
for f in glob.glob(os.path.join(repo, "roles", "*.md")):
    parts = open(f, encoding="utf-8").read().split("---", 2)
    if len(parts) < 3:
        continue
    for m in re.finditer(r"^model:\s*(\S+)", parts[1], re.M):
        value = m.group(1).strip("'\"").lower()
        words.add(value)
        words.add(value.split("-")[0])
words -= {"", "n/a", "none", "default"}
text = open(rule, encoding="utf-8").read().lower()
hits = sorted(w for w in words if re.search(r"\b%s\b" % re.escape(w), text))
if hits:
    print("    fixture names:", ", ".join(hits))
sys.exit(1 if hits else 0)
PY
checkf "fixture names no vendor or model (words read from providers/ and roles/ front matter)" $?

# The words the block teaches must be the words the runner reads.
python3 - "$REPO_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import desk_live
want_block = {"BLOCK-FIX", "BLOCK-ESCALATE", "BLOCK-CLOSE"}
want_safe = {"SAFE-TO-MERGE"}
ok = want_block <= desk_live.BLOCK_VERDICTS and want_safe <= desk_live.SAFE_VERDICTS
ok = ok and desk_live.first_line_verdict("CRITIC DEVOPS ROUND 2: BLOCK-ESCALATE") == "BLOCK-ESCALATE"
ok = ok and desk_live.first_line_verdict("CRITIC DEVOPS SAFE-TO-MERGE") == "SAFE-TO-MERGE"
ok = ok and desk_live.first_line_verdict("the last review said BLOCK-FIX but this is not a verdict") is None
sys.exit(0 if ok else 1)
PY
checkf "the four words are in scripts/desk_live.py BLOCK_VERDICTS / SAFE_VERDICTS and the first-line form parses" $?

echo ""
echo "== every critic charter carries the block verbatim =="
for r in $CRITICS; do
    f="$REPO_DIR/roles/$r.md"
    [ -f "$f" ]; checkf "roles/$r.md exists" $?
    contains "$f" "$RULE"; checkf "roles/$r.md contains the rule block verbatim" $?
    ! contains "$f" "$RULE" mutate; checkf "roles/$r.md does not match a one-word mutation (match is real)" $?
done

echo ""
echo "== the same block in CLAUDE.md and the docs =="
for c in $COPIES; do
    f="$REPO_DIR/$c"
    [ -f "$f" ]; checkf "$c exists" $?
    contains "$f" "$RULE"; checkf "$c contains the rule block verbatim" $?
done

echo ""
echo "== provider copies mirror roles/ (make sync) =="
for r in $CRITICS; do
    for p in "$REPO_DIR"/providers/*/agents/"$r.md"; do
        [ -f "$p" ] || continue
        cmp -s "$REPO_DIR/roles/$r.md" "$p"
        checkf "${p#"$REPO_DIR"/} is byte-identical to roles/$r.md" $?
    done
done

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
