#!/usr/bin/env bash
set -euo pipefail

# flow.sh — deterministic dev pipeline (CrewAI Flows-style) with a HUMAN merge gate.
#
# One explicit, legible pipeline instead of charter-soup + manual dispatch.
# Cost control is built into the shape: the expensive Opus critic fires ONLY on
# risky diffs, and a human approves before anything merges.
#
#   intake → implement(producer) → risk_gate → [critic if risky] → test
#            → cto_gate → HUMAN APPROVAL → merge
#
# Usage:
#   ./scripts/flow.sh <issue-number> [--repo OWNER/REPO] [--base BRANCH] [--auto-implement]
#
# Modes:
#   default          operate on the issue's existing PR/branch (you implemented it)
#   --auto-implement dispatch the producer agent to implement first
#
# Requires: gh, git, claude (Claude Code CLI). Reads ../config/routing.yaml.

# requires bash 4+ (associative arrays). macOS default is 3.2 — `brew install bash`.
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  echo "flow.sh requires bash 4+ (found ${BASH_VERSION:-unknown}). Run: brew install bash" >&2
  exit 1
fi

# ---------- styling ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}${BOLD}▸ $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}! $*${NC}"; }
err()   { echo -e "${RED}✗ $*${NC}" >&2; }
die()   { err "$*"; exit 1; }

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ROUTING="$REPO_DIR/config/routing.yaml"
AGENTS_DIR="$REPO_DIR/providers/claude/agents"

# ---------- args ----------
[ $# -ge 1 ] || die "usage: flow.sh <issue-number> [--repo OWNER/REPO] [--base BRANCH] [--auto-implement]"
ISSUE="$1"; shift
REPO="Arlencho/olympus-platform"; BASE="main"; AUTO_IMPLEMENT=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --auto-implement) AUTO_IMPLEMENT=1; shift;;
    --dry-run) DRY=1; shift;;
    *) die "unknown flag: $1";;
  esac
done

command -v gh >/dev/null     || die "gh CLI not found"
command -v claude >/dev/null || die "claude CLI not found"

# ---------- producer → paired critic (heterogeneous, runs on Opus) ----------
declare -A CRITIC_OF=(
  [go-backend]=backend-critic
  [web-frontend]=frontend-critic
  [db-architect]=database-critic
  [api-designer]=api-critic
  [mobile]=frontend-critic
)

# A diff touching any of these is RISKY → critic is mandatory. Everything else
# skips the critic (that's the cost lever — Opus only on what can hurt you).
RISKY='payment|stripe|duffel|klarna|auth|token|session|webhook|/db/migrations|migration|state|status|refund|security|crypto|secret|pricing|currency'

# run a role agent with a prompt: agent <role> <prompt>
agent() {
  local charter="$AGENTS_DIR/$1.md"
  [ -f "$charter" ] || die "charter not found for role '$1' ($charter)"
  if [ "$DRY" -eq 1 ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} would dispatch ${BOLD}$1${NC} — $(echo "$2" | head -c 80)..." >&2
    case "$1" in
      *critic) echo "CRITIC: PASS";;
      cto)     echo "APPROVE-MERGE (dry-run stub)";;
      *)       echo "[dry-run: $1 output]";;
    esac
    return 0
  fi
  claude --agent "$charter" --print "$2"
}

# pick the producer from issue labels (routing.yaml label_routes), fall back to title
route_producer() {
  local labels="$1" title="$2" role=""
  # label_routes: "agent:go-backend": go-backend
  while IFS= read -r line; do
    local key val
    key=$(echo "$line" | sed -E 's/^ *"([^"]+)".*/\1/')
    val=$(echo "$line" | sed -E 's/.*: *([a-z-]+) *$/\1/')
    [ -z "$key" ] && continue
    if echo "$labels" | grep -qiF "$key"; then role="$val"; break; fi
  done < <(grep -E '^\s+"agent:' "$ROUTING")
  if [ -z "$role" ]; then
    echo "$title" | grep -qiE 'api'      && role=api-designer
    echo "$title" | grep -qiE 'migrat'   && role=db-architect
    echo "$title" | grep -qiE 'frontend|page|ui|web' && role=web-frontend
    [ -z "$role" ] && role=go-backend   # safe default
  fi
  echo "$role"
}

