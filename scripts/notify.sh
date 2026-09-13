#!/bin/bash
set -euo pipefail

# Send completion notifications for agent tasks.
#
# Usage:
#   ./scripts/notify.sh <agent> <worker> <branch> <status> [detail]
#   ./scripts/notify.sh needs-you [live.json]
#
# Status: "success" | "failure" | "ratecap"
# Detail: optional 5th arg — for "ratecap", the vendor name being failed over
#
# Notification channels:
#   - macOS: native notification via osascript (unless silenced, see below)
#   - GitHub: comment on issue if GITHUB_ISSUE env var is set (format: owner/repo#123)
#   - Fallback: prints to stdout
#
# Environment variables:
#   GITHUB_ISSUE        — if set, posts a comment on the issue (e.g., "Arlencho/olympus-platform#42")
#   FLEET_NOTIFY_SILENT — if "1", skip the macOS osascript toast (stdout/GitHub still run)
#   NOTIFY_SILENT       — alias of FLEET_NOTIFY_SILENT
#
# NEEDS YOU push (Floor v3-C, docs/proposals/floor-v3-purpose.md section 5):
#   `notify.sh needs-you [live.json]` reads the Ops Floor projection (default
#   site/experience/data/live.json) and sends ONE macOS notification per
#   NEEDS YOU item that has had no action for N minutes, with the item's own
#   one-line text. Once per item, never twice: the items already sent are
#   recorded in a state file keyed on the item's stable identity (its type,
#   the source kind and the comment id, the repo and PR number, the dispatch
#   and seat, or the checkout, file and line). Never on the whole source: a
#   later SAFE comment on the same PR changes source.comments, not the item.
#   An item whose text carries an operator path (absolute, home, variable or
#   parent escape) is refused with one stderr line and never sent: the
#   projector marks those tokens itself, so only a hand-written live.json
#   can get here, and it does not get through.
#   Off by default. scripts/desk_live.py calls this after every write.
#
#   FLEET_NOTIFY_NEEDS_YOU_MIN   — N, in minutes. Unset or empty: nothing is
#                                  sent, nothing is written (the default).
#   FLEET_NOTIFY_NEEDS_YOU_STATE — the seen file (default logs/notify-state/needs-you.seen)
#
#   Honesty: only a live view (never a replay), only verified items, only an
#   item whose `at` proves it has waited N minutes. FLEET_NOTIFY_SILENT still
#   gates the toast; the stdout line and the seen record happen either way.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --------------------------------------------------
# NEEDS YOU push
# --------------------------------------------------

# Prints "<key>\t<text>" for every item due and not yet seen. Reads only.
needs_you_due() {
    python3 - "$1" "$2" "$3" <<'PY'
import hashlib, json, re, sys
from datetime import datetime, timezone

live_path, state_path, after_min = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(live_path, encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
# A replay is history and an unknown schema is not the Floor: nothing to push.
if not isinstance(d, dict) or d.get("schema") != "live/1" or d.get("view") != "live":
    sys.exit(0)
seen = set()
try:
    with open(state_path, encoding="utf-8") as fh:
        seen = {line.strip() for line in fh if line.strip()}
except OSError:
    pass
now = datetime.now(timezone.utc).replace(tzinfo=None)

# The fields that name an item, per source kind. Everything else in `source`
# (a comments array, a url, a timestamp, a merge state) can change while the
# item is the same, and must not make a second toast.
STABLE = {"comment": ("repo", "comment_id"), "pr": ("repo", "pr"),
          "stream": ("dispatch_id", "task_id"), "file": ("checkout", "file", "line")}


def identity(item):
    src = item.get("source") if isinstance(item.get("source"), dict) else {}
    kind = src.get("kind")
    fields = STABLE.get(kind)
    if fields:
        named = {f: src.get(f) for f in fields}
    else:
        named = src   # an unknown kind has no better name than all of it
    return "%s|%s|%s" % (item.get("type"), kind, json.dumps(named, sort_keys=True))


# The same path start as PATH_START in scripts/desk_live.py: a slash, home,
# variable or parent escape after an optional file:, at the start of the
# token or right after a character that cannot be part of a relative path.
PATH_START = re.compile(r"(?i)(?<![\w.~$/+@%-])(?:file:)?(?:[/~$]|\.\.(?=/|$))")
URL_SCHEME = re.compile(r"(?i)^(?!file:)[a-z][a-z0-9+.-]*://")


def has_operator_path(text):
    """True when a slash token of the line reads as a path outside the
    worktree: absolute, home, a variable, or a parent escape, whether the
    token is the path or the path sits inside it (fix:/Users/x, `~/.ssh`).
    The law of task_path in scripts/desk_live.py; the projector already
    marks these, so a token that still reads so came from a hand-written
    file."""
    for tok in text.split(" "):
        if "/" not in tok:
            continue
        core = tok.rstrip(".,;:!?)'\"`")
        while core and core[0] in "(\"'`":
            core = core[1:]
        if not URL_SCHEME.match(core):
            start = PATH_START.search(core)
            if start:
                core = core[start.start():]
        if core.lower().startswith("file:"):
            core = core[5:]
        if core.startswith(("/", "~", "$")) or ".." in core.split("/"):
            return True
    return False


for item in d.get("needs_you") or []:
    if not isinstance(item, dict) or not item.get("verified"):
        continue
    try:
        at = datetime.strptime(item.get("at") or "", "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        continue   # no time, no proof of how long it has waited
    if (now - at).total_seconds() < after_min * 60:
        continue
    key = hashlib.sha1(identity(item).encode("utf-8")).hexdigest()[:16]
    if key in seen:
        continue
    text = " ".join(str(item.get("text") or "").split())
    if has_operator_path(text):
        # Refused, not seen: nothing was sent, and the line says why without
        # repeating the path.
        print("WARNING: needs-you item %s refused: its text carries a path outside the worktree"
              % item.get("type"), file=sys.stderr)
        continue
    seen.add(key)
    print("%s\t%s" % (key, text))
PY
}

needs_you_push() {
    local live="$1"
    local after="${FLEET_NOTIFY_NEEDS_YOU_MIN:-}"
    # Off by default: unset or empty sends nothing and writes nothing.
    [ -n "$after" ] || return 0
    case "$after" in
        *[!0-9]*|0)
            echo "WARNING: FLEET_NOTIFY_NEEDS_YOU_MIN must be a positive integer (minutes), got: $after" >&2
            return 0 ;;
    esac
    [ -f "$live" ] || return 0
    local state="${FLEET_NOTIFY_NEEDS_YOU_STATE:-$REPO_DIR/logs/notify-state/needs-you.seen}"
    mkdir -p "$(dirname "$state")"
    touch "$state"
    local toast=1
    if [ "${FLEET_NOTIFY_SILENT:-0}" = "1" ] || [ "${NOTIFY_SILENT:-0}" = "1" ] || [ "$(uname)" != "Darwin" ]; then
        toast=0
    fi
    local key text msg
    while IFS=$'\t' read -r key text; do
        [ -n "$key" ] || continue
        if [ "$toast" = "1" ]; then
            msg="$(printf '%s' "$text" | sed 's/[\\"]/\\&/g')"
            osascript -e "display notification \"$msg\" with title \"Needs you\"" 2>/dev/null || true
        fi
        printf '%s\n' "$key" >> "$state"
        echo "[notify] Needs you: $text"
    done < <(needs_you_due "$live" "$state" "$after")
    return 0
}

