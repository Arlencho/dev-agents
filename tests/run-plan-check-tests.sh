#!/bin/bash
# Ground Truth: the fix-round targeted-tests rule.
#   1. Every producer charter carries the producer rule block verbatim, and
#      every critic charter (roles/ plus the provider copies under
#      providers/*/agents/) carries the critic rule block verbatim. The blocks
#      live in tests/fixtures/ so this test cannot drift from the charters.
#   2. The fix-round gate in scripts/dispatch.sh refuses a fix-round plan whose
#      task line asks for the full suite, unless a header allows it. The gate
#      block is EXTRACTED from dispatch.sh (between the fix-round-gate:begin
#      and fix-round-gate:end markers), never restated here.
# No network, no vendor CLIs, no dispatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/dispatch.sh"
PRODUCER_RULE="$REPO_DIR/tests/fixtures/fix-round-producer-rule.md"
CRITIC_RULE="$REPO_DIR/tests/fixtures/fix-round-critic-rule.md"

PRODUCERS="go-backend web-frontend db-architect api-designer devops test-engineer mobile docs-writer"
CRITICS="backend-critic frontend-critic database-critic api-critic plan-critic devops-critic security-reviewer"

pass=0; fail=0
checkf() { # <name> <exit code: 0=pass>
    if [ "$2" -eq 0 ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n' "$1"; fail=$((fail+1))
    fi
}

# contains <file> <rule> [mutate]: exit 0 when the rule block (trailing newline
# stripped) is a substring of the file. With "mutate", one phrase of the block
# is changed first; that copy must NOT be found, which proves the match is real.
contains() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import sys
path, rule, mutate = sys.argv[1], sys.argv[2], sys.argv[3]
block = open(rule, encoding="utf-8").read().rstrip("\n")
if mutate:
    for old, new in (("do not run mutation checks", "do not run any checks"),
                     ("one regression check you name", "every regression check you can find")):
        if old in block:
            block = block.replace(old, new, 1)
            break
text = open(path, encoding="utf-8").read()
sys.exit(0 if block in text else 1)
PY
}

no_long_dash() { # <file>
    python3 -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(1 if any(ord(c) in (0x2013, 0x2014, 0x2015) for c in t) else 0)' "$1"
}

echo "== the fixtures themselves =="
[ -s "$PRODUCER_RULE" ]; checkf "fixture exists and is not empty: tests/fixtures/fix-round-producer-rule.md" $?
[ -s "$CRITIC_RULE" ];   checkf "fixture exists and is not empty: tests/fixtures/fix-round-critic-rule.md" $?
no_long_dash "$PRODUCER_RULE"; checkf "producer fixture carries no long dash (U+2013, U+2014, U+2015)" $?
no_long_dash "$CRITIC_RULE";   checkf "critic fixture carries no long dash (U+2013, U+2014, U+2015)" $?

# The blocks read the same on every seat, so they name no vendor and no model.
# The forbidden words are read out of the repo (providers/<vendor>/ and every
# model: value in roles/*.md front matter), never spelled here.
for rule in "$PRODUCER_RULE" "$CRITIC_RULE"; do
    python3 - "$REPO_DIR" "$rule" <<'PY'
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
    checkf "$(basename "$rule") names no vendor or model (words read from providers/ and roles/ front matter)" $?
done

echo ""
echo "== every producer charter carries the producer block verbatim =="
for r in $PRODUCERS; do
    f="$REPO_DIR/roles/$r.md"
    [ -f "$f" ]; checkf "roles/$r.md exists" $?
    contains "$f" "$PRODUCER_RULE"; checkf "roles/$r.md contains the producer rule block verbatim" $?
    ! contains "$f" "$PRODUCER_RULE" mutate; checkf "roles/$r.md does not match a one-phrase mutation (match is real)" $?
done

echo ""
echo "== every critic charter carries the critic block verbatim =="
for r in $CRITICS; do
    f="$REPO_DIR/roles/$r.md"
    [ -f "$f" ]; checkf "roles/$r.md exists" $?
    contains "$f" "$CRITIC_RULE"; checkf "roles/$r.md contains the critic rule block verbatim" $?
    ! contains "$f" "$CRITIC_RULE" mutate; checkf "roles/$r.md does not match a one-phrase mutation (match is real)" $?
done

echo ""
echo "== provider copies carry the critic block verbatim too =="
found_copy=0
for r in $CRITICS; do
    for p in "$REPO_DIR"/providers/*/agents/"$r.md"; do
        [ -f "$p" ] || continue
        found_copy=1
        contains "$p" "$CRITIC_RULE"; checkf "${p#"$REPO_DIR"/} contains the critic rule block verbatim" $?
    done
done
[ "$found_copy" -eq 1 ]; checkf "at least one provider copy exists under providers/*/agents" $?

# ----------------------------------------------------------------------
# The dispatch gate. Extract the marked block and drive it with plan files,
# mirroring how dispatch.sh itself reads tasks (drop comments and blanks).
# ----------------------------------------------------------------------
echo ""
echo "== fix-round gate in scripts/dispatch.sh =="
GATE_BLOCK=$(sed -n '/# ---- fix-round-gate:begin/,/# ---- fix-round-gate:end/p' "$DISPATCH")
if [ -z "$GATE_BLOCK" ]; then
    echo "  FAIL could not extract the fix-round-gate block from scripts/dispatch.sh"
    exit 1
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

