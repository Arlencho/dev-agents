#!/bin/bash
# Ground Truth: per-seat worktrees in scripts/run-remote.sh (issue #66), the
# per-branch dispatch lock end to end, and the seat sweep. No network, no
# vendor CLIs: the claude/kimi shims in tests/shims run in SHIM_MODE=work,
# which commits one file in the seat's cwd and sleeps so two seats can be
# observed alive at once. Everything runs in a throwaway HOME with a bare
# origin, so the operator's ~/dev is never touched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0; fail=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %-58s → %s\n' "$1" "$3"; pass=$((pass+1))
    else
        printf '  FAIL %-58s want=%s got=%s\n' "$1" "$2" "$3"; fail=$((fail+1))
    fi
}
check_true() { # <name> <command...>
    local name="$1"; shift
    if "$@"; then printf '  ok   %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL %s\n' "$name"; fail=$((fail+1)); fi
}

# ---- sandbox -----------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
FLEET="$SANDBOX/fleet"; mkdir -p "$FLEET/tests" "$FLEET/logs" "$FLEET/wave-plans" "$FLEET/learnings"
for d in scripts providers config roles skills; do cp -R "$REPO_DIR/$d" "$FLEET/$d"; done
cp -R "$REPO_DIR/tests/shims" "$FLEET/tests/shims"
ORIGIN="$SANDBOX/product.git"
git init -q --bare -b main "$ORIGIN"
export GIT_AUTHOR_NAME=fleet GIT_AUTHOR_EMAIL=fleet@example.invalid \
       GIT_COMMITTER_NAME=fleet GIT_COMMITTER_EMAIL=fleet@example.invalid
seed="$SANDBOX/seed"
git clone -q "$ORIGIN" "$seed" 2>/dev/null
( cd "$seed" && git checkout -q -b main 2>/dev/null; echo "# product" > README.md \
  && git add README.md && git commit -q -m "chore: seed" && git push -q origin main 2>/dev/null )
FETCH="$HOME/dev/product"
WT="$HOME/dev/worktrees/product"
export PATH="$FLEET/tests/shims:$PATH"
export SHIM_MODE=work SEAT_WAIT_POLL_S=1 DISPATCH_LOCK_POLL_S=1 FLEET_HEARTBEAT_S=0
# A suite launched from inside a seat inherits that seat's env; the rows below
# choose their own provider and event stream.
unset AGENT_PROVIDER AGENT_MODEL FLEET_EVENTS_FILE FLEET_EVENTS_DIR
# This suite may itself run inside a dispatched seat: its dispatch id and detached
# marker must not leak into the dispatches started here.
unset DISPATCH_DETACHED DISPATCH_RUN_LOG FLEET_DISPATCH_ID

