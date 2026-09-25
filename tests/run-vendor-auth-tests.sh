#!/usr/bin/env bash
# Vendor auth preflight tests - no real network logins.
# Uses tests/shims on PATH + temp HOME for kimi/grok credential files.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIMS="$SCRIPT_DIR/shims"
CHECK="$REPO_DIR/scripts/vendor-auth-check.sh"

pass=0; fail=0
check() {
    if [ "$2" -eq "$3" ]; then
        printf '  ok   %-56s (exit %s)\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-56s (want %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT

# Fake kimi + grok session material under temp HOME
mkdir -p "$TMPHOME/.kimi-code/credentials" "$TMPHOME/.kimi-code/oauth" "$TMPHOME/.grok"
echo '{"token":"fake"}' > "$TMPHOME/.kimi-code/credentials/kimi-code.json"
echo fake-oauth > "$TMPHOME/.kimi-code/oauth/kimi-code"
echo '{"https://auth.x.ai::test":{"access_token":"x"}}' > "$TMPHOME/.grok/auth.json"

export HOME="$TMPHOME"
export KIMI_CODE_HOME="$TMPHOME/.kimi-code"
export GROK_HOME="$TMPHOME/.grok"
export VENDOR_AUTH_TIMEOUT_SEC=5

echo "== vendor-auth: all ok with shims + fake credentials =="
got=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --vendors claude,kimi,grok,codex >/dev/null 2>&1; echo $?)
check "all vendors ok" 0 "$got"

echo "== vendor-auth: codex login status =="
got=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --vendors codex >/dev/null 2>&1; echo $?)
check "codex logged in ok" 0 "$got"
got=$(SHIM_MODE=noauth PATH="$SHIMS:$PATH" "$CHECK" --vendors codex >/dev/null 2>&1; echo $?)
check "codex not logged in fails" 1 "$got"
out=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" 2>&1) || true
if echo "$out" | grep -q codex; then
    echo "  ok   codex is in the default vendor set"; pass=$((pass+1))
else
    echo "  FAIL codex missing from ALL_VENDORS"; fail=$((fail+1))
fi

echo "== vendor-auth: claude loggedIn=false =="
got=$(SHIM_MODE=noauth PATH="$SHIMS:$PATH" "$CHECK" --vendors claude >/dev/null 2>&1; echo $?)
check "claude noauth fails" 1 "$got"

echo "== vendor-auth: claude oauth expired message =="
got=$(SHIM_MODE=fail PATH="$SHIMS:$PATH" "$CHECK" --vendors claude >/dev/null 2>&1; echo $?)
check "claude auth fail fails" 1 "$got"

echo "== vendor-auth: kimi missing credentials =="
rm -rf "$TMPHOME/.kimi-code/credentials" "$TMPHOME/.kimi-code/oauth"
got=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --vendors kimi >/dev/null 2>&1; echo $?)
check "kimi no creds fails" 1 "$got"
# restore for later
mkdir -p "$TMPHOME/.kimi-code/credentials" "$TMPHOME/.kimi-code/oauth"
echo '{"token":"fake"}' > "$TMPHOME/.kimi-code/credentials/kimi-code.json"
echo fake-oauth > "$TMPHOME/.kimi-code/oauth/kimi-code"

echo "== vendor-auth: grok missing auth.json =="
rm -f "$TMPHOME/.grok/auth.json"
got=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --vendors grok >/dev/null 2>&1; echo $?)
check "grok no auth fails" 1 "$got"
echo '{"https://auth.x.ai::test":{"access_token":"x"}}' > "$TMPHOME/.grok/auth.json"

echo "== vendor-auth: binary absent =="
got=$(PATH="/usr/bin:/bin" "$CHECK" --vendors claude >/dev/null 2>&1; echo $?)
check "claude binary-absent fails" 1 "$got"

echo "== vendor-auth: --plan resolves web-frontend → codex (+failover) =="
PLAN=$(mktemp)
cat > "$PLAN" <<'EOF'
1 | web-frontend | smoke only | feat/smoke
EOF
# success path with credentials + shim
out=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --plan "$PLAN" 2>&1)
ec=$?
if echo "$out" | grep -q codex && [ "$ec" -eq 0 ]; then
    echo "  ok   plan resolves and checks codex (exit 0)"; pass=$((pass+1))
else
    echo "  FAIL plan web-frontend (exit $ec)"; echo "$out" | head -20; fail=$((fail+1))
fi
# Every failover provider is preflighted after the codex primary.
if echo "$out" | grep -q kimi && echo "$out" | grep -q grok && echo "$out" | grep -q claude; then
    echo "  ok   plan preflights the kimi, grok and claude failover rungs"; pass=$((pass+1))
else
    echo "  FAIL plan did not preflight kimi + grok + claude:"; echo "$out" | head -20; fail=$((fail+1))
fi
rm -f "$PLAN"

echo "== vendor-auth: --json overall ok =="
json=$(SHIM_MODE=success PATH="$SHIMS:$PATH" "$CHECK" --vendors claude --json 2>/dev/null) || true
if echo "$json" | grep -q '"overall":"ok"'; then
    echo "  ok   json overall ok"; pass=$((pass+1))
else
    echo "  FAIL json overall: $json"; fail=$((fail+1))
fi

echo "== ratecap-patterns: claude oauth expired classed auth =="
# Source lib and classify a fake tail (same as run_and_classify path)
PAT="$REPO_DIR/config/ratecap-patterns.conf"
if grep -qE 'claude\|auth\|oauth session expired' "$PAT" \
   && grep -qE 'claude\|auth\|failed to authenticate' "$PAT"; then
    echo "  ok   oauth expired patterns present"; pass=$((pass+1))
else
    echo "  FAIL oauth patterns missing from ratecap-patterns.conf"; fail=$((fail+1))
fi

echo "== ratecap-patterns: codex rows cover cap, quota, 429, 402, balance and auth =="
for want in 'codex\|ratecap\|HTTP\.\*429' 'codex\|ratecap\|.*usage limit' 'codex\|ratecap\|quota' \
            'codex\|ratecap\|402 Payment Required' 'codex\|ratecap\|usage balance' \
            'codex\|auth\|not logged in' 'codex\|auth\|codex login' 'codex\|auth\|unauthorized' \
            'codex\|limit\|HTTP\.\*401'; do
    if grep -qE "^$want" "$PAT"; then
        echo "  ok   pattern present: $want"; pass=$((pass+1))
    else
        echo "  FAIL pattern missing: $want"; fail=$((fail+1))
    fi
done

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