if [ "${1:-}" = "needs-you" ]; then
    needs_you_push "${2:-$REPO_DIR/site/experience/data/live.json}"
    exit 0
fi

# --------------------------------------------------
# Seat outcomes
# --------------------------------------------------

AGENT="${1:?Usage: notify.sh <agent> <worker> <branch> <status> [detail]}"
WORKER="${2:?Missing worker name}"
BRANCH="${3:?Missing branch name}"
STATUS="${4:?Missing status (success/failure/ratecap)}"
DETAIL="${5:-}"

if [ "$STATUS" = "success" ]; then
    TITLE="Agent Succeeded"
    MSG="$AGENT on $WORKER completed ($BRANCH)"
    GH_EMOJI=":white_check_mark:"
elif [ "$STATUS" = "ratecap" ]; then
    TITLE="Provider Rate-Capped"
    MSG="$AGENT on $WORKER: ${DETAIL:-provider} cap hit — failing over ($BRANCH)"
    GH_EMOJI=":hourglass_flowing_sand:"
else
    TITLE="Agent Failed"
    MSG="$AGENT on $WORKER failed ($BRANCH)"
    GH_EMOJI=":x:"
fi

# --------------------------------------------------
# macOS notification (skipped when silenced — tests and headless runs set this
# so `make test` never pops "Provider Rate-Capped" toasts on the operator's Mac)
# --------------------------------------------------
if [ "${FLEET_NOTIFY_SILENT:-0}" != "1" ] && [ "${NOTIFY_SILENT:-0}" != "1" ] && [ "$(uname)" = "Darwin" ]; then
    osascript -e "display notification \"$MSG\" with title \"$TITLE\"" 2>/dev/null || true
fi

# --------------------------------------------------
# GitHub issue comment
# --------------------------------------------------
if [ -n "${GITHUB_ISSUE:-}" ]; then
    # Parse owner/repo#number
    if [[ "$GITHUB_ISSUE" =~ ^(.+)#([0-9]+)$ ]]; then
        GH_REPO="${BASH_REMATCH[1]}"
        GH_NUMBER="${BASH_REMATCH[2]}"
        COMMENT="$GH_EMOJI **$AGENT** on \`$WORKER\`: $STATUS${DETAIL:+ ($DETAIL)} (\`$BRANCH\`)"
        gh issue comment "$GH_NUMBER" -R "$GH_REPO" --body "$COMMENT" 2>/dev/null || \
            echo "WARNING: Failed to comment on $GITHUB_ISSUE"
    else
        echo "WARNING: GITHUB_ISSUE format should be owner/repo#123, got: $GITHUB_ISSUE"
    fi
fi

# --------------------------------------------------
# Stdout fallback (always)
# --------------------------------------------------
echo "[notify] $TITLE: $MSG"
