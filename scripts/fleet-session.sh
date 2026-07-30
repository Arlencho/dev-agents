#!/usr/bin/env bash
# Fleet Desk — orchestrator / autopilot session bridge (follow live on Ops Floor).
#
# Wraps long-running work so the Floor can show motion without a full wave plan.
# Emits redaction-safe fleet-events/1 into logs/fleet-events/ (same path as dispatch).
#
# Law: never emit transcripts, prompts, absolute paths, or task bodies.
#
# Usage:
#   ./scripts/fleet-session.sh run --label "phase-c-autopilot" -- make test
#   ./scripts/fleet-session.sh run --label "critic" --repo dev-agents -- \
#       ./scripts/dispatch.sh git@github.com:Arlencho/dev-agents.git plan.plan
#
#   # Manual lifecycle (multiple steps in one shell):
#   eval "$(./scripts/fleet-session.sh start --label my-run --repo dev-agents)"
#   ./scripts/fleet-session.sh step --label "building"
#   ./scripts/fleet-session.sh step --label "testing"
#   ./scripts/fleet-session.sh end --status completed
#
# Opt-out: FLEET_EVENTS=0
# Requires: make desk-follow (or desk-live) open to *see* the stream live.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/fleet-events.sh
. "$SCRIPT_DIR/fleet-events.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fleet-session.sh run   [--label L] [--repo R] [--plan P] -- <command...>
  fleet-session.sh start [--label L] [--repo R] [--plan P]
  fleet-session.sh step  [--label L] [--note N]
  fleet-session.sh end   [--status completed|aborted|failed]

  run    start a session, run the command, end with exit status (best for autopilot)
  start  print export lines for FLEET_EVENTS_FILE (eval this in the parent shell)
  step   emit a progress heartbeat (updates Floor last_event_ts + event tail)
  end    close the stream with dispatch_end

Open the Floor first:  make desk-follow
EOF
}

_parse_common() {
  LABEL="session"
  REPO_SLUG="fleet"
  PLAN_LABEL="session"
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) LABEL="${2:-session}"; shift 2 ;;
      --repo)  REPO_SLUG="${2:-fleet}"; shift 2 ;;
      --plan)  PLAN_LABEL="${2:-session}"; shift 2 ;;
      --note)  NOTE="${2:-}"; shift 2 ;;
      --status) END_STATUS="${2:-completed}"; shift 2 ;;
      --) shift; break ;;
      -h|--help) usage; exit 0 ;;
      *) break ;;
    esac
  done
  REST=("$@")
}

_session_init() {
  # mode=session → desk_live projects as wave lanes + session flag
  fleet_events_init "$REPO_SLUG" "session" "$PLAN_LABEL"
  if [ -z "${FLEET_EVENTS_FILE:-}" ]; then
    echo "fleet-session: event stream disabled (FLEET_EVENTS=0 or unwritable dir)" >&2
    return 0
  fi
  fleet_event dispatch_plan waves=1 seats=1 format=session
  fleet_event wave_start wave=1 seats=1 mode=session
  fleet_event seat_dispatch \
    task_id=0 \
    agent=orchestrator \
    branch="session/${LABEL}" \
    wave=1 \
    provider=local \
    model=session \
    worker=localhost \
    attempt=1
  fleet_event progress label="$LABEL" note="session_start"
  echo "fleet-session: stream ${FLEET_DISPATCH_ID}  (Floor: make desk-follow)" >&2
}

cmd="${1:-}"
shift || true
NOTE=""
END_STATUS="completed"

