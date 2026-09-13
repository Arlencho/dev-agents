#!/usr/bin/env bash
# land.sh - drive one PR all the way: CI -> merge -> deploy -> prod verify -> close.
#
# Usage:  ./land.sh <PR#> [<PR#> ...]
#
# Written after 2026-08-12, where five PRs were landed by hand and every step
# below corresponds to something that actually went wrong that day.
#
#   1. `.conclusion // "RUNNING"` does NOT catch an empty string, only null.
#      A wait loop written that way exits immediately and reports a running
#      job as finished. Poll `.status == "completed"` instead.
#   2. Every merge puts the remaining PRs BEHIND. Without update-branch they
#      sit at BLOCKED forever while looking mergeable.
#   3. A squash merge can DROP the `Closes #N` keywords from the commit body,
#      so the issue silently stays open. Verify issue state after every merge.
#   4. mergeStateStatus CLEAN is not safety. Two PRs that never touch a common
#      file merge clean and still redden main. Only running the merged tree
#      finds it. See MERGE ORDER (HARD GATE) below.
#   5. A green deploy run is not a deploy. A 9-second "success" is a gate skip.
#      Ask the service which commit it is running.
#   6. The Go module root is apps/api. Running `go test` from the repo root
#      gives `[setup failed]`, which reads exactly like a real break.
#
# MERGE ORDER (HARD GATE). NOT OPTIONAL. NOT AUTOMATED HERE.
#   Before landing two PRs that can COUPLE (same subsystem OR shared test
#   surface), merge one onto the other LOCALLY and run the suite. CLEAN is
#   not safety: #2568 and #2561 shared NO file, both reported CLEAN, and the
#   second to land would have reddened main with no warning from git. This
#   script cannot detect that class of break; you must run the combined tree
#   before calling land.sh on the second PR.

set -uo pipefail

# The queue runner (scripts/queue-runner.sh) lands PRs of other repos through
# this script too: LAND_REPO names the GitHub slug, LAND_ROOT the checkout the
# fetch and the worktree sweep run in. Defaults stay the product repo.
REPO="${LAND_REPO:-Arlencho/olympus-platform}"
ROOT="${LAND_ROOT:-/Users/arlenrios/Desktop/dev-projects/AI-Orchestration/olympus-platform}"
API_URL=""

# Another repo's PR must never be landed standing in the product checkout: the
# fetch and the sweep below would run in the wrong tree. A caller that names
# the repo names the checkout too, or is refused before anything is touched.
if [ -n "${LAND_REPO:-}" ] && [ -z "${LAND_ROOT:-}" ]; then
  printf 'land.sh: LAND_REPO=%s given without LAND_ROOT; refusing to stand in the default checkout\n' "$LAND_REPO" >&2
  exit 2
fi
if [ ! -d "$ROOT/.git" ]; then
  printf 'land.sh: %s is not a git checkout; refusing\n' "$ROOT" >&2
  exit 2
fi

cd "$ROOT" || exit 1

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
fail() { printf '\033[31mXX %s\033[0m\n' "$*"; }

head_sha() { gh pr view "$1" -R "$REPO" --json headRefOid --jq .headRefOid; }

# Poll on .status, never on .conclusion (lesson 1).
#
# lesson 8: ZERO CHECKS MUST NOT READ AS GREEN.
#   A conflicted (DIRTY) PR produces no merge ref, so GitHub runs NOTHING on
#   the new head. `check-runs` then returns an EMPTY array: the pending count
#   is 0, the non-green filter yields nothing, and the old version of this
#   function printed "checks green". `gh pr checks` is no better - it shows the
#   stale run still attached to the PREVIOUS head and looks green too.
#   "No failures" and "no run" are indistinguishable unless you count.
#   Found on PR #2596, 2026-08-13, by querying actions/runs?head_sha= and
#   getting an empty list. This is the same defect class the whole wave is
#   about, sitting inside the tool built to enforce it.
wait_checks() {
  local pr="$1" tries="${2:-45}" h p total
  for _ in $(seq 1 "$tries"); do
    h=$(head_sha "$pr")
    total=$(gh api "repos/$REPO/commits/$h/check-runs" --jq '.check_runs|length' 2>/dev/null)
    p=$(gh api "repos/$REPO/commits/$h/check-runs" --jq '[.check_runs[]|select(.status!="completed")]|length' 2>/dev/null)
    # keep waiting while nothing has been scheduled yet OR something is running
    { [ "$total" != "0" ] && [ "$p" = "0" ]; } && break
    sleep 40
  done

  h=$(head_sha "$pr")
  total=$(gh api "repos/$REPO/commits/$h/check-runs" --jq '.check_runs|length' 2>/dev/null)

  # A DIRTY PR never gets a merge ref, so it never gets checks. Say why.
  local ms; ms=$(gh pr view "$pr" -R "$REPO" --json mergeStateStatus --jq .mergeStateStatus)
  if [ "$ms" = "DIRTY" ]; then
    fail "PR #$pr is DIRTY (conflicts). GitHub runs no checks on a conflicted PR."
    echo "     Resolve the conflict, push, and re-run. Do NOT read a green"
    echo "     'gh pr checks' here: that is the STALE run from the previous head."
    return 1
  fi
  if [ "${total:-0}" = "0" ]; then
    fail "PR #$pr head ${h:0:8} has ZERO check runs. That is not green, it is unchecked."
    return 1
  fi

  local bad
  bad=$(gh api "repos/$REPO/commits/$h/check-runs" \
        --jq '.check_runs[]|select(.conclusion!="skipped" and .conclusion!="success")|"\(.conclusion // .status)  \(.name)"')
  if [ -n "$bad" ]; then fail "PR #$pr not green:"; echo "$bad"; return 1; fi
  echo "  checks green at ${h:0:8} ($total runs)"
}

