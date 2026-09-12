#!/bin/bash
set -euo pipefail

# Run a fleet agent on a worker host.
# Usage: ./scripts/run-remote.sh <host> <repo-url> <agent> <task> [branch]
#
# WARNING: This script uses --dangerously-skip-permissions for unattended
# execution. The agent can read/write/execute without prompts. Only run
# on trusted machines with trusted repos.
#
# Localhost / 127.0.0.1: runs **in-process** (no SSH). Required so Claude
# OAuth/keychain from `claude login` is visible. Non-interactive `ssh localhost`
# sees loggedIn:false even when the desktop session is authenticated.
#
# True remote hosts: still use SSH + scp (Mac Minis, etc.).
#
# Prerequisites on worker:
#   1. Vendor CLIs installed + logged in (claude / kimi / grok)
#   2. Agents bootstrapped where needed
#   3. GitHub SSH key configured
#
# Examples:
#   ./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/olympus-platform.git go-backend "fix auth bug #123"
#   ./scripts/run-remote.sh localhost git@github.com:Arlencho/dev-agents.git devops "task" feat/x

HOST="${1:?Usage: run-remote.sh <host> <repo-url> <agent> <task> [branch] [--log-dir <dir>]}"
REPO_URL="${2:?Missing repo URL}"
AGENT="${3:?Missing agent name}"
TASK="${4:?Missing task description}"
BRANCH="${5:-fix/${AGENT}-$(date +%s)}"
shift 5 2>/dev/null || shift $#

# Local worker? Never SSH — Claude OAuth does not survive BatchMode ssh.
IS_LOCAL=0
case "$HOST" in
    localhost|127.0.0.1) IS_LOCAL=1 ;;
esac

# Run a command string on the worker (local bash -c or ssh).
remote_run() {
    if [ "$IS_LOCAL" -eq 1 ]; then
        bash -c "$1"
    else
        ssh "$HOST" "$1"
    fi
}

# Copy a local file to worker path (relative to home or absolute under $HOME).
# Usage: remote_put <local> <remote-path-under-home> e.g. remote_put a.sh dev/guardrails/a.sh
remote_put() {
    local src="$1" dest_rel="$2"
    if [ "$IS_LOCAL" -eq 1 ]; then
        mkdir -p "$HOME/$(dirname "$dest_rel")"
        cp -f "$src" "$HOME/$dest_rel"
    else
        ssh "$HOST" "mkdir -p ~/$(dirname "$dest_rel")"
        scp -q "$src" "$HOST:~/$dest_rel"
    fi
}

# Copy a local directory tree to worker path under home.
remote_put_dir() {
    local src="$1" dest_rel="$2"
    if [ "$IS_LOCAL" -eq 1 ]; then
        mkdir -p "$HOME/$dest_rel"
        cp -R "$src"/. "$HOME/$dest_rel/" 2>/dev/null || true
    else
        ssh "$HOST" "mkdir -p ~/$dest_rel"
        scp -rq "$src/." "$HOST:~/$dest_rel/" 2>/dev/null || true
    fi
}

# Pipe a bash script (stdin) to the worker.
remote_bash_s() {
    if [ "$IS_LOCAL" -eq 1 ]; then
        bash -s
    else
        ssh "$HOST" bash -s
    fi
}

# Parse optional flags
# Default log dir: \$HOME expands worker-side (see FETCH_DIR note below).
LOG_DIR="\$HOME/dev/agent-logs"
# Model tier or ID, set by dispatch.sh via AGENT_MODEL env var (e.g. opus,
# sonnet, haiku, or an explicit model ID). Empty means use the CLI default.
MODEL="${AGENT_MODEL:-}"
# Provider (CLI vendor) set by dispatch.sh via AGENT_PROVIDER (claude|kimi|grok).
# Selects which providers/<provider>/launch.sh runs the agent. All authenticate
# via subscription login on the worker — no API keys anywhere.
PROVIDER="${AGENT_PROVIDER:-claude}"
# Wave number set by dispatch.sh via AGENT_WAVE (default 1 for direct runs).
# Drives the handoff ledger location (wave-plans/<wave>/handoffs/).
WAVE="${AGENT_WAVE:-1}"
while [ $# -gt 0 ]; do
    case "$1" in
        --log-dir)
            LOG_DIR="${2:?--log-dir requires a path}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model requires a value}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_NAME=$(basename "$REPO_URL" .git)