case "$cmd" in
  run)
    _parse_common "$@"
    if [ ${#REST[@]} -eq 0 ]; then
      echo "fleet-session run: missing command after --" >&2
      usage
      exit 2
    fi
    START_TS=$(date +%s)
    _session_init
    set +e
    "${REST[@]}"
    rc=$?
    set -e
    DUR=$(( $(date +%s) - START_TS ))
    if [ "$rc" -eq 0 ]; then
      st=success
      end=completed
    else
      st=failed
      end=failed
    fi
    if [ -n "${FLEET_EVENTS_FILE:-}" ]; then
      FLEET_EVENT_SEQ="$(wc -l < "$FLEET_EVENTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
      fleet_event seat_exit \
        task_id=0 agent=orchestrator branch="session/${LABEL}" wave=1 \
        provider=local worker=localhost status="$st" exit="$rc" duration_s="$DUR" attempt=1
      fleet_event wave_end wave=1 seats=1 succeeded="$([ "$rc" -eq 0 ] && echo 1 || echo 0)" failed="$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
      fleet_event dispatch_end status="$end" total=1 succeeded="$([ "$rc" -eq 0 ] && echo 1 || echo 0)" failed="$([ "$rc" -eq 0 ] && echo 0 || echo 1)" duration_s="$DUR"
    fi
    exit "$rc"
    ;;
  start)
    _parse_common "$@"
    _session_init
    # Parent can eval these to keep emitting into the same stream.
    printf 'export FLEET_EVENTS_FILE=%q\n' "${FLEET_EVENTS_FILE:-}"
    printf 'export FLEET_DISPATCH_ID=%q\n' "${FLEET_DISPATCH_ID:-}"
    printf 'export FLEET_EVENT_SEQ=%q\n' "${FLEET_EVENT_SEQ:-0}"
    ;;
  step)
    _parse_common "$@"
    if [ -z "${FLEET_EVENTS_FILE:-}" ]; then
      # Resume from latest pointer when possible
      base="${FLEET_EVENTS_DIR:-$REPO_ROOT/logs/fleet-events}"
      if [ -f "$base/latest" ]; then
        name="$(tr -d '[:space:]' < "$base/latest")"
        FLEET_EVENTS_FILE="$base/$name"
        FLEET_DISPATCH_ID="${name%.jsonl}"
      fi
    fi
    if [ -z "${FLEET_EVENTS_FILE:-}" ] || [ ! -f "${FLEET_EVENTS_FILE:-}" ]; then
      echo "fleet-session step: no active stream (run start/run first)" >&2
      exit 1
    fi
    FLEET_EVENT_SEQ="$(wc -l < "$FLEET_EVENTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
    fleet_event progress label="${LABEL}" note="${NOTE:-step}"
    ;;
  end)
    _parse_common "$@"
    if [ -z "${FLEET_EVENTS_FILE:-}" ]; then
      base="${FLEET_EVENTS_DIR:-$REPO_ROOT/logs/fleet-events}"
      if [ -f "$base/latest" ]; then
        name="$(tr -d '[:space:]' < "$base/latest")"
        FLEET_EVENTS_FILE="$base/$name"
        FLEET_DISPATCH_ID="${name%.jsonl}"
      fi
    fi
    if [ -z "${FLEET_EVENTS_FILE:-}" ] || [ ! -f "${FLEET_EVENTS_FILE:-}" ]; then
      echo "fleet-session end: no active stream" >&2
      exit 1
    fi
    FLEET_EVENT_SEQ="$(wc -l < "$FLEET_EVENTS_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
    case "${END_STATUS}" in
      completed) st=success; sc=1; fc=0 ;;
      aborted)   st=failed;  sc=0; fc=1 ;;
      *)         st=failed;  sc=0; fc=1; END_STATUS=failed ;;
    esac
    fleet_event seat_exit \
      task_id=0 agent=orchestrator branch="session/${LABEL}" wave=1 \
      provider=local status="$st" exit="$([ "$sc" -eq 1 ] && echo 0 || echo 1)" duration_s=0 attempt=1
    fleet_event wave_end wave=1 seats=1 succeeded="$sc" failed="$fc"
    fleet_event dispatch_end status="$END_STATUS" total=1 succeeded="$sc" failed="$fc"
    ;;
  *)
    usage
    exit 2
    ;;
esac
