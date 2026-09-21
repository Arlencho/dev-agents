#!/bin/bash
# Ground Truth: plan text is prose written by a person and must survive parsing
# verbatim.
#
# This exists because three dispatches were lost to "xargs: unterminated
# quote". The parser trimmed whitespace with `echo "$x" | xargs`, and xargs
# parses its input as shell words, so one apostrophe in a task description
# ("the day's data") aborted the whole run before a single seat started. The
# failure was silent about its cause and looked like a dispatch bug rather than
# a plan one.
#
# The trim helper is EXTRACTED from scripts/dispatch.sh rather than restated
# here, so this test cannot drift from the code it guards.
# No network, no vendor CLIs, no dispatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/scripts/dispatch.sh"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"; pass=$((pass+1))
    else
        printf '  FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

echo "Plan parsing: text survives verbatim"

# Extract trim() from dispatch.sh and define it here.
eval "$(sed -n '/^trim() {$/,/^}$/p' "$DISPATCH")"
if ! declare -f trim >/dev/null; then
    echo "  FAIL could not extract trim() from dispatch.sh"
    exit 1
fi

check "plain text"                "hello"              "$(trim '  hello  ')"
check "apostrophe survives"       "the day's data"     "$(trim "  the day's data  ")"
check "two apostrophes survive"   "it's the app's job" "$(trim "it's the app's job")"
check "double quote survives"     'say "no" clearly'   "$(trim '  say "no" clearly  ')"
check "backslash survives"        'a\b'                "$(trim '  a\b  ')"
check "inner spacing untouched"   "a   b"              "$(trim '  a   b  ')"
check "tabs trimmed"              "x"                  "$(trim "$(printf '\tx\t')")"
check "empty stays empty"         ""                   "$(trim '   ')"

# The parse path must not reintroduce the xargs idiom.
echo "Parsing does not shell-parse plan text"
if grep -nE '\| *xargs\)' "$DISPATCH" >/dev/null 2>&1; then
    printf '  FAIL dispatch.sh still trims with xargs:\n'
    grep -nE '\| *xargs\)' "$DISPATCH" | sed 's/^/    /'
    fail=$((fail+1))
else
    printf '  ok   no `| xargs)` trim remains in dispatch.sh\n'; pass=$((pass+1))
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
