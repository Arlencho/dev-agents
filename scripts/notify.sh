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
#   NEEDS YOU item that has had no action for N minutes. Once per item,
#   never twice: the items already sent are recorded in a state file keyed
#   on the item's stable identity (its type, the source kind and the comment
#   id, the repo and PR number, the dispatch and seat, or the checkout, file
#   and line). Never on the whole source: a later SAFE comment on the same
#   PR changes source.comments, not the item.
#   The toast text is built from fixed phrases and identifiers only, never
#   from a PR title, a comment body, a task line or the item's own text:
#   "<repo> <item type phrase> PR <number>", and for a critic block
#   "<repo> blocked by <critic stem word> round <n> PR <number>". An item
#   whose identifiers are missing or malformed (no repo name, a stem that
#   is not plain words) is refused with one stderr line and never sent: no
#   free text reaches a lock-screen toast, whatever live.json says. The
#   item's scrubbed text is for the page rows, which is where desk_live.py
#   still marks operator paths.
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


# The toast line is fixed phrases and identifiers only, never the item's
# text: no PR title, comment body or task line reaches the Mac. The shapes:
#   <repo> <item type phrase> PR <number>      olympus-platform ready to merge PR 102
#   <repo> blocked by <stem> round <n> PR <n>  dev-agents blocked by frontend critic round 2 PR 80
REPO_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
STEM_WORDS = re.compile(r"^[A-Za-z0-9 ]+$")
# The item type as its phrase (the underscore form with spaces); a critic
# block names the critic and the round instead.
TOAST_PHRASES = {"ready_to_merge": "ready to merge", "quiet_seat": "quiet seat",
                 "failed_dispatch": "failed dispatch", "prd_proposed": "prd proposed",
                 "missing_variable": "missing variable"}


def toast_text(item):
    """The one toast line for an item, or None when its identifiers cannot
    carry the fixed shape (no repo name, a stem that is not plain words, an
    unknown type). The item's `text` is never read: it is free text for the
    page rows, and free text does not go on a lock screen."""
    src = item.get("source") if isinstance(item.get("source"), dict) else {}
    repo = item.get("repo") or src.get("repo") or src.get("checkout")
    if not isinstance(repo, str) or not REPO_NAME.match(repo):
        return None
    kind = item.get("type")
    if kind == "critic_block":
        stem = src.get("stem")
        if isinstance(stem, str) and STEM_WORDS.match(stem):
            stem = " ".join(stem.lower().split()) or "critic"
        else:
            stem = "critic"
        rnd = src.get("round")
        if not isinstance(rnd, int) or isinstance(rnd, bool) or rnd < 1:
            rnd = 1
        phrase = "blocked by %s round %d" % (stem, rnd)
    elif kind in TOAST_PHRASES:
        phrase = TOAST_PHRASES[kind]
    else:
        return None
    pr = item.get("pr")
    if not isinstance(pr, int) or isinstance(pr, bool):
        pr = src.get("pr")
    suffix = " PR %d" % pr if isinstance(pr, int) and not isinstance(pr, bool) and pr > 0 else ""
    return "%s %s%s" % (repo, phrase, suffix)


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
    text = toast_text(item)
    if text is None:
        # Refused, not seen: nothing was sent, and the line says why.
        print("WARNING: needs-you item %s refused: no fixed phrase (missing or malformed identifiers)"
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