# ======================================================================
step "STAGE 0 · intake  (issue #$ISSUE in $REPO)"
META=$(gh issue view "$ISSUE" -R "$REPO" --json title,labels,url 2>/dev/null) || die "cannot read issue #$ISSUE"
TITLE=$(echo "$META" | python3 -c 'import json,sys;print(json.load(sys.stdin)["title"])')
LABELS=$(echo "$META" | python3 -c 'import json,sys;print(",".join(l["name"] for l in json.load(sys.stdin)["labels"]))')
URL=$(echo "$META" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')
PRODUCER=$(route_producer "$LABELS" "$TITLE")
CRITIC="${CRITIC_OF[$PRODUCER]:-}"
echo "  title    : $TITLE"
echo "  labels   : ${LABELS:-none}"
echo "  producer : $PRODUCER"
echo "  critic   : ${CRITIC:-none (devops/test paths have no paired critic)}"
ok "routed"

# ======================================================================
BRANCH="flow/issue-$ISSUE"
if [ "$AUTO_IMPLEMENT" -eq 1 ]; then
  step "STAGE 1 · implement  (producer: $PRODUCER)"
  warn "auto-implement runs the producer agent against the repo on branch $BRANCH."
  agent "$PRODUCER" "Implement GitHub issue #$ISSUE ($TITLE) in $REPO. Work on branch $BRANCH off $BASE, follow the repo CLAUDE.md + PRD, commit in small steps, open a draft PR with 'Closes #$ISSUE'. Do not merge."
  ok "producer finished"
else
  step "STAGE 1 · implement  (manual)"
  echo "  expecting an existing PR/branch for issue #$ISSUE."
fi

# locate the PR for this issue
PR=$(gh pr list -R "$REPO" --search "$ISSUE in:body" --json number,headRefName --jq '.[0].number' 2>/dev/null || true)
if [ -z "${PR:-}" ]; then
  if [ "$DRY" -eq 1 ]; then warn "no PR yet for issue #$ISSUE — dry-run will show routing and simulate the rest"; PR="none"
  else die "no PR found referencing issue #$ISSUE — implement it first (or rerun with --auto-implement)"; fi
fi
echo "  PR #$PR"

# ======================================================================
step "STAGE 2 · risk gate"
if [ "$PR" = "none" ]; then FILES=""; else FILES=$(gh pr diff "$PR" -R "$REPO" --name-only 2>/dev/null || echo ""); fi
if [ -z "$FILES" ] && [ "$PR" = "none" ]; then
  RISKY_HIT=0; warn "no PR diff to scan yet — risk gate would run on the PR once it exists"
elif echo "$FILES" | grep -qiE "$RISKY"; then
  RISKY_HIT=1
  warn "RISKY diff — touches: $(echo "$FILES" | grep -iE "$RISKY" | head -3 | tr '\n' ' ')"
  echo "  → critic review is MANDATORY"
else
  RISKY_HIT=0
  ok "low-risk diff — skipping the Opus critic (cost lever)"
fi

# ======================================================================
if [ "$RISKY_HIT" -eq 1 ] && [ -n "$CRITIC" ]; then
  step "STAGE 3 · critic review  ($CRITIC, Opus, 2-loop ceiling)"
  for loop in 1 2; do
    echo "  loop $loop/2"
    VERDICT=$(agent "$CRITIC" "Adversarially review PR #$PR in $REPO for issue #$ISSUE. Per your charter: output executable failure only (failing test diff or file:line contract violation). If the PR is clean, reply exactly 'CRITIC: PASS'. Otherwise reply 'CRITIC: FAIL' and the executable findings.")
    echo "$VERDICT"
    if echo "$VERDICT" | grep -q "CRITIC: PASS"; then ok "critic passed on loop $loop"; break; fi
    if [ "$loop" -eq 2 ]; then warn "critic still failing after 2 loops → escalate to CTO"; fi
    [ "$AUTO_IMPLEMENT" -eq 1 ] && agent "$PRODUCER" "Address the Backend/Frontend critic findings on PR #$PR in $REPO. Push fixes to branch. Do not merge."
  done
else
  step "STAGE 3 · critic review  (skipped — low risk or no paired critic)"
fi

# ======================================================================
step "STAGE 4 · test  (test-engineer)"
agent "test-engineer" "Review and strengthen test coverage for PR #$PR in $REPO (issue #$ISSUE). Per your charter: write tests only, never production code. Ensure the change is covered; on risky paths, a failing-test-first must already exist." || warn "test stage reported issues"
ok "test stage done"

# ======================================================================
step "STAGE 5 · CTO gate"
CTO_VERDICT=$(agent "cto" "Final architectural gate on PR #$PR in $REPO (issue #$ISSUE). Reply with exactly one of: 'APPROVE-MERGE', 'BLOCK-FIX' + reasons, or 'BLOCK-ESCALATE' + reasons.")
echo "$CTO_VERDICT"

# ======================================================================
echo -e "\n${BOLD}══════════════════ HUMAN GATE ══════════════════${NC}"
echo "  Issue   : #$ISSUE  $TITLE"
echo "  PR      : #$PR"
echo "  Risk    : $([ "$RISKY_HIT" -eq 1 ] && echo RISKY || echo low)"
echo "  CTO     : $(echo "$CTO_VERDICT" | grep -oE 'APPROVE-MERGE|BLOCK-FIX|BLOCK-ESCALATE' | head -1)"
echo "  Diff    :"; echo "$FILES" | sed 's/^/            /' | head -20
echo -e "${BOLD}═════════════════════════════════════════════════${NC}"

if ! echo "$CTO_VERDICT" | grep -q "APPROVE-MERGE"; then
  err "CTO did not approve — stopping before the human gate. Fix and rerun."
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  warn "[dry-run] would prompt: Merge PR #$PR? — stopping here. No agents dispatched, no merge, nothing spent."
  exit 0
fi
read -r -p "$(echo -e "${BOLD}Merge PR #$PR? [y/N] ${NC}")" ANS
case "$ANS" in
  y|Y|yes)
    step "merging PR #$PR"
    gh pr merge "$PR" -R "$REPO" --squash --delete-branch && ok "merged"
    gh issue edit "$ISSUE" -R "$REPO" --remove-label "status:in-review" --add-label "status:qa" 2>/dev/null || true
    ;;
  *)
    warn "not merging. PR #$PR left open for you. ($URL)"
    ;;
esac