# \$HOME stays literal through the dispatcher-side heredoc expansion and
# expands ON THE WORKER — a quoted "~" would never expand anywhere (latent
# bug: quoted-tilde paths broke fresh clones, cd, and tee on every worker).
#
# Layout on the worker (issue #66):
#   FETCH_DIR  ~/dev/<repo>                          the fetch point: objects and
#              refs only. Seats never check a branch out here again.
#   SEAT_DIR   ~/dev/worktrees/<repo>/<dispatch>/<task>-<branch>
#              one git worktree per seat, added from origin/<branch> when the
#              branch exists on origin, else as a new branch from origin/main.
#              The seat runs, commits and pushes in it.
# The dispatch id groups every seat of one dispatch. dispatch.sh passes
# FLEET_DISPATCH_ID; a direct run gets a private id so it never shares a
# directory with a live dispatch. Kept path-safe.
DISPATCH_ID=$(printf '%s' "${FLEET_DISPATCH_ID:-direct-$(date +%Y%m%d-%H%M%S)-$$}" | tr -c 'A-Za-z0-9._-' '_')
BRANCH_SAFE=$(printf '%s' "$BRANCH" | tr '/ ' '--')
FETCH_DIR="\$HOME/dev/$REPO_NAME"
SEAT_DIR="\$HOME/dev/worktrees/$REPO_NAME/$DISPATCH_ID/${AGENT_TASK_ID:-0}-$BRANCH_SAFE"
#   RUNTIME_DIR ~/dev/agent-runtime/<dispatch>    the launcher runtime, shipped
#              once per dispatch and never written again while a seat may be
#              reading it (the flat ~/dev/agent-runtime/ used to be overwritten
#              by every dispatch under running seats).
RUNTIME_REL="dev/agent-runtime/$DISPATCH_ID"
RUNTIME_DIR="\$HOME/$RUNTIME_REL"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${REPO_NAME}-${BRANCH_SAFE}-${TIMESTAMP}.log"

echo "=== Remote Agent Execution ==="
echo "Host:   $HOST$([ "$IS_LOCAL" -eq 1 ] && echo ' (local, no SSH)')"
echo "Repo:   $REPO_NAME"
echo "Agent:  $AGENT"
echo "Model:  ${MODEL:-default}"
echo "Branch: $BRANCH"
echo "Task:   $TASK"
echo "Log:    $LOG_DIR/$LOG_FILE"
echo "Seat:   $SEAT_DIR"
echo ""

if [ "$IS_LOCAL" -eq 1 ]; then
    # Do not SSH: non-interactive ssh drops Claude OAuth/keychain (loggedIn:false).
    echo "Local worker — running in-session (Claude OAuth / keychain available)"
else
    echo "Checking SSH connection..."
    ssh -o ConnectTimeout=5 "$HOST" "echo 'Connected'" || {
        echo "ERROR: Cannot SSH to $HOST"
        echo "Make sure SSH key is configured: ssh-copy-id $HOST"
        exit 1
    }
fi

# A/B control arm (Phase 1): a task whose text carries the [blind] marker gets
# no handoff slice in its preamble — per-task control, so a plan can hold a
# normal producer and a charter-blind critic in the same wave pair. The marker
# is stripped before the task reaches the agent.
if [[ "$TASK" == *"[blind]"* ]]; then
    TASK="${TASK//\[blind\] /}"
    TASK="${TASK//\[blind\]/}"
    export PREAMBLE_NO_HANDOFF=1
fi

# L2 skill packs (stable playbooks) — NOT folded into preamble (L3 case file).
# See docs/proposals/skills-evolution-SYNTHESIS.md. Missing skills → empty, non-fatal.
PRODUCT_REPO_PATH="$HOME/dev/$REPO_NAME"
SKILLS=$("$SCRIPT_DIR/skill-inject.sh" "$AGENT" "$PRODUCT_REPO_PATH" 2>/dev/null || true)
if [ -n "$SKILLS" ]; then
    echo "Injected L2 skill packs into prompt"
fi

# Generate preamble (includes CLAUDE.md, learnings, parallel sessions, git state, issue context)
# Path here is dispatcher-absolute ($HOME expands locally); FETCH_DIR above is worker-relative.
# Wave + provider enable the handoff slice + continuity line (Phase 1).
PREAMBLE=$("$SCRIPT_DIR/preamble.sh" "$PRODUCT_REPO_PATH" "$AGENT" "$BRANCH" "$WAVE" "$PROVIDER" 2>/dev/null || true)
if [ -n "$PREAMBLE" ]; then
    echo "Injected session preamble into prompt"
fi