land_one() {
  local pr="$1"
  say "PR #$pr"

  local state
  state=$(gh pr view "$pr" -R "$REPO" --json state --jq .state)
  [ "$state" = "MERGED" ] && { echo "  already merged"; return 0; }

  # lesson 2: clear BEHIND before waiting on checks
  if [ "$(gh pr view "$pr" -R "$REPO" --json mergeStateStatus --jq .mergeStateStatus)" = "BEHIND" ]; then
    echo "  BEHIND, updating branch"
    gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" >/dev/null 2>&1
    sleep 10
  fi

  wait_checks "$pr" || return 1

  # capture closing keywords BEFORE merging (lesson 3)
  local closes
  closes=$(gh pr view "$pr" -R "$REPO" --json body --jq .body | grep -oiE 'closes #[0-9]+' | grep -oE '[0-9]+' | sort -u)

  # lesson 2b: main can move again WHILE we wait for checks - another land.sh,
  # a teammate, anything. The BEHIND clear at the top of this function is stale
  # by the time we get here. Re-check and re-clear, up to three times, then
  # give up rather than looping forever against a busy repo.
  local attempt
  for attempt in 1 2 3; do
    [ "$(gh pr view "$pr" -R "$REPO" --json mergeStateStatus --jq .mergeStateStatus)" != "BEHIND" ] && break
    echo "  went BEHIND again (attempt $attempt), updating and re-waiting"
    gh api -X PUT "repos/$REPO/pulls/$pr/update-branch" >/dev/null 2>&1
    sleep 10
    wait_checks "$pr" || return 1
  done

  gh pr merge "$pr" -R "$REPO" --squash --delete-branch >/dev/null 2>&1
  sleep 8
  if [ "$(gh pr view "$pr" -R "$REPO" --json state --jq .state)" != "MERGED" ]; then
    fail "merge did not take for #$pr"; return 1
  fi
  git fetch origin -q
  local msha; msha=$(git log origin/main -1 --format=%h)
  echo "  merged -> $msha"

  # lesson 3: the squash body may have eaten the keywords
  for i in $closes; do
    if [ "$(gh issue view "$i" -R "$REPO" --json state --jq .state)" = "OPEN" ]; then
      warn "issue #$i still OPEN after merge - squash dropped the keyword. Close it with a receipt."
    else
      echo "  #$i closed"
    fi
  done

  # Did this touch shippable code, or only tests?
  # Ask the PR for its own file list. Do NOT diff HEAD~1..HEAD in the shared
  # checkout: its local HEAD lags behind origin/main whenever the last merges
  # were not pulled, so that diff describes some unrelated older commit.
  # This bit me on #2574 - an apps/api-only PR was reported as touching three
  # apps/web files, which were the previous local HEAD's.
  local prod_files
  prod_files=$(gh pr view "$pr" -R "$REPO" --json files --jq '.[][].path' 2>/dev/null \
               | grep -E '^(apps/api|apps/web|services)/' \
               | grep -vE '(_test\.go|\.test\.(ts|tsx)|/tests/|\.spec\.ts)$' | head -5)
  if [ -z "$prod_files" ]; then
    echo "  test-only change, no deploy expected"
    return 0
  fi
  echo "  touches shippable code:"; echo "$prod_files" | sed 's/^/    /'
  warn "run verify_prod after the deploy workflow finishes"
}

