#!/bin/bash
set -euo pipefail

# Run a Claude agent on a remote machine via SSH
# Usage: ./scripts/run-remote.sh <host> <repo-url> <agent> <task> [branch]
#
# WARNING: This script uses --dangerously-skip-permissions for unattended
# execution. The agent can read/write/execute without prompts. Only run
# on trusted machines with trusted repos.
#
# Prerequisites on remote machine:
#   1. Claude Code installed (npm install -g @anthropic-ai/claude-code)
#   2. Agents bootstrapped (./scripts/bootstrap.sh claude)
#   3. GitHub SSH key configured
#
# Examples:
#   ./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/olympus-platform.git go-backend "fix auth bug #123"
#   ./scripts/run-remote.sh mac-mini-2 git@github.com:Arlencho/olympus-platform.git web-frontend "build settings page" feat/settings

HOST="${1:?Usage: run-remote.sh <host> <repo-url> <agent> <task> [branch] [--log-dir <dir>]}"
REPO_URL="${2:?Missing repo URL}"
AGENT="${3:?Missing agent name}"
TASK="${4:?Missing task description}"
BRANCH="${5:-fix/${AGENT}-$(date +%s)}"
shift 5 2>/dev/null || shift $#

# Parse optional flags
# Default log dir: \$HOME expands worker-side (see WORK_DIR note below).
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
WORK_DIR="\$HOME/dev/$REPO_NAME"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${REPO_NAME}-${BRANCH//\//-}-${TIMESTAMP}.log"

echo "=== Remote Agent Execution ==="
echo "Host:   $HOST"
echo "Repo:   $REPO_NAME"
echo "Agent:  $AGENT"
echo "Model:  ${MODEL:-default}"
echo "Branch: $BRANCH"
echo "Task:   $TASK"
echo "Log:    $LOG_DIR/$LOG_FILE"
echo ""

# Verify SSH connectivity
echo "Checking SSH connection..."
ssh -o ConnectTimeout=5 "$HOST" "echo 'Connected'" || {
    echo "ERROR: Cannot SSH to $HOST"
    echo "Make sure SSH key is configured: ssh-copy-id $HOST"
    exit 1
}

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
# Path here is dispatcher-absolute ($HOME expands locally) — WORK_DIR above is worker-relative.
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

# Copy guardrails to remote
GUARDRAILS_SCRIPT="$SCRIPT_DIR/guardrails.sh"
GUARDRAILS_CONFIG="$SCRIPT_DIR/../config/guardrails.yaml"
if [ -f "$GUARDRAILS_SCRIPT" ] && [ -f "$GUARDRAILS_CONFIG" ]; then
    echo "Copying guardrails to $HOST..."
    ssh "$HOST" "mkdir -p ~/dev/guardrails/config"
    scp -q "$GUARDRAILS_SCRIPT" "$HOST:~/dev/guardrails/guardrails.sh"
    scp -q "$GUARDRAILS_CONFIG" "$HOST:~/dev/guardrails/config/guardrails.yaml"
    ssh "$HOST" "chmod +x ~/dev/guardrails/guardrails.sh"
else
    echo "WARNING: Guardrails not found locally, skipping safety hooks"
fi

# Ship the provider launcher runtime to the worker (same scp precedent as
# guardrails above). lib.sh + the chosen provider's launch.sh land flat in
# ~/dev/agent-runtime/; non-claude providers also get the role charter, which
# their launcher injects into the prompt (claude resolves --agent natively).
PROVIDER_LAUNCHER="$SCRIPT_DIR/../providers/$PROVIDER/launch.sh"
PROVIDER_LIB="$SCRIPT_DIR/../providers/lib.sh"
RATECAP_CONF="$SCRIPT_DIR/../config/ratecap-patterns.conf"
if [ -f "$PROVIDER_LAUNCHER" ] && [ -f "$PROVIDER_LIB" ]; then
    echo "Shipping $PROVIDER launcher runtime to $HOST..."
    ssh "$HOST" "mkdir -p ~/dev/agent-runtime/roles ~/dev/agent-runtime/skills ~/dev/agent-runtime/config"
    scp -q "$PROVIDER_LIB" "$HOST:~/dev/agent-runtime/lib.sh"
    scp -q "$PROVIDER_LAUNCHER" "$HOST:~/dev/agent-runtime/launch.sh"
    [ -f "$RATECAP_CONF" ] && scp -q "$RATECAP_CONF" "$HOST:~/dev/agent-runtime/ratecap-patterns.conf"
    if [ "$PROVIDER" != "claude" ] && [ -f "$SCRIPT_DIR/../roles/$AGENT.md" ]; then
        scp -q "$SCRIPT_DIR/../roles/$AGENT.md" "$HOST:~/dev/agent-runtime/roles/$AGENT.md"
    fi
    # Global L2 skills + map (for local skill-inject / offline debugging on worker)
    if [ -d "$SCRIPT_DIR/../skills" ]; then
        scp -rq "$SCRIPT_DIR/../skills/." "$HOST:~/dev/agent-runtime/skills/" 2>/dev/null || true
    fi
    if [ -f "$SCRIPT_DIR/../config/role-skills.yaml" ]; then
        scp -q "$SCRIPT_DIR/../config/role-skills.yaml" "$HOST:~/dev/agent-runtime/config/role-skills.yaml" 2>/dev/null || true
    fi
else
    echo "ERROR: launcher runtime for provider '$PROVIDER' not found ($PROVIDER_LAUNCHER)" >&2
    exit 1
fi

# Execute on remote
echo "Starting agent on $HOST..."
ssh "$HOST" bash -s <<REMOTE_SCRIPT
set -euo pipefail

# Non-interactive ssh shells get a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin) —
# the vendor CLIs (kimi, grok, claude) install under \$HOME. Prepend the known
# locations (expanded worker-side) so launch.sh can find its CLI.
export PATH="\$HOME/.kimi-code/bin:\$HOME/.grok/bin:\$HOME/.local/bin:\$PATH"

# Create log directory
mkdir -p $LOG_DIR

# Ensure repo exists
if [ ! -d "$WORK_DIR" ]; then
    echo "Cloning $REPO_URL..."
    mkdir -p ~/dev
    cd ~/dev
    git clone "$REPO_URL"
fi

cd "$WORK_DIR"

# Update and land on the task branch. The branch may already exist (producer
# pushed it; a critic reviews the same branch next) — create only if missing,
# track origin when it only exists remotely, fast-forward when local.
git fetch origin
git checkout main
git pull origin main
if git checkout "$BRANCH" 2>/dev/null; then
    git pull origin "$BRANCH" 2>/dev/null || true
elif git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
else
    git checkout -b "$BRANCH"
fi

# Install guardrails git hooks
if [ -x ~/dev/guardrails/guardrails.sh ]; then
    ~/dev/guardrails/guardrails.sh install "$WORK_DIR"
fi

# Run the agent through the provider launcher (it verifies its own CLI is
# installed + logged in, exiting 69 if not). $MODEL / $AGENT expand
# dispatcher-side through the unquoted heredoc; the task arrives base64-encoded
# (see above) and is decoded HERE on the worker — \$( … ) stays remote, so no
# task character ever enters this script's parse. ~ paths expand on the worker.
# set +e so a launcher exit (69/75/1) is captured, not aborted.
echo "Starting $PROVIDER launcher for agent $AGENT (model: ${MODEL:-default})..."
echo "Logging to: $LOG_DIR/$LOG_FILE"
FULL_TASK=\$(printf '%s' "$FULL_TASK_B64" | base64 -d)
set +e
AGENT_MODEL="$MODEL" ROLES_DIR=~/dev/agent-runtime/roles \
    RATECAP_PATTERNS=~/dev/agent-runtime/ratecap-patterns.conf \
    bash ~/dev/agent-runtime/launch.sh "$AGENT" "\$FULL_TASK" 2>&1 | tee "$LOG_DIR/$LOG_FILE"
AGENT_EXIT=\${PIPESTATUS[0]}
set -e

# Push the branch
echo "Pushing branch $BRANCH..."
git push origin "$BRANCH" 2>/dev/null || echo "Nothing to push (no changes)"

echo ""
echo "Log saved: $LOG_DIR/$LOG_FILE"
echo "Done on $HOST"
exit \$AGENT_EXIT
REMOTE_SCRIPT

REMOTE_EXIT=$?

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
# Expand WORK_DIR for local host when querying git (remote still uses ssh)
if [ "$HOST" = "localhost" ] || [ "$HOST" = "127.0.0.1" ]; then
    LOCAL_WORK="$HOME/dev/$REPO_NAME"
    BASE_SHA=$(cd "$LOCAL_WORK" 2>/dev/null && git rev-parse --short origin/main 2>/dev/null || echo "unknown")
    HEAD_SHA=$(cd "$LOCAL_WORK" 2>/dev/null && git rev-parse --short "$BRANCH" 2>/dev/null || echo "unknown")
    FILES_TOUCHED=$(cd "$LOCAL_WORK" 2>/dev/null && git diff --name-only "origin/main...$BRANCH" 2>/dev/null || echo "")
    DIFF_STAT=$(cd "$LOCAL_WORK" 2>/dev/null && git diff --shortstat "origin/main...$BRANCH" 2>/dev/null || echo "")
else
    BASE_SHA=$(ssh "$HOST" "cd $WORK_DIR && git rev-parse --short origin/main" 2>/dev/null || echo "unknown")
    HEAD_SHA=$(ssh "$HOST" "cd $WORK_DIR && git rev-parse --short $BRANCH" 2>/dev/null || echo "unknown")
    FILES_TOUCHED=$(ssh "$HOST" "cd $WORK_DIR && git diff --name-only origin/main...$BRANCH" 2>/dev/null || echo "")
    DIFF_STAT=$(ssh "$HOST" "cd $WORK_DIR && git diff --shortstat origin/main...$BRANCH" 2>/dev/null || echo "")
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

# Agent intent block (handoff.md at repo root) — merged alongside the skeleton.
if ssh "$HOST" "test -f $WORK_DIR/handoff.md" 2>/dev/null; then
    ssh "$HOST" "cat $WORK_DIR/handoff.md" > "$HANDOFF_DIR/$TASK_ID.md" 2>/dev/null || true
    echo "Handoff recorded: $HANDOFF_DIR/$TASK_ID.{jsonl,md}"
elif [ "$REMOTE_EXIT" -eq 0 ]; then
    echo "WARNING: $AGENT left no handoff.md (soft phase — task still counts as done)" >&2
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
    FAIL_TAIL=$(ssh "$HOST" "tail -3 $LOG_DIR/$LOG_FILE 2>/dev/null" || echo "no log available")
    "$SCRIPT_DIR/learnings.sh" add "$REPO_NAME" "$AGENT" failure \
        "Agent exited $REMOTE_EXIT. Last output: $FAIL_TAIL" \
        --severity medium 2>/dev/null || true
    echo "Recorded failure learning for $REPO_NAME/$AGENT"
fi

echo ""
echo "=== Agent completed on $HOST ==="
echo "Remote log: $HOST:$REMOTE_LOG_PATH"
echo "Check: gh pr list -R $(echo $REPO_URL | sed 's/.*://' | sed 's/\.git//')"