# Order: L2 skills → L3 case (preamble) → task  (charter prepended by kimi/grok launchers)
FULL_TASK=""
if [ -n "$SKILLS" ]; then
    FULL_TASK+="$SKILLS

"
fi
if [ -n "$PREAMBLE" ]; then
    FULL_TASK+="$PREAMBLE

"
fi
if [ -n "$FULL_TASK" ]; then
    FULL_TASK+="YOUR TASK: $TASK"
else
    FULL_TASK="$TASK"
fi

# The task text (and preamble) can contain ANY shell-significant characters —
# quotes, parens, apostrophes, URLs. It must never reach the remote shell
# parser through the unquoted heredoc (live-run bug: task text fragmented the
# remote invocation). Encode dispatcher-side, decode on the worker; base64's
# alphabet is inert inside double quotes.
FULL_TASK_B64=$(printf '%s' "$FULL_TASK" | base64)

# Copy guardrails to worker
GUARDRAILS_SCRIPT="$SCRIPT_DIR/guardrails.sh"
GUARDRAILS_CONFIG="$SCRIPT_DIR/../config/guardrails.yaml"
if [ -f "$GUARDRAILS_SCRIPT" ] && [ -f "$GUARDRAILS_CONFIG" ]; then
    echo "Copying guardrails to $HOST..."
    remote_run "mkdir -p ~/dev/guardrails/config"
    remote_put "$GUARDRAILS_SCRIPT" "dev/guardrails/guardrails.sh"
    remote_put "$GUARDRAILS_CONFIG" "dev/guardrails/config/guardrails.yaml"
    remote_run "chmod +x ~/dev/guardrails/guardrails.sh"
else
    echo "WARNING: Guardrails not found locally, skipping safety hooks"
fi

# Ship the launcher runtime to the worker, once per dispatch. The snapshot
# holds every provider launcher (providers/ as laid out in this checkout, so
# launch.sh finds ../lib.sh), every role charter, the skills, the two configs
# and the live-progress pair; nothing in it is seat-specific, so the seats of a
# dispatch share one copy and never write into it. First seat to claim the
# directory ships it (staged locally, copied to <dir>.tmp, renamed into place,
# then marked .ready); the others wait for the marker.
RUNTIME_SRC="$SCRIPT_DIR/.."
if [ ! -f "$RUNTIME_SRC/providers/$PROVIDER/launch.sh" ] || [ ! -f "$RUNTIME_SRC/providers/lib.sh" ]; then
    echo "ERROR: launcher runtime for provider '$PROVIDER' not found ($RUNTIME_SRC/providers/$PROVIDER/launch.sh)" >&2
    exit 1
fi
ship_runtime_once() {
    local dest="~/$RUNTIME_REL" stage waited
    if remote_run "test -f $dest/.ready"; then
        echo "Launcher runtime already shipped for dispatch $DISPATCH_ID"
        return 0
    fi
    if remote_run "mkdir -p ~/dev/agent-runtime && ( set -o noclobber; : > $dest.claim ) 2>/dev/null"; then
        echo "Shipping launcher runtime to $HOST ($dest)..."
        stage=$(mktemp -d)
        mkdir -p "$stage/config" "$stage/scripts" "$stage/roles" "$stage/skills"
        cp -R "$RUNTIME_SRC/providers" "$stage/providers"
        [ -d "$RUNTIME_SRC/roles" ] && cp -R "$RUNTIME_SRC/roles/." "$stage/roles/"
        [ -d "$RUNTIME_SRC/skills" ] && cp -R "$RUNTIME_SRC/skills/." "$stage/skills/"
        [ -f "$RUNTIME_SRC/config/ratecap-patterns.conf" ] && cp "$RUNTIME_SRC/config/ratecap-patterns.conf" "$stage/config/"
        [ -f "$RUNTIME_SRC/config/role-skills.yaml" ] && cp "$RUNTIME_SRC/config/role-skills.yaml" "$stage/config/"
        [ -f "$SCRIPT_DIR/seat-progress.py" ] && cp "$SCRIPT_DIR/seat-progress.py" "$stage/scripts/"
        [ -f "$SCRIPT_DIR/fleet-events.sh" ] && cp "$SCRIPT_DIR/fleet-events.sh" "$stage/scripts/"
        remote_run "rm -rf $dest.tmp"
        if [ "$IS_LOCAL" -eq 1 ]; then
            cp -R "$stage" "$HOME/$RUNTIME_REL.tmp"
        else
            scp -rq "$stage" "$HOST:$dest.tmp"
        fi
        rm -rf "$stage"
        remote_run "mv $dest.tmp $dest && : > $dest/.ready && rm -f $dest.claim"
        return 0
    fi
    waited=0
    while ! remote_run "test -f $dest/.ready"; do
        sleep 1
        waited=$(( waited + 1 ))
        if [ "$waited" -ge 120 ]; then
            echo "ERROR: another seat claimed the launcher runtime $dest but never marked it ready" >&2
            exit 1
        fi
    done
    echo "Launcher runtime shipped by another seat of dispatch $DISPATCH_ID"
}
ship_runtime_once

