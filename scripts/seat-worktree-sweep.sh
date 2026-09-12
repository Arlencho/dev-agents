#!/usr/bin/env bash
#
# seat-worktree-sweep.sh: remove stale per-seat worktrees and per-dispatch
# launcher runtimes that scripts/run-remote.sh left on this machine.
#
# Usage:
#   ./scripts/seat-worktree-sweep.sh            # dry run, prints what it would remove
#   ./scripts/seat-worktree-sweep.sh --apply    # actually remove
#
# On a normal exit a seat leaves nothing: it removes its own worktree on every
# exit path. What survives is a kill -9 or a worker reboot mid-seat, a tree
# kept on purpose with FLEET_KEEP_FAILED_WORKTREES=1, a tree moved aside
# because it held uncommitted work (<seat>.aside-<ts>), and the per-dispatch
# runtime of a remote worker (a localhost runtime goes with its dispatch).
#
# Rule: anything under $FLEET_HOME/worktrees/<repo>/ or
# $FLEET_HOME/agent-runtime/ older than SEAT_SWEEP_MAX_AGE_MIN minutes
# (default 1440, one day) goes, unless git still shows it locked by a live seat
# pid, or it is the runtime of a dispatch with a live seat. A live seat is never
# touched whatever its age. Uncommitted work in a stale tree is gone with it:
# a day is the grace period, and the seat log says what happened.
#
# Runs from scripts/land.sh after a landing and from the daily launchd backstop
# (docs/worktree-sweep-launchd.plist), next to the olympus-platform sweep of
# merged PR worktrees, which covers a different clone.

set -euo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

FLEET_HOME="${FLEET_HOME:-$HOME/dev}"
WT_BASE="$FLEET_HOME/worktrees"
RT_BASE="$FLEET_HOME/agent-runtime"
MAX_AGE_MIN="${SEAT_SWEEP_MAX_AGE_MIN:-1440}"

say() { printf '%s\n' "$*"; }
stale() { [ -n "$(find "$1" -maxdepth 0 -mmin +"$MAX_AGE_MIN" 2>/dev/null)" ]; }

# "<real path> <pid> <dispatch id>" per locked seat worktree, across every
# fetch point that has a worktrees directory.
live_seats() {
    local repo_dir fetch
    for repo_dir in "$WT_BASE"/*/; do
        [ -d "$repo_dir" ] || continue
        fetch="$FLEET_HOME/$(basename "$repo_dir")"
        [ -d "$fetch/.git" ] || continue
        git -C "$fetch" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree /{w=substr($0,10)} /^locked seat pid /{print w, $4, $6}'
    done
}
LIVE=$(live_seats)
live_pid_for() { printf '%s\n' "$LIVE" | awk -v w="$1" '$1==w{print $2}'; }
live_dispatch() { # true when a seat of this dispatch id is alive
    local pid
    while read -r _ pid id; do
        [ "$id" = "$1" ] || continue
        kill -0 "$pid" 2>/dev/null && return 0
    done <<< "$LIVE"
    return 1
}

# ---- seat worktrees ----------------------------------------------------------
removed=0; kept=0
if [ -d "$WT_BASE" ]; then
    for repo_dir in "$WT_BASE"/*/; do
        [ -d "$repo_dir" ] || continue
        repo_dir="${repo_dir%/}"
        fetch="$FLEET_HOME/$(basename "$repo_dir")"
        for seat in "$repo_dir"/*/*; do
            [ -d "$seat" ] || continue
            seat_real=$(cd "$seat" && pwd -P)
            pid=$(live_pid_for "$seat_real")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                say "KEEP  live seat pid $pid  $seat"; kept=$(( kept + 1 )); continue
            fi
            if ! stale "$seat"; then
                say "KEEP  younger than ${MAX_AGE_MIN}m  $seat"; kept=$(( kept + 1 )); continue
            fi
            if [[ $APPLY == 1 ]]; then
                if [ -d "$fetch/.git" ]; then
                    git -C "$fetch" worktree unlock "$seat_real" 2>/dev/null || true
                    git -C "$fetch" worktree remove --force "$seat_real" 2>/dev/null || rm -rf "$seat"
                else
                    rm -rf "$seat"
                fi
                say "GONE  $seat"
            else
                say "  would remove worktree: $seat"
            fi
            removed=$(( removed + 1 ))
        done
        if [[ $APPLY == 1 ]]; then
            [ -d "$fetch/.git" ] && git -C "$fetch" worktree prune
            find "$repo_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
            rmdir "$repo_dir" 2>/dev/null || true
        fi
    done
fi

# ---- per-dispatch launcher runtimes ------------------------------------------
rt_removed=0; rt_kept=0
if [ -d "$RT_BASE" ]; then
    for rt in "$RT_BASE"/*/ "$RT_BASE"/*.tmp "$RT_BASE"/*.claim; do
        [ -e "$rt" ] || continue
        rt="${rt%/}"
        id=$(basename "$rt")
        if live_dispatch "$id"; then
            say "KEEP  runtime of a live dispatch  $rt"; rt_kept=$(( rt_kept + 1 )); continue
        fi
        if ! stale "$rt"; then
            say "KEEP  younger than ${MAX_AGE_MIN}m  $rt"; rt_kept=$(( rt_kept + 1 )); continue
        fi
        if [[ $APPLY == 1 ]]; then
            rm -rf "$rt"
            say "GONE  runtime $rt"
        else
            say "  would remove runtime: $rt"
        fi
        rt_removed=$(( rt_removed + 1 ))
    done
fi

say ""
say "seat worktrees: $removed removed, $kept kept"
say "runtimes      : $rt_removed removed, $rt_kept kept"
[[ $APPLY == 0 ]] && say "" && say "Dry run. Re-run with --apply to make changes."
exit 0
