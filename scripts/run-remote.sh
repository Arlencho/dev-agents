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

# Producer roles from config/routing.yaml provider_failover.
DELIVERY_REQUIRED=false
case "$AGENT" in
    web-frontend|go-backend|db-architect|api-designer|devops|test-engineer|mobile|investigate|docs-writer)
        DELIVERY_REQUIRED=true ;;
esac

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
        # Private copy, then rename: the seats of a wave start in the same
        # second and all put the same file, and GNU cp creates a missing
        # destination with O_EXCL, so the second writer used to die with
        # "File exists" (never on macOS, whose cp does not). A rename is
        # atomic, so a seat reading the file sees a whole one either way.
        cp -f "$src" "$HOME/$dest_rel.$$.tmp"
        mv -f "$HOME/$dest_rel.$$.tmp" "$HOME/$dest_rel"
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
# Provider (CLI vendor) set by dispatch.sh via AGENT_PROVIDER (claude|kimi|grok|codex).
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
#              refs only, HEAD detached at origin/main so no branch, main
#              included, is ever checked out here. Seats never check a branch
#              out here again.
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
    # The tilde is for the worker shell (remote_run / scp target), not this one.
    # shellcheck disable=SC2088
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
        [ -f "$SCRIPT_DIR/seat-watchdog.py" ] && cp "$SCRIPT_DIR/seat-watchdog.py" "$stage/scripts/"
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
export SEAT_QUIET_AFTER_S=$(printf '%q' "${SEAT_QUIET_AFTER_S:-1800}")
export SEAT_TOOL_CEILING_S=$(printf '%q' "${SEAT_TOOL_CEILING_S:-5400}")
export SEAT_QUIET_POLL_S=$(printf '%q' "${SEAT_QUIET_POLL_S:-5}")
export SEAT_QUIET_KILL_GRACE_S=$(printf '%q' "${SEAT_QUIET_KILL_GRACE_S:-5}")
FULL_TASK_B64=$(printf '%q' "$FULL_TASK_B64")
DELIVERY_REQUIRED=$(printf '%q' "$DELIVERY_REQUIRED")
DELIVERY_TASK=$(printf '%q' "$TASK")
$PROGRESS_ENV
WORKER_ENV
    cat <<'WORKER'
set -euo pipefail

# Ensure vendor CLIs are on PATH (ssh bare PATH; local session may already have them).
# codex is a Homebrew binary, and the non-interactive ssh PATH on macOS lacks
# /opt/homebrew/bin, so it is appended (appended, so a local session's own
# ordering wins).
export PATH="$HOME/.kimi-code/bin:$HOME/.grok/bin:$HOME/.local/bin:$PATH:/opt/homebrew/bin"

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

# The fetch point has no branch checked out: HEAD stays detached at
# origin/main, so `git worktree add` is free for every branch, main included
# (a branch checked out here, even main, would block a seat on that branch
# forever). A clean tree is detached on every seat start, which also keeps
# the preamble's git state fresh; a dirty tree is left alone and reported with
# its real reason, and a seat that needs that branch says so below.
fetch_point_clean() { [ -z "$(git status --porcelain)" ]; }
head_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
if fetch_point_clean; then
    [ -n "$head_branch" ] && echo "Fetch point was left on $head_branch; detaching it at origin/main"
    git checkout -q --detach origin/main
    # The local main ref feeds the preamble's git state; refresh it without a
    # checkout, fast-forward only: a commit a seat made on main but could not
    # push stays on the ref, and the next seat on main runs on that tip with
    # the "diverged" warning below, like any other branch. Refused, harmlessly,
    # while a seat worktree has main checked out.
    if git merge-base --is-ancestor main origin/main 2>/dev/null; then
        git branch -q -f main origin/main 2>/dev/null || true
    fi
elif [ -n "$head_branch" ]; then
    echo "WARNING: fetch point $FETCH_DIR is on $head_branch with uncommitted changes, so it cannot be detached; a seat on $head_branch cannot start until the tree is cleaned by hand" >&2