# lesson 7: THERE IS MORE THAN ONE SERVICE. This checked only olympus-api and
# printed "API is current" for PR #2585, which changed only services/hermes.
# Green, reassuring, and about the wrong service. Report per service, and say
# plainly when a service cannot be version-probed rather than staying silent.
verify_prod() {
  say "prod verification"

  local touched
  touched=$(git diff --name-only origin/main~1..origin/main 2>/dev/null)
  if echo "$touched" | grep -q '^services/hermes/'; then
    warn "this merge touched services/hermes - olympus-api's version says NOTHING about it"
    echo "  hermes deploy runs (verify the newest matches the merge SHA):"
    gh run list -R "$REPO" --workflow=deploy-hermes.yml --limit 2 \
      --json headSha,conclusion,createdAt \
      --jq '.[] | "    \(.conclusion)  \(.headSha[0:8])  \(.createdAt[11:16])"' 2>/dev/null \
      || echo "    (could not read deploy-hermes runs)"
    echo "  NOTE: Hermes exposes no version endpoint, so a matching deploy run is"
    echo "        the strongest evidence available. Say so rather than implying more."
  fi
  if echo "$touched" | grep -q '^apps/web/'; then
    warn "this merge touched apps/web - check the Vercel deploy separately"
  fi
  [ -z "$API_URL" ] && API_URL=$(gcloud run services describe olympus-api \
      --region=europe-north1 --project=olympus-ai-tech --format='value(status.url)' 2>/dev/null)
  [ -z "$API_URL" ] && { fail "could not resolve the API url"; return 1; }

  local live newest
  live=$(curl -s "$API_URL/api/v1/health" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["version"])' 2>/dev/null)
  # compare against the newest apps/api commit, NOT origin/main: the API only
  # deploys on apps/api/**, so lagging main after a web-only merge is healthy.
  newest=$(git log origin/main -1 --format=%H -- apps/api)

  echo "  live:   ${live:0:8}"
  echo "  newest: ${newest:0:8} (newest apps/api commit)"
  if [ "$live" = "dev" ]; then
    fail "version is 'dev' - the SHA was never injected, nothing about this service is externally verifiable"
    return 1
  fi
  if [ "$live" = "$newest" ]; then
    echo "  API is current"
  else
    warn "API is behind. Check whether the gap is test-only commits (fine) or a failed deploy."
    git log --oneline "$live..$newest" -- apps/api 2>/dev/null | sed 's/^/    /'
  fi

  curl -s "$API_URL/api/v1/health" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print("  db:",d["components"]["database"]["status"],"| providers:",d["components"]["providers"])' 2>/dev/null
}

# lesson 4 lives here as a reminder, not as automation
main_green() {
  say "main CI"
  local rid st
  rid=$(gh run list -R "$REPO" --workflow=ci.yml --branch=main --limit 1 --json databaseId --jq '.[0].databaseId')
  for _ in $(seq 1 45); do
    st=$(gh api "repos/$REPO/actions/runs/$rid" --jq .status)
    [ "$st" = "completed" ] && break
    sleep 45
  done
  gh api "repos/$REPO/actions/runs/$rid" --jq '"  \(.head_sha[0:8]): \(.conclusion)"'
  gh api "repos/$REPO/actions/runs/$rid/jobs" \
    --jq '.jobs[]|select(.conclusion!="success" and .conclusion!="skipped")|"  FAILED \(.conclusion // .status)  \(.name)"'
}

# Here because nothing else tears a dispatch worktree down: 74 stale worktrees and 243 stale local branches had piled up on one machine by 2026-08-10.
sweep_worktrees() {
  say "worktree sweep"
  local out rc
  out=$(cd "$ROOT" && make worktree-sweep-apply 2>&1); rc=$?
  # Print the sweep's own summary, plus anything it refused to touch.
  printf '%s\n' "$out" | grep -E '^(worktrees:|branches :|DIRTY )' | sed 's/^/  /'
  if [ "$rc" -ne 0 ]; then
    warn "sweep exited $rc - worktrees may still be stale. Landing result is unaffected."
  fi
  # Second sweep: the per-seat worktrees and per-dispatch runtimes that
  # scripts/run-remote.sh keeps under ~/dev, older than a day (a different
  # clone from the one above, so a different sweep).
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  out=$("$here/seat-worktree-sweep.sh" --apply 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(seat worktrees:|runtimes +:)' | sed 's/^/  /'
  if [ "$rc" -ne 0 ]; then
    warn "seat sweep exited $rc - seat worktrees may still be stale. Landing result is unaffected."
  fi
  # Never let teardown decide whether the landing succeeded.
  return 0
}

for pr in "$@"; do land_one "$pr" || { fail "stopping at #$pr"; exit 1; }; done
main_green
# The prod probe knows one service set: the product's. Another repo gets the
# merge, the main CI read-back and the sweep, and is told plainly what it did
# not get.
case "$REPO" in
  */olympus-platform) verify_prod ;;
  *) say "prod verification"; echo "  none configured for $REPO (only the product repo is probed)" ;;
esac
sweep_worktrees

say "still yours to do by hand"
cat <<'EOF'
  - Close any issue flagged above, with a receipt naming the merge SHA.
  - Verify the specific claim the PR made, not that the page loads.
    Run the control FIRST: if a known-live string returns 0 hits, the probe
    cannot see the surface and every 0 is meaningless.
  - Say what could NOT be verified. That beats a green probe implying
    coverage it does not have.
EOF