HARNESS="$SANDBOX/gate-harness.sh"
{
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo 'RED= ; GREEN= ; YELLOW= ; NC='
    printf '%s\n' "$GATE_BLOCK"
    cat <<'EOF'
plan="$1"
tasks=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -z "$line" ] && continue
    tasks+=("$line")
done < "$plan"
fix_round_gate "$plan" ${tasks[@]+"${tasks[@]}"}
EOF
} > "$HARNESS"
chmod +x "$HARNESS"

gate() { # <plan file> -> sets GATE_RC and GATE_OUT
    GATE_OUT=$("$HARNESS" "$1" 2>&1)
    GATE_RC=$?
}

# A fix-round plan (FIX-ROUND header) whose task line says `make test`.
cat > "$SANDBOX/fix-make-test.plan" <<'EOF'
# Payments W2 fix round
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
1 | go-backend | patch the checkout handler, VERIFY: make test | feat/payments-w2-fix
EOF

# The same plan with the owner override header.
cat > "$SANDBOX/fix-allow.plan" <<'EOF'
# Payments W2 fix round
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
# ALLOW-FULL-SUITE
1 | go-backend | patch the checkout handler, VERIFY: make test | feat/payments-w2-fix
EOF

# A round 1 plan whose task line says `make test`.
cat > "$SANDBOX/round1-make-test.plan" <<'EOF'
# Payments W3, round 1
1 | go-backend | build the refund handler, VERIFY: make test | feat/payments-w3
EOF

gate "$SANDBOX/fix-make-test.plan"
[ "$GATE_RC" -ne 0 ]; checkf "fix-round plan with 'make test' is refused" $?
printf '%s' "$GATE_OUT" | grep -qF '1 | go-backend | patch the checkout handler, VERIFY: make test | feat/payments-w2-fix'
checkf "the stop message names the task line" $?
printf '%s' "$GATE_OUT" | grep -qi 'rule: in a fix round'
checkf "the stop message names the rule" $?

gate "$SANDBOX/fix-allow.plan"
[ "$GATE_RC" -eq 0 ]; checkf "the same plan with ALLOW-FULL-SUITE passes" $?

gate "$SANDBOX/round1-make-test.plan"
[ "$GATE_RC" -eq 0 ]; checkf "a round 1 plan with 'make test' passes" $?

echo ""
echo "== gate edge cases =="

# Fix suffix on the plan basename marks a fix round without any header.
cat > "$SANDBOX/payments-w2-fix1.plan" <<'EOF'
# follow-up on the payments wave
1 | go-backend | patch the checkout handler, VERIFY: make test | feat/payments-w2-fix
EOF
gate "$SANDBOX/payments-w2-fix1.plan"
[ "$GATE_RC" -ne 0 ]; checkf "a -fix1 plan suffix marks a fix round (refused with make test)" $?

# A round number above 1 in the header marks a fix round.
cat > "$SANDBOX/round3.plan" <<'EOF'
# Payments W2, critic round 3 findings
1 | go-backend | close the round 3 findings, VERIFY: make test | feat/payments-w2-fix
EOF
gate "$SANDBOX/round3.plan"
[ "$GATE_RC" -ne 0 ]; checkf "a header naming round 3 marks a fix round (refused with make test)" $?

# "final round" on the task line exempts that line.
cat > "$SANDBOX/fix-final-round.plan" <<'EOF'
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
1 | go-backend | patch the checkout handler, VERIFY: make test (final round before merge) | feat/payments-w2-fix
EOF
gate "$SANDBOX/fix-final-round.plan"
[ "$GATE_RC" -eq 0 ]; checkf "a full-suite VERIFY naming the final round passes" $?

# A targeted VERIFY in a fix round is what the rule wants.
cat > "$SANDBOX/fix-targeted.plan" <<'EOF'
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
1 | go-backend | patch the checkout handler, VERIFY: tests/run-plan-check-tests.sh only | feat/payments-w2-fix
EOF
gate "$SANDBOX/fix-targeted.plan"
[ "$GATE_RC" -eq 0 ]; checkf "a fix round with a targeted test file passes" $?

# The words "full suite" are refused even without make test.
cat > "$SANDBOX/fix-full-suite.plan" <<'EOF'
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
1 | test-engineer | close the findings, VERIFY: run the full suite | feat/payments-w2-fix
EOF
gate "$SANDBOX/fix-full-suite.plan"
[ "$GATE_RC" -ne 0 ]; checkf "a fix round asking for the words 'full suite' is refused" $?

# The whole tests directory runner (a tests/ glob) is refused.
cat > "$SANDBOX/fix-tests-glob.plan" <<'EOF'
# FIX-ROUND: 1 of wave-plans/payments-w2.plan
1 | test-engineer | close the findings, VERIFY: tests/run-*.sh | feat/payments-w2-fix
EOF
gate "$SANDBOX/fix-tests-glob.plan"
[ "$GATE_RC" -ne 0 ]; checkf "a fix round asking for the whole tests directory runner is refused" $?

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