else
    echo "WARNING: fetch point $FETCH_DIR has uncommitted changes; left as is" >&2
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
            # Only a dirty tree keeps a branch checked out at the fetch point
            # (a clean one was detached above); name whichever it is.
            if fetch_point_clean; then
                echo "ERROR: $BRANCH is checked out in the fetch point $FETCH_DIR and it could not be detached; run 'git -C $FETCH_DIR checkout --detach origin/main' by hand" >&2
            else
                echo "ERROR: $BRANCH is checked out in the fetch point $FETCH_DIR, which has uncommitted changes; commit or stash them there so the fetch point can be detached" >&2
            fi
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
SEAT_BASE_SHA=$(git rev-parse "refs/heads/$BRANCH")
echo "Starting $PROVIDER launcher for agent $AGENT (model: ${MODEL:-default})..."
echo "Logging to: $LOG_DIR/$LOG_FILE"
FULL_TASK=$(printf '%s' "$FULL_TASK_B64" | base64 -d)
set +e
AGENT_MODEL="$MODEL" ROLES_DIR="$RUNTIME_DIR/roles" \
    RATECAP_PATTERNS="$RUNTIME_DIR/config/ratecap-patterns.conf" \
    bash "$RUNTIME_DIR/providers/$PROVIDER/launch.sh" "$AGENT" "$FULL_TASK" 2>&1 | tee "$LOG_DIR/$LOG_FILE"
AGENT_EXIT=${PIPESTATUS[0]}
set -e

if [ "$AGENT_EXIT" -eq 0 ] && [ "$DELIVERY_REQUIRED" = true ]; then
    source "$RUNTIME_DIR/providers/lib.sh"
    verify_delivery "$SEAT_BASE_SHA" "$BRANCH" "$DELIVERY_TASK" || AGENT_EXIT=$?
fi

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
[ "$REMOTE_EXIT" -eq 79 ] && LEDGER_STATUS="no-delivery"
[ "$REMOTE_EXIT" -eq 76 ] && LEDGER_STATUS="out-of-credit"
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

if [ "$REMOTE_EXIT" -eq 76 ]; then
    STATE_DIR="$SCRIPT_DIR/../logs/provider-state"
    mkdir -p "$STATE_DIR"
    echo $(( $(date +%s) + ${OUT_OF_CREDIT_COOLDOWN_MINUTES:-1440} * 60 )) > "$STATE_DIR/${PROVIDER}.credit-until"
    echo "$(date -u +%FT%TZ)|$PROVIDER|$AGENT|$HOST|out-of-credit" >> "$STATE_DIR/ratecap.log"
fi