seat() { # <task-id> <branch> [dispatch-id]   env: SHIM_WORK_SLEEP SHIM_WORK_TAG AGENT_PROVIDER
    AGENT_PROVIDER="${AGENT_PROVIDER:-claude}" AGENT_WAVE=1 AGENT_TASK_ID="$1" FLEET_DISPATCH_ID="${3:-d1}" \
        bash "$FLEET/scripts/run-remote.sh" localhost "$ORIGIN" devops "${4:-do the thing}" "$2"
}
# A seat in its own process group: what a terminal Ctrl-C targets. Sets SEAT_PID.
seat_group() { # <task-id> <branch> <logfile>
    AGENT_PROVIDER=claude AGENT_WAVE=1 AGENT_TASK_ID="$1" FLEET_DISPATCH_ID=d1 \
        perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; setpgrp(0,0); exec @ARGV or die $!' -- \
        bash "$FLEET/scripts/run-remote.sh" localhost "$ORIGIN" devops "do the thing" "$2" > "$3" 2>&1 &
    SEAT_PID=$!
}
seat_trees() { git -C "$FETCH" worktree list --porcelain 2>/dev/null | grep -c "^worktree .*/worktrees/"; }
origin_log() { git --git-dir="$ORIGIN" log --format=%s "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

echo "== two seats in one wave on two branches run at the same time =="
SHIM_WORK_SLEEP=5 SHIM_WORK_TAG=a seat 0 feat/a > "$SANDBOX/a.log" 2>&1 & PA=$!
SHIM_WORK_SLEEP=5 SHIM_WORK_TAG=b seat 1 feat/b > "$SANDBOX/b.log" 2>&1 & PB=$!
sleep 4
check "seat worktrees present mid-run" "2" "$(seat_trees)"
check_true "seat a runs in its own worktree" test -d "$WT/d1/0-feat-a"
check_true "seat b runs in its own worktree" test -d "$WT/d1/1-feat-b"
wait $PA; check "seat a exit" "0" "$?"
wait $PB; check "seat b exit" "0" "$?"
check "seat worktrees after both ended" "0" "$(seat_trees)"
check "feat/a reached origin" "chore: seat work a chore: seed" "$(origin_log feat/a)"
check "feat/b reached origin" "chore: seat work b chore: seed" "$(origin_log feat/b)"
check "fetch point is detached, no branch checked out" "detached" "$(git -C "$FETCH" symbolic-ref -q --short HEAD || echo detached)"
check "no stale fetch-point lock" "absent" "$([ -d "$FETCH.seat-lock" ] && echo present || echo absent)"

echo ""
echo "== a later seat on an existing origin branch stacks on it =="
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=a2 seat 2 feat/a > "$SANDBOX/a2.log" 2>&1
check "critic seat exit" "0" "$?"
check "feat/a on origin" "chore: seat work a2 chore: seat work a chore: seed" "$(origin_log feat/a)"

echo ""
echo "== launcher exit codes propagate, and the ledger is written on failure =="
SHIM_MODE=fail    seat 3 feat/f1 > /dev/null 2>&1; check "fail    → 1"  "1"  "$?"
SHIM_MODE=ratecap seat 4 feat/f2 > /dev/null 2>&1; check "ratecap → 75" "75" "$?"
SHIM_MODE=noauth  seat 5 feat/f3 > /dev/null 2>&1; check "noauth  → 69" "69" "$?"
check "failed seat's ledger line carries status failed" "1" \
      "$(grep -c '"status":"failed"' "$FLEET/wave-plans/1/handoffs/1-devops-feat-f1.jsonl" 2>/dev/null)"
check_true "ratecap wrote the vendor cooldown file" test -f "$FLEET/logs/provider-state/claude.cooldown"
check "worktrees after the failures" "0" "$(seat_trees)"
# The failure learnings are injected into the next seat's prompt; a raw cap or
# auth phrase there would be echoed by a CLI and misread by the classifier.
check "failure learnings carry a fixed code, never the classifier phrase" "0" \
      "$(grep -ciE 'not logged in|please run /login|usage limit|limit resets|oauth session expired' "$FLEET/learnings/product.jsonl")"
check "learnings recorded for the fail, ratecap and noauth seats" "3" "$(grep -c '"type":"failure"' "$FLEET/learnings/product.jsonl")"
check "ratecap learning" "1" "$(grep -c '"summary":"RATE_CAP:' "$FLEET/learnings/product.jsonl")"
check "noauth learning" "1" "$(grep -c '"summary":"UNAVAILABLE:' "$FLEET/learnings/product.jsonl")"
check "learnings reach the next prompt" "1" "$(SHIM_ARGV_LOG="$SANDBOX/argv" SHIM_MODE=success seat 18 feat/prompt > /dev/null 2>&1; tr '\0' '\n' < "$SANDBOX/argv" | grep -c 'UNAVAILABLE: claude launcher exit 69')"
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=after seat 19 feat/after > "$SANDBOX/after.log" 2>&1
check "the seat after the noauth seat is classified by its own output" "0" "$?"
check "feat/after reached origin" "chore: seat work after chore: seed" "$(origin_log feat/after)"

echo ""
echo "== two dispatches started in the same second get two ids, two runtimes, two event files =="
# fleet-events mints <utc second>-<slug>-<pid>; two inits in one process each
# are the two dispatchers. Retry until a pair lands in the same second.
FE_DIR="$SANDBOX/fe"
for _try in 1 2 3 4 5 6 7 8; do
    rm -rf "$FE_DIR"; mkdir -p "$FE_DIR"   # a pair that straddled a second leaves no files behind
    ID1=$(FLEET_EVENTS_DIR="$FE_DIR" bash "$FLEET/scripts/fleet-events.sh" init product wave | xargs basename | sed 's/\.jsonl$//')
    ID2=$(FLEET_EVENTS_DIR="$FE_DIR" bash "$FLEET/scripts/fleet-events.sh" init product wave | xargs basename | sed 's/\.jsonl$//')
    [ "${ID1:0:15}" = "${ID2:0:15}" ] && break
done
check "both ids share the same second" "${ID1:0:15}" "${ID2:0:15}"
check_true "the ids differ" test "$ID1" != "$ID2"
check "two event files" "2" "$(ls "$FE_DIR"/*.jsonl | wc -l | tr -d ' ')"
check "latest points at the second" "$ID2.jsonl" "$(cat "$FE_DIR/latest")"
echo "  ids: $ID1  $ID2"
SHIM_WORK_SLEEP=3 SHIM_WORK_TAG=s1 seat 23 feat/s1 "$ID1" > "$SANDBOX/s1id.log" 2>&1 & PS1_=$!
SHIM_WORK_SLEEP=3 SHIM_WORK_TAG=s2 seat 24 feat/s2 "$ID2" > "$SANDBOX/s2id.log" 2>&1 & PS2_=$!
sleep 2
check "two runtimes alive at once" "2" "$(find "$HOME/dev/agent-runtime" -mindepth 1 -maxdepth 1 -type d \( -name "$ID1" -o -name "$ID2" \) | wc -l | tr -d ' ')"
wait $PS1_; check "seat of the first id exit" "0" "$?"
wait $PS2_; check "seat of the second id exit" "0" "$?"
# A direct seat leaves its runtime to the sweep; only dispatch.sh removes one.
rm -rf "$HOME/dev/agent-runtime/$ID1" "$HOME/dev/agent-runtime/$ID2"

echo ""
echo "== FLEET_KEEP_FAILED_WORKTREES=1 keeps a failed tree; the next seat clears it =="
FLEET_KEEP_FAILED_WORKTREES=1 SHIM_MODE=fail seat 6 feat/keep > "$SANDBOX/keep.log" 2>&1
check "failed seat exit" "1" "$?"
check_true "its worktree is kept" test -d "$WT/d1/6-feat-keep"
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=k2 seat 7 feat/keep > "$SANDBOX/keep2.log" 2>&1
check "next seat on that branch exit" "0" "$?"
check "dead holder was removed" "1" "$(grep -c 'Removed the dead seat worktree' "$SANDBOX/keep2.log")"
check "worktrees after" "0" "$(seat_trees)"

echo ""
echo "== a dead tree with uncommitted work is moved aside, never destroyed =="
git -C "$FETCH" worktree add -q "$WT/old/9-feat-dirty" -b feat/dirty origin/main
echo scratch > "$WT/old/9-feat-dirty/scratch.txt"
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=d seat 8 feat/dirty > "$SANDBOX/dirty.log" 2>&1
check "seat exit" "0" "$?"
check "moved aside" "1" "$(grep -c 'aside' "$SANDBOX/dirty.log")"
check_true "the scratch file survived" test -f "$WT"/old/9-feat-dirty.aside-*/scratch.txt

echo ""
echo "== two seats on the same branch serialize: the second waits =="
SHIM_WORK_SLEEP=5 SHIM_WORK_TAG=first seat 10 feat/same > "$SANDBOX/s1.log" 2>&1 & P1=$!
sleep 2
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=second seat 11 feat/same > "$SANDBOX/s2.log" 2>&1 & P2=$!
sleep 2
check "only the holder's worktree exists" "1" "$(seat_trees)"
check "holder is locked with its seat pid" "1" "$(git -C "$FETCH" worktree list --porcelain | grep -c '^locked seat pid ')"
wait $P1; check "first exit" "0" "$?"
wait $P2; check "second exit" "0" "$?"
check_true "second waited on the live holder" test "$(grep -c 'held by a live seat' "$SANDBOX/s2.log")" -ge 1
check "commits stacked in order" "chore: seat work second chore: seat work first chore: seed" "$(origin_log feat/same)"

echo ""
if command -v perl >/dev/null 2>&1; then
    echo "== Ctrl-C / kill of a running seat tears its worktree down =="
    SHIM_WORK_SLEEP=30 SHIM_WORK_TAG=t seat_group 12 feat/sig "$SANDBOX/sig.log"
    sleep 4
    check "worktree present before the signal" "1" "$(seat_trees)"
    kill -TERM -"$SEAT_PID"; wait "$SEAT_PID"; check "terminated seat exits 143" "143" "$?"
    sleep 2
    check "worktree gone after SIGTERM" "0" "$(seat_trees)"
    SHIM_WORK_SLEEP=30 SHIM_WORK_TAG=i seat_group 13 feat/sig2 "$SANDBOX/sig2.log"
    sleep 4
    kill -INT -"$SEAT_PID"; wait "$SEAT_PID"; check "interrupted seat exits 130" "130" "$?"
    sleep 2
    check "worktree gone after SIGINT" "0" "$(seat_trees)"
else
    echo "  skip perl is not available: cannot isolate a process group for the signal tests"
fi

echo ""
echo "== guardrail hooks installed at the fetch point fire inside a worktree =="
git -C "$FETCH" worktree add -q "$WT/probe/0-feat-hook" -b feat/hook origin/main
echo x > "$WT/probe/0-feat-hook/x.txt"
git -C "$WT/probe/0-feat-hook" add x.txt
git -C "$WT/probe/0-feat-hook" commit -q -m "feat: x

Generated with a code assistant" > /dev/null 2>&1
check "branded commit message is blocked in the worktree" "1" "$?"
git -C "$WT/probe/0-feat-hook" commit -q -m "feat: x" > /dev/null 2>&1
check "a plain message commits in the worktree" "0" "$?"
git -C "$FETCH" worktree remove --force "$WT/probe/0-feat-hook"

echo ""
echo "== the launcher runtime ships once per dispatch, per provider launcher =="
mkdir -p "$HOME/dev/agent-runtime"; echo legacy > "$HOME/dev/agent-runtime/launch.sh"
SHIM_WORK_SLEEP=2 SHIM_WORK_TAG=r1 seat 14 feat/r1 d-rt > "$SANDBOX/r1.log" 2>&1 & PR1=$!
AGENT_PROVIDER=kimi SHIM_WORK_SLEEP=2 SHIM_WORK_TAG=r2 seat 15 feat/r2 d-rt > "$SANDBOX/r2.log" 2>&1 & PR2=$!
wait $PR1; check "first provider seat exit" "0" "$?"
wait $PR2; check "second provider seat exit" "0" "$?"
check "exactly one seat shipped the runtime" "1" "$(cat "$SANDBOX/r1.log" "$SANDBOX/r2.log" | grep -c '^Shipping launcher runtime')"
check "the other found it shipped" "1" "$(cat "$SANDBOX/r1.log" "$SANDBOX/r2.log" | grep -c 'shipped by another seat')"
check_true "per-dispatch runtime holds both launchers" test -f "$HOME/dev/agent-runtime/d-rt/providers/claude/launch.sh" -a -f "$HOME/dev/agent-runtime/d-rt/providers/kimi/launch.sh"
check "the second seat ran its own provider launcher" "1" "$(grep -c '^\[kimi shim\]' "$SANDBOX/r2.log")"
check "the flat legacy launcher was not written" "legacy" "$(cat "$HOME/dev/agent-runtime/launch.sh")"

echo ""
echo "== seat_progress paths are worktree-relative; the fetch point reads outside-repo =="
EVENTS="$SANDBOX/events.jsonl"; : > "$EVENTS"
FLEET_EVENTS_FILE="$EVENTS" SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=p SHIM_OUTSIDE_PATH="$FETCH/README.md" \
    seat 16 feat/p > "$SANDBOX/p.log" 2>&1
check "seat exit" "0" "$?"
check "file written in the worktree is repo-relative" "1" "$(grep -c '"path":"seat-p.txt"' "$EVENTS")"
check_true "the fetch point path reads outside-repo" test "$(grep -c '"path":"outside-repo"' "$EVENTS")" -ge 1
check "no absolute path in the event stream" "0" "$(grep -c "$HOME" "$EVENTS")"

echo ""
echo "== the seat sweep keeps live and young trees, removes stale ones =="
SHIM_WORK_SLEEP=12 SHIM_WORK_TAG=live seat 17 feat/live d-live > "$SANDBOX/live.log" 2>&1 & PL=$!
sleep 3
touch -t 202501010000 "$WT/d-live/17-feat-live" "$HOME/dev/agent-runtime/d-live"
git -C "$FETCH" worktree add -q "$WT/d-old/1-feat-old" -b feat/old origin/main
git -C "$FETCH" worktree lock --reason "seat pid 999999 dispatch d-old" "$WT/d-old/1-feat-old"
touch -t 202501010000 "$WT/d-old/1-feat-old"
git -C "$FETCH" worktree add -q "$WT/d-young/2-feat-young" -b feat/young origin/main
mkdir -p "$HOME/dev/agent-runtime/d-old"; touch -t 202501010000 "$HOME/dev/agent-runtime/d-old"
touch -t 202501010000 "$HOME/dev/agent-runtime/d-crashed.claim"
sweep_out=$(bash "$FLEET/scripts/seat-worktree-sweep.sh" --apply 2>&1); check "sweep exit" "0" "$?"
check_true "live seat kept although backdated" test -d "$WT/d-live/17-feat-live"
check_true "live dispatch runtime kept although backdated" test -d "$HOME/dev/agent-runtime/d-live"
check_true "stale dead tree removed" test ! -d "$WT/d-old/1-feat-old"
check_true "young dead tree kept" test -d "$WT/d-young/2-feat-young"
check_true "stale runtime removed" test ! -d "$HOME/dev/agent-runtime/d-old"
check_true "stale claim marker removed" test ! -e "$HOME/dev/agent-runtime/d-crashed.claim"
# kept: the live seat, the young dead tree, and the young aside dir from above
check "sweep summary" "seat worktrees: 1 removed, 3 kept" "$(printf '%s\n' "$sweep_out" | grep '^seat worktrees:')"
wait $PL; check "the live seat still finished cleanly" "0" "$?"
git -C "$FETCH" worktree remove --force "$WT/d-young/2-feat-young"

echo ""
BASH4=""
for cand in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$cand" ] && [ "$("$cand" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ] 2>/dev/null && { BASH4="$cand"; break; }
done
if [ -n "$BASH4" ]; then
    echo "== two real dispatches on the same repo: different branches run concurrently =="
    printf '# TIER: C\n1 | devops | do the thing | feat/da\n' > "$FLEET/wave-plans/da.plan"
    printf '# TIER: C\n1 | devops | do the thing | feat/db\n' > "$FLEET/wave-plans/db.plan"
    printf '# TIER: C\n1 | devops | do the thing | feat/da\n' > "$FLEET/wave-plans/da2.plan"
    disp() { # <plan> <tag> <exit file>
        ( cd "$FLEET" && SHIM_WORK_TAG="$2" SHIM_WORK_SLEEP=8 "$BASH4" scripts/dispatch.sh "$ORIGIN" "wave-plans/$1.plan" \
              --auto --retries 0 --skip-auth-preflight ) > "$SANDBOX/disp-$1.log" 2>&1
        echo $? > "$3"
    }
    disp da A "$SANDBOX/x.da" & D1=$!; sleep 0.5; disp db B "$SANDBOX/x.db" & D2=$!
    # Dispatch start-up (worker probe, plan parse, lock) takes a few seconds:
    # poll for the moment both seats are alive rather than guess a delay.
    seen=0; polls=0; rts=0
    while [ "$polls" -lt 60 ]; do
        n=$(seat_trees); [ "$n" -gt "$seen" ] && seen=$n
        n=$(find "$HOME/dev/agent-runtime" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-product-[0-9]*' | wc -l | tr -d ' '); [ "$n" -gt "$rts" ] && rts=$n
        [ "$seen" -ge 2 ] && [ "$rts" -ge 2 ] && break
        sleep 0.5; polls=$((polls + 1))
    done
    check "two seat worktrees from two dispatches alive at once" "2" "$seen"
    check "two dispatch runtimes alive at once" "2" "$rts"
    check "two branch locks held" "2" "$(find "$HOME/dev/dispatch-locks/product" -name '*.lock' | wc -l | tr -d ' ')"
    wait $D1 $D2
    check "dispatch on feat/da exit" "0" "$(cat "$SANDBOX/x.da")"
    check "dispatch on feat/db exit" "0" "$(cat "$SANDBOX/x.db")"
    check "neither dispatch queued" "0" "$(cat "$SANDBOX/disp-da.log" "$SANDBOX/disp-db.log" | grep -c 'Another dispatch holds')"
    check "worktrees after both" "0" "$(seat_trees)"
    # dispatch ids are <utc second>-<repo>-<pid>; the direct-seat runtimes above stay
    check "localhost runtimes removed with their dispatches" "0" "$(find "$HOME/dev/agent-runtime" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-product-[0-9]*' | wc -l | tr -d ' ')"
    check "each dispatch wrote its own event file" "2" "$(ls "$FLEET/logs/fleet-events"/[0-9]*-product-[0-9]*.jsonl | wc -l | tr -d ' ')"
    check "the two dispatch ids differ" "2" "$(grep -ho '"dispatch_id":"[^"]*"' "$FLEET/logs/fleet-events"/[0-9]*-product-[0-9]*.jsonl | sort -u | wc -l | tr -d ' ')"

    echo ""
    echo "== two real dispatches on the same branch serialize =="
    disp da A2 "$SANDBOX/x.da" & D3=$!; sleep 2; disp da2 A3 "$SANDBOX/x.da2" & D4=$!
    sleep 3
    check "one seat worktree while the second dispatch queues" "1" "$(seat_trees)"
    check "second dispatch reports the holder" "1" "$(grep -c 'Another dispatch holds product branch feat-da' "$SANDBOX/disp-da2.log")"
    wait $D3 $D4
    check "first dispatch exit" "0" "$(cat "$SANDBOX/x.da")"
    check "second dispatch exit" "0" "$(cat "$SANDBOX/x.da2")"
    check "feat/da commits in dispatch order" \
          "chore: seat work A3 chore: seat work A2 chore: seat work A chore: seed" "$(origin_log feat/da)"
    check "worktrees after both" "0" "$(seat_trees)"
else
    echo "  skip bash >= 4 not found: the real-dispatch rows need scripts/dispatch.sh"
fi

echo ""
# Last: these seats push to origin/main, which every later branch would inherit.
echo "== a seat whose branch is main starts: the fetch point holds no branch =="
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=m seat 20 main > "$SANDBOX/main.log" 2>&1
check "seat on main exit" "0" "$?"
check "main reached origin" "chore: seat work m chore: seed" "$(origin_log main)"
check "fetch point still detached" "detached" "$(git -C "$FETCH" symbolic-ref -q --short HEAD || echo detached)"
check "no fetch-point error in the log" "0" "$(grep -c 'checked out in the fetch point' "$SANDBOX/main.log")"
git -C "$FETCH" checkout -q main
echo dirty > "$FETCH/README.md"
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=m2 seat 21 main > "$SANDBOX/main2.log" 2>&1
check "a dirty fetch point on main blocks a seat on main" "1" "$?"
check "the error names the uncommitted changes" "1" "$(grep -c 'which has uncommitted changes' "$SANDBOX/main2.log")"
git -C "$FETCH" checkout -q -- README.md
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=m3 seat 22 main > "$SANDBOX/main3.log" 2>&1
check "a clean fetch point on main is detached and the seat starts" "0" "$?"
check "detach reported" "1" "$(grep -c 'Fetch point was left on main; detaching it' "$SANDBOX/main3.log")"
check "main on origin" "chore: seat work m3 chore: seat work m chore: seed" "$(origin_log main)"
# A commit a seat left on local main without pushing (a rejected push, a kill
# between commit and push) is not thrown away by the fetch-point refresh: the
# ref only fast-forwards, and the next seat on main runs on the local tip.
git -C "$FETCH" checkout -q main && echo local > "$FETCH/local.txt" \
    && git -C "$FETCH" add local.txt && git -C "$FETCH" commit -q -m "chore: unpushed local main" \
    && git -C "$FETCH" checkout -q --detach
SHIM_WORK_SLEEP=1 SHIM_WORK_TAG=m4 seat 25 main > "$SANDBOX/main4.log" 2>&1
check "a seat on a local main that is ahead of origin starts" "0" "$?"
check "the unpushed local commit reached origin under the seat's" "chore: seat work m4 chore: unpushed local main chore: seat work m3 chore: seat work m chore: seed" "$(origin_log main)"

echo "== delivery requires a new commit on every attempt =="
SHIM_MODE=success seat 90 feat/no-delivery > "$SANDBOX/no-delivery.log" 2>&1
check "zero exit without commit is no-delivery" 79 "$?"
SHIM_MODE=success seat 91 feat/r1 > "$SANDBOX/old-delivery.log" 2>&1
check "existing branch commit is not fresh delivery" 79 "$?"

echo "== worker records long paid-credit cooldown =="
OUT_OF_CREDIT_COOLDOWN_MINUTES=120 SHIM_MODE=credit seat 92 feat/credit > "$SANDBOX/credit.log" 2>&1
check "credit exhaustion has distinct exit" 76 "$?"
credit_until=$(cat "$FLEET/logs/provider-state/claude.credit-until" 2>/dev/null || echo 0)
check_true "configured credit cooldown lasts nearly two hours" test "$credit_until" -gt "$(( $(date +%s) + 7100 ))"
check_true "credit event is recorded" grep -q '|out-of-credit$' "$FLEET/logs/provider-state/ratecap.log"
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nprintf "[]\\n"\n' > "$SANDBOX/bin/gh"
chmod +x "$SANDBOX/bin/gh"
PATH="$SANDBOX/bin:$PATH" SHIM_WORK_SLEEP=0 SHIM_WORK_TAG=missing-pr seat 93 feat/missing-pr d-pr 'Open a pull request' > "$SANDBOX/missing-pr.log" 2>&1
check "new commit without requested PR is no-delivery" 79 "$?"
printf '#!/bin/sh\nprintf '\''[{"number":12}]\\n'\''\n' > "$SANDBOX/bin/gh"
PATH="$SANDBOX/bin:$PATH" SHIM_WORK_SLEEP=0 SHIM_WORK_TAG=with-pr seat 94 feat/with-pr d-pr2 'Open a PR' > "$SANDBOX/with-pr.log" 2>&1
check "new commit with requested PR delivers" 0 "$?"

echo ""
echo "== $pass passed, $fail failed =="
if [ "$fail" -ne 0 ]; then
    # Seat logs, for a failure on a machine without a shell to look at them.
    for f in "$SANDBOX"/*.log; do
        [ -f "$f" ] || continue
        echo "---- $(basename "$f") (last 40 lines) ----"; tail -40 "$f"
    done
fi
[ "$fail" -eq 0 ]