# Live seat activity: the launcher pipes the agent stream through
# scripts/seat-progress.py, which emits redaction-safe seat_progress events into
# the dispatcher's event stream (tool name, one repo-relative path, four counts,
# one phase word; never a prompt, an argument or a command line). The reader
# makes paths relative to SEAT_REPO_DIR, which is the seat worktree: a path
# inside it stays repo-relative, and anything else, the fetch point included,
# is written as the literal outside-repo (docs/experience-data.md, redaction law).
#
# Local worker only: the event stream file lives on the dispatcher, so a true
# remote host would append to a path that is not the Floor's. Without this env
# the reader degrades to a plain pass-through and the log is unchanged.
# Emitted as export lines into the worker env block below; a path value keeps
# its literal \$HOME so it expands on the worker.
PROGRESS_ENV=""
if [ "$IS_LOCAL" -eq 1 ] && [ -n "${FLEET_EVENTS_FILE:-}" ] && [ -f "$SCRIPT_DIR/seat-progress.py" ]; then
    PROGRESS_ENV="export AGENT_STREAM_READER=\"$RUNTIME_DIR/scripts/seat-progress.py\"
export FLEET_EVENTS_SH=\"$RUNTIME_DIR/scripts/fleet-events.sh\"
export FLEET_EVENTS_FILE=$(printf '%q' "$FLEET_EVENTS_FILE")
export FLEET_DISPATCH_ID=$(printf '%q' "${FLEET_DISPATCH_ID:-}")
export SEAT_TASK_ID=$(printf '%q' "${AGENT_TASK_ID:-0}")
export SEAT_AGENT=$(printf '%q' "$AGENT")
export SEAT_REPO_DIR=\"$SEAT_DIR\""
    echo "Live seat activity: seat_progress events → $(basename "$FLEET_EVENTS_FILE")"
fi