# Provider-limit sentinel (exit 78): record the hold where dispatch.sh reads
# it, with the reset time parsed from the seat's own log (issue #84: the
# message says when the session limit resets; the Floor stop row shows it).
# run-remote RECORDS; dispatch.sh holds the seat and probes before any start
# on this provider and model. No vendor cooldown: a limit is not a rate cap.
if [ "$REMOTE_EXIT" -eq 78 ]; then
    STATE_DIR="$SCRIPT_DIR/../logs/provider-state"
    mkdir -p "$STATE_DIR"
    if [ "$IS_LOCAL" -eq 1 ]; then
        LIMIT_LOG_TAIL=$(tail -40 "$REMOTE_LOG_PATH" 2>/dev/null || true)
    else
        LIMIT_LOG_TAIL=$(ssh "$HOST" "tail -40 $REMOTE_LOG_PATH" 2>/dev/null || true)
    fi
    LIMIT_RESET=$(printf '%s\n' "$LIMIT_LOG_TAIL" \
        | grep -oiE 'limit resets (at )?[0-9]{1,2}:[0-9]{2} ?(am|pm)' | tail -1 \
        | grep -oiE '[0-9]{1,2}:[0-9]{2} ?(am|pm)' | tr -d ' ' || true)
    [ -n "$LIMIT_RESET" ] || LIMIT_RESET="unknown"
    LIMIT_MODEL=$(printf '%s' "${MODEL:-default}" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s|%s|%s|%s|%s|%s\n' \
        "$(date +%s)" "$PROVIDER" "${MODEL:-default}" "$LIMIT_RESET" "$AGENT" "$LOG_FILE" \
        > "$STATE_DIR/${PROVIDER}-${LIMIT_MODEL}.limit-hold"
    echo "PROVIDER_LIMIT recorded for $PROVIDER (${MODEL:-default}), resets $LIMIT_RESET, dispatch will hold, not retry"
fi

# Hung sentinel (exit 124): when the watchdog stopped the seat for a tool
# call past the tool ceiling, its stop line in the seat log names the tool.
# Leave the reason where dispatch.sh reads it, so the stop row can name the
# tool too. A plain quiet stop leaves no file and gets the generic row.
if [ "$REMOTE_EXIT" -eq 124 ]; then
    STATE_DIR="$SCRIPT_DIR/../logs/provider-state"
    mkdir -p "$STATE_DIR"
    if [ "$IS_LOCAL" -eq 1 ]; then
        HUNG_TAIL=$(tail -40 "$REMOTE_LOG_PATH" 2>/dev/null || true)
    else
        HUNG_TAIL=$(ssh "$HOST" "tail -40 $REMOTE_LOG_PATH" 2>/dev/null || true)
    fi
    HUNG_WHY=$(printf '%s\n' "$HUNG_TAIL" \
        | grep -oE 'tools? [A-Za-z0-9_,. -]+ still running past the [0-9]+s tool ceiling' \
        | tail -1 || true)
    if [ -n "$HUNG_WHY" ]; then
        printf '%s\n' "$HUNG_WHY" > "$STATE_DIR/seat-hung-${AGENT_TASK_ID:-0}.reason"
    fi
fi

# On other failures, auto-record a learning (skip 75, logged high above).
# The summary is a fixed code plus facts, never a line of agent output: a
# learning is injected into later prompts, and a raw cap or auth phrase in it
# would be echoed by a CLI and read by the launcher's classifier as a fresh
# cap or auth exit for a seat that actually did its work. The log has the
# detail.
if [ "$REMOTE_EXIT" -ne 0 ] && [ "$REMOTE_EXIT" -ne 75 ] && [ -x "$SCRIPT_DIR/learnings.sh" ]; then
    case "$REMOTE_EXIT" in
        69) FAIL_CODE="UNAVAILABLE: $PROVIDER launcher exit 69 (CLI missing or session invalid)" ;;
        77) FAIL_CODE="BLOCKED: guardrails stopped the seat (exit 77)" ;;
        78) FAIL_CODE="PROVIDER_LIMIT: $PROVIDER account ceiling (exit 78); seat held until a probe passes" ;;
        124) FAIL_CODE="HUNG: no model event for ${SEAT_QUIET_AFTER_S:-1800}s; the watchdog stopped the seat (exit 124)"
             [ -n "${HUNG_WHY:-}" ] && FAIL_CODE="HUNG: $HUNG_WHY; the watchdog stopped the seat (exit 124)" ;;
        *)  FAIL_CODE="TASK_FAIL: seat exit $REMOTE_EXIT" ;;
    esac
    "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$AGENT" failure \
        "$FAIL_CODE for $AGENT on $HOST; log $LOG_FILE" \
        --severity medium 2>/dev/null || true
    echo "Recorded failure learning for $REPO_NAME/$AGENT"
fi

echo ""
echo "=== Agent completed on $HOST ==="
echo "Remote log: $HOST:$REMOTE_LOG_PATH"
echo "Check: gh pr list -R $(echo $REPO_URL | sed 's/.*://' | sed 's/\.git//')"
# dispatch.sh classifies the seat by this code (0 / 1 / 69 / 75 / 77 / 78 / 124).
exit "$REMOTE_EXIT"