# Execute on worker (local bash -s or ssh bash -s). Two heredocs feed one
# worker shell: the first, unquoted, carries dispatcher values as plain
# assignments (%q-quoted, so no task or branch character reaches the worker's
# parser); the second is quoted and runs verbatim, so worker-side code needs no
# escaping. A path value that carries a literal $HOME expands on the worker.
# set +e around the pipeline: under set -e a non-zero seat exit (1 / 69 / 75)
# used to abort run-remote right here, before the ledger, the failover event,
# the cooldown file and the failure learning below were ever written.
echo "Starting agent on $HOST..."
set +e
{
    cat <<WORKER_ENV
HOST=$(printf '%q' "$HOST")
LOG_DIR="$LOG_DIR"
LOG_FILE=$(printf '%q' "$LOG_FILE")
REPO_URL=$(printf '%q' "$REPO_URL")
BRANCH=$(printf '%q' "$BRANCH")
AGENT=$(printf '%q' "$AGENT")
PROVIDER=$(printf '%q' "$PROVIDER")
MODEL=$(printf '%q' "$MODEL")
DISPATCH_ID=$(printf '%q' "$DISPATCH_ID")
FETCH_DIR="$FETCH_DIR"
SEAT_DIR="$SEAT_DIR"
RUNTIME_DIR="$RUNTIME_DIR"
KEEP_FAILED=$(printf '%q' "${FLEET_KEEP_FAILED_WORKTREES:-0}")
SEAT_WAIT_POLL_S=$(printf '%q' "${SEAT_WAIT_POLL_S:-5}")
FULL_TASK_B64=$(printf '%q' "$FULL_TASK_B64")
$PROGRESS_ENV
WORKER_ENV
    cat <<'WORKER'
set -euo pipefail

# Ensure vendor CLIs are on PATH (ssh bare PATH; local session may already have them).
export PATH="$HOME/.kimi-code/bin:$HOME/.grok/bin:$HOME/.local/bin:$PATH"

mkdir -p "$LOG_DIR"

# ---- fetch point: clone once, then only ever fetch ----
# Every fetch-point operation (clone, fetch, hook install, worktree add /
# remove / prune) runs under one per-repo lock: the seats of a wave start
# within the same second, and two fetches into one .git race on ref locks
# (two clones of a missing fetch point race on the directory itself). mkdir
# is atomic; the pid inside lets a later seat clear the lock of a dead one.
mkdir -p "$(dirname "$FETCH_DIR")"
FP_LOCK="$FETCH_DIR.seat-lock"
fp_lock() {
    local owner
    until mkdir "$FP_LOCK" 2>/dev/null; do
        owner=$(cat "$FP_LOCK/pid" 2>/dev/null || echo "")
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$FP_LOCK"
            continue
        fi
        # A lock with no pid for over a minute: its taker died between mkdir and the write.
        if [ -z "$owner" ] && [ -n "$(find "$FP_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
            rm -rf "$FP_LOCK"
            continue
        fi
        sleep 1
    done
    echo "$$" > "$FP_LOCK/pid"
}
fp_unlock() {
    [ "$(cat "$FP_LOCK/pid" 2>/dev/null || echo "")" = "$$" ] && rm -rf "$FP_LOCK"
    return 0
}

fp_lock
if [ ! -d "$FETCH_DIR" ]; then
    echo "Cloning $REPO_URL..."
    git clone "$REPO_URL" "$FETCH_DIR"
fi
cd "$FETCH_DIR"
FETCH_DIR=$(pwd -P)   # git prints real paths in `worktree list`; compare like with like
git fetch --prune origin

# The fetch point never checks a task branch out again. One left there by the
# shared-checkout flow would block `git worktree add` for that branch forever,
# so park HEAD on main once. A dirty tree is left alone and reported.
head_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
if [ -n "$head_branch" ] && [ "$head_branch" != "main" ]; then
    if [ -z "$(git status --porcelain)" ]; then
        echo "Fetch point was left on $head_branch; parking it on main"
        git checkout -q main
        head_branch=main
    else
        echo "WARNING: fetch point $FETCH_DIR is on $head_branch with uncommitted changes; a seat on that branch cannot start until it is cleaned by hand" >&2
    fi
fi
# Keep main fresh for the preamble's git state: a fast-forward of the ref the
# fetch point already sits on, never a checkout of another branch.
if [ "$head_branch" = "main" ] && [ -z "$(git status --porcelain)" ]; then
    git merge -q --ff-only origin/main 2>/dev/null || true
fi

# Guardrail hooks live in the fetch point's .git/hooks and apply to every
# linked worktree, so one install covers every seat.
if [ -x "$HOME/dev/guardrails/guardrails.sh" ]; then
    "$HOME/dev/guardrails/guardrails.sh" install "$FETCH_DIR"
fi

# ---- seat worktree ----
# Teardown runs on every exit path: the normal end, a set -e abort, a launcher
# exit of 1 / 69 / 75, and INT / TERM / HUP. The worktree is removed even when
# it holds uncommitted work (the push above is the delivery; the log says what
# happened), unless the seat failed and FLEET_KEEP_FAILED_WORKTREES=1 asks for
# failed trees to stay for inspection. The branch ref survives either way. The
# empty per-dispatch and per-repo directories go with the last seat.
SEAT_ADDED=false
seat_teardown() {
    local rc="$1"
    set +e
    trap - EXIT INT TERM HUP
    [ "$SEAT_ADDED" = true ] || return 0
    cd "$FETCH_DIR" || return 0
    fp_lock
    git worktree unlock "$SEAT_DIR" 2>/dev/null
    if [ "$rc" -ne 0 ] && [ "$KEEP_FAILED" = 1 ]; then
        echo "Seat exited $rc; keeping its worktree for inspection (FLEET_KEEP_FAILED_WORKTREES=1): $SEAT_DIR"
    else
        git worktree remove --force "$SEAT_DIR" || echo "WARNING: could not remove seat worktree $SEAT_DIR" >&2
        rmdir "$(dirname "$SEAT_DIR")" 2>/dev/null
        rmdir "$(dirname "$(dirname "$SEAT_DIR")")" 2>/dev/null
    fi
    git worktree prune
    fp_unlock
}
trap 'seat_teardown $?' EXIT
trap 'seat_teardown 130; exit 130' INT
trap 'seat_teardown 143; exit 143' TERM
trap 'seat_teardown 129; exit 129' HUP

# A branch can only be checked out in one worktree. Every seat locks its
# worktree with its pid in the reason (`git worktree lock`), which is what a
# later seat on the same branch reads: a live holder is waited for (the
# fetch-point lock is released while sleeping so the holder can tear down),
# a dead one (killed run, or a tree kept by FLEET_KEEP_FAILED_WORKTREES) is
# cleared: a clean tree is removed, a tree with uncommitted work is moved aside
# next to itself and pruned, so no work is destroyed and the branch is free.
# Two seats on different branches never meet here and run side by side.
branch_holder() {
    git worktree list --porcelain \
        | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{w=substr($0,10)} $0==b{print w}'
}
holder_seat_pid() { # <worktree path> -> pid from the lock reason, or nothing
    git worktree list --porcelain \
        | awk -v w="worktree $1" '$0==w{f=1;next} /^worktree /{f=0} f && /^locked seat pid /{print $4}'
}
wait_for_branch() {
    local holder pid aside
    while :; do
        holder=$(branch_holder)
        [ -n "$holder" ] || return 0
        if [ "$holder" = "$FETCH_DIR" ]; then
            echo "ERROR: $BRANCH is checked out in the fetch point $FETCH_DIR with uncommitted changes; clean it by hand" >&2
            return 1
        fi
        pid=$(holder_seat_pid "$holder")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Branch $BRANCH is held by a live seat (pid $pid) in $holder; waiting ${SEAT_WAIT_POLL_S}s"
            fp_unlock
            sleep "$SEAT_WAIT_POLL_S"
            fp_lock
            continue
        fi
        git worktree unlock "$holder" 2>/dev/null || true
        if git worktree remove "$holder" 2>/dev/null; then
            echo "Removed the dead seat worktree that held $BRANCH: $holder"
        else
            aside="$holder.aside-$(date +%Y%m%d-%H%M%S)"
            mv "$holder" "$aside"
            git worktree prune
            echo "Moved a dead seat worktree with uncommitted work aside: $aside"
        fi
    done
}

# The branch may already exist (producer pushed it; a critic reviews the same
# branch next). From origin when it is there, else a new branch off origin/main.
# A local branch left by an earlier seat is reused and fast-forwarded to origin.
mkdir -p "$(dirname "$SEAT_DIR")"
wait_for_branch
if git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null; then
    git worktree add "$SEAT_DIR" "$BRANCH"
    if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
        git -C "$SEAT_DIR" merge -q --ff-only "origin/$BRANCH" 2>/dev/null \
            || echo "WARNING: local $BRANCH has diverged from origin/$BRANCH; running on the local tip" >&2
    fi
elif git rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
    git worktree add --track -b "$BRANCH" "$SEAT_DIR" "origin/$BRANCH"
else
    git worktree add --no-track -b "$BRANCH" "$SEAT_DIR" origin/main
fi
SEAT_ADDED=true
git worktree lock --reason "seat pid $$ dispatch $DISPATCH_ID" "$SEAT_DIR"
fp_unlock
cd "$SEAT_DIR"
echo "Seat worktree: $SEAT_DIR ($(git rev-parse --short HEAD) on $BRANCH)"

# Run the agent through the provider launcher (it verifies its own CLI is
# installed + logged in, exiting 69 if not). The task arrives base64-encoded
# and is decoded HERE on the worker. set +e so a launcher exit (69/75/1) is
# captured, not aborted.
echo "Starting $PROVIDER launcher for agent $AGENT (model: ${MODEL:-default})..."
echo "Logging to: $LOG_DIR/$LOG_FILE"
FULL_TASK=$(printf '%s' "$FULL_TASK_B64" | base64 -d)
set +e
AGENT_MODEL="$MODEL" ROLES_DIR="$RUNTIME_DIR/roles" \
    RATECAP_PATTERNS="$RUNTIME_DIR/config/ratecap-patterns.conf" \
    bash "$RUNTIME_DIR/providers/$PROVIDER/launch.sh" "$AGENT" "$FULL_TASK" 2>&1 | tee "$LOG_DIR/$LOG_FILE"
AGENT_EXIT=${PIPESTATUS[0]}
set -e

# Push the branch from the seat worktree
echo "Pushing branch $BRANCH..."
git push origin "$BRANCH" 2>/dev/null || echo "Nothing to push (no changes)"

# The agent's intent block (handoff.md at the worktree root) travels with the
# log: the worktree is gone by the time the dispatcher reads it.
if [ -f "$SEAT_DIR/handoff.md" ]; then
    cp "$SEAT_DIR/handoff.md" "$LOG_DIR/${LOG_FILE%.log}.handoff.md"
fi

echo ""
echo "Log saved: $LOG_DIR/$LOG_FILE"
echo "Done on $HOST"
# The EXIT trap tears the worktree down with this code in hand.
exit "$AGENT_EXIT"
WORKER
} | remote_bash_s
REMOTE_EXIT=$?
set -e

# Log path: expand on orchestrator for localhost so ledgers + collection work;
# keep worker-side $HOME form for true remote hosts.
# shellcheck source=../providers/lib.sh
if [ -f "$SCRIPT_DIR/../providers/lib.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../providers/lib.sh"
elif [ -f "$SCRIPT_DIR/../providers/claude/../lib.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../providers/lib.sh"
fi
EFFECTIVE_MODEL="${MODEL:-default}"
if type effective_model >/dev/null 2>&1; then
    EFFECTIVE_MODEL="$(effective_model "$PROVIDER" "${MODEL:-}")"
fi
if [ "$HOST" = "localhost" ] || [ "$HOST" = "127.0.0.1" ]; then
    REMOTE_LOG_PATH="$HOME/dev/agent-logs/$LOG_FILE"
else
    REMOTE_LOG_PATH="\$HOME/dev/agent-logs/$LOG_FILE"
fi

# ── Handoff ledger (Phase 1): orchestrator-authored mechanical fields ──
# The agent writes intent (handoff.md at repo root); everything here is git
# truth pulled from the worker — it cannot be hallucinated downstream.
# APPEND-ONLY: attempts for the same task-id (failover retries) accumulate as
# JSONL lines — truncating would wipe first-vendor provenance + failover event.
# provenance.model = effective model actually used by the launcher
# provenance.requested_model = AGENT_MODEL from routing (may be a Claude tier
# alias ignored by kimi/grok)
HANDOFF_DIR="$SCRIPT_DIR/../wave-plans/$WAVE/handoffs"
TASK_ID="${WAVE}-${AGENT}-$(echo "$BRANCH" | tr '/ ' '--')"
mkdir -p "$HANDOFF_DIR"
# Git truth is read at the fetch point: a worktree's branch ref lives in the
# shared .git, so it is visible here and outlives the worktree's removal.
# ($HOME expands here for the local host; the literal form goes over ssh.)
if [ "$HOST" = "localhost" ] || [ "$HOST" = "127.0.0.1" ]; then
    LOCAL_WORK="$HOME/dev/$REPO_NAME"
    BASE_SHA=$(cd "$LOCAL_WORK" 2>/dev/null && git rev-parse --short origin/main 2>/dev/null || echo "unknown")
    HEAD_SHA=$(cd "$LOCAL_WORK" 2>/dev/null && git rev-parse --short "$BRANCH" 2>/dev/null || echo "unknown")
    FILES_TOUCHED=$(cd "$LOCAL_WORK" 2>/dev/null && git diff --name-only "origin/main...$BRANCH" 2>/dev/null || echo "")
    DIFF_STAT=$(cd "$LOCAL_WORK" 2>/dev/null && git diff --shortstat "origin/main...$BRANCH" 2>/dev/null || echo "")
else
    BASE_SHA=$(ssh "$HOST" "cd $FETCH_DIR && git rev-parse --short origin/main" 2>/dev/null || echo "unknown")
    HEAD_SHA=$(ssh "$HOST" "cd $FETCH_DIR && git rev-parse --short $BRANCH" 2>/dev/null || echo "unknown")
    FILES_TOUCHED=$(ssh "$HOST" "cd $FETCH_DIR && git diff --name-only origin/main...$BRANCH" 2>/dev/null || echo "")
    DIFF_STAT=$(ssh "$HOST" "cd $FETCH_DIR && git diff --shortstat origin/main...$BRANCH" 2>/dev/null || echo "")
fi
FILES_JSON=$(printf '%s\n' "$FILES_TOUCHED" | awk 'NF { printf "%s\"%s\"", (c++ ? ", " : ""), $0 }')
LEDGER_STATUS="failed"
[ "$REMOTE_EXIT" -eq 0 ] && LEDGER_STATUS="done"
printf '{"task_id":"%s","wave":%s,"agent":"%s","provenance":{"vendor":"%s","model":"%s","requested_model":"%s","effective_model":"%s","host":"%s"},"branch":"%s","base_sha":"%s","head_sha":"%s","ts":"%s","status":"%s","orchestrator_fields":{"files_touched":[%s],"diff_stat":"%s","agent_exit":%s,"log":"%s"}}\n' \
    "$TASK_ID" "$WAVE" "$AGENT" "$PROVIDER" "$EFFECTIVE_MODEL" "${MODEL:-}" "$EFFECTIVE_MODEL" "$HOST" \
    "$BRANCH" "$BASE_SHA" "$HEAD_SHA" "$(date -u +%FT%TZ)" "$LEDGER_STATUS" \
    "$FILES_JSON" "$DIFF_STAT" "$REMOTE_EXIT" "$REMOTE_LOG_PATH" \
    >> "$HANDOFF_DIR/$TASK_ID.jsonl"

# Failover transparency: on 75/69, append the failover event BEFORE dispatch
# retries on another vendor — the second vendor inherits a complete picture.
if [ "$REMOTE_EXIT" -eq 75 ] || [ "$REMOTE_EXIT" -eq 69 ]; then
    FAILOVER_REASON="UNAVAILABLE"
    [ "$REMOTE_EXIT" -eq 75 ] && FAILOVER_REASON="RATE_CAP"
    printf '{"task_id":"%s","event":"failover","from_vendor":"%s","reason":"%s","partial":true,"ts":"%s"}\n' \
        "$TASK_ID" "$PROVIDER" "$FAILOVER_REASON" "$(date -u +%FT%TZ)" \
        >> "$HANDOFF_DIR/$TASK_ID.jsonl"
fi

# Agent intent block: handoff.md was written at the seat worktree root and the
# worker copied it next to the log before removing the worktree.
HANDOFF_SRC="${REMOTE_LOG_PATH%.log}.handoff.md"
if [ "$IS_LOCAL" -eq 1 ]; then
    if [ -f "$HANDOFF_SRC" ]; then
        cp "$HANDOFF_SRC" "$HANDOFF_DIR/$TASK_ID.md" 2>/dev/null || true
        echo "Handoff recorded: $HANDOFF_DIR/$TASK_ID.{jsonl,md}"
    elif [ "$REMOTE_EXIT" -eq 0 ]; then
        echo "WARNING: $AGENT left no handoff.md (soft phase — task still counts as done)" >&2
    fi
else
    if ssh "$HOST" "test -f $HANDOFF_SRC" 2>/dev/null; then
        ssh "$HOST" "cat $HANDOFF_SRC" > "$HANDOFF_DIR/$TASK_ID.md" 2>/dev/null || true
        echo "Handoff recorded: $HANDOFF_DIR/$TASK_ID.{jsonl,md}"
    elif [ "$REMOTE_EXIT" -eq 0 ]; then
        echo "WARNING: $AGENT left no handoff.md (soft phase — task still counts as done)" >&2
    fi
fi

# Rate-cap sentinel (exit 75): mark the vendor cooling, log the event, learn it.
# run-remote RECORDS; dispatch.sh REACTS (fails over per routing.yaml chain).
if [ "$REMOTE_EXIT" -eq 75 ]; then
    STATE_DIR="$SCRIPT_DIR/../logs/provider-state"
    mkdir -p "$STATE_DIR"
    date +%s > "$STATE_DIR/${PROVIDER}.cooldown"
    echo "$(date -u +%FT%TZ)|$PROVIDER|$AGENT|$HOST|ratecap" >> "$STATE_DIR/ratecap.log"
    [ -x "$SCRIPT_DIR/learnings.sh" ] && "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$PROVIDER" failure \
        "RATE_CAP: $PROVIDER consumer cap hit by $AGENT on $HOST" --severity high 2>/dev/null || true
    echo "RATE_CAP recorded for $PROVIDER — dispatch will fail over"
fi

# On other failures, auto-record a learning from the last 3 log lines
# (skip 75 — already logged high above).
if [ "$REMOTE_EXIT" -ne 0 ] && [ "$REMOTE_EXIT" -ne 75 ] && [ -x "$SCRIPT_DIR/learnings.sh" ]; then
    if [ "$IS_LOCAL" -eq 1 ]; then
        FAIL_TAIL=$(tail -3 "$HOME/dev/agent-logs/$LOG_FILE" 2>/dev/null || echo "no log available")
    else
        FAIL_TAIL=$(ssh "$HOST" "tail -3 $LOG_DIR/$LOG_FILE 2>/dev/null" || echo "no log available")
    fi
    "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$AGENT" failure \
        "Agent exited $REMOTE_EXIT. Last output: $FAIL_TAIL" \
        --severity medium 2>/dev/null || true
    echo "Recorded failure learning for $REPO_NAME/$AGENT"
fi

echo ""
echo "=== Agent completed on $HOST ==="
echo "Remote log: $HOST:$REMOTE_LOG_PATH"
echo "Check: gh pr list -R $(echo $REPO_URL | sed 's/.*://' | sed 's/\.git//')"
# dispatch.sh classifies the seat by this code (0 / 1 / 69 / 75 / 77).
exit "$REMOTE_EXIT"
