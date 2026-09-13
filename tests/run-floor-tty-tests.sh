#!/usr/bin/env bash
# Floor in the terminal (scripts/floor_tty.py): the same live.json the page
# reads, rendered as plain text in the v3 order.
#
#   Part A: the page fixtures (tests/fixtures/live/*.json) render to the
#           pinned text, --once exits 0, width never exceeds 100 columns,
#           the render never exceeds 60 lines even with a flooded projection
#   Part B: honesty: the stale fixture puts the stale sentence first, the
#           offline one the offline sentence, a replay carries its watermark
#           on every section, a queued plan never reads as running, no
#           stream path, plan path, log name or url reaches the terminal
#   Part C: modes: --color prints the same characters as plain, a missing
#           file exits non-zero with a hint, the make target and the docs exist
#   Part D: the critic's round 2 fixtures: the loop survives a JSON value
#           that is not an object, INITIATIVES renders the page's row, a
#           projection without summary prints no zero, an off-schema file is
#           refused like the page, an absolute path never reaches the output
#
# Offline by design: no socket, no network, no event stream is read.
#
# Law: docs/proposals/floor-v3-purpose.md section 4 (order) and section 6 (rules)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIVEFIX="$SCRIPT_DIR/fixtures/live"
EXPECTED="$SCRIPT_DIR/fixtures/floor-tty"
TTY="$REPO_DIR/scripts/floor_tty.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# render <fixture> <now> [flags...] -> stdout
render() {
  local file="$1" now="$2"; shift 2
  python3 "$TTY" --once --file "$file" --now "$now" "$@"
}

# max_width <file>: the longest visible line, colour codes stripped
max_width() {
  python3 - "$1" <<'PY'
import re, sys
strip = re.compile(r"\x1b\[[0-9;]*m")
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
print(max((len(strip.sub("", l)) for l in lines), default=0))
PY
}

[ -f "$TTY" ] && ok "scripts/floor_tty.py exists" || { bad "scripts/floor_tty.py exists"; exit 1; }
[ -x "$TTY" ] && ok "scripts/floor_tty.py is executable" || bad "scripts/floor_tty.py is executable"

echo "== Part A: the page fixtures render to the pinned text =="

# Each fixture is rendered with the clock pinned to its generated_at, so the
# derived state (live, stale) is the one the fixture was written to show.
declare -a NAMES=(wave conductor floor-v3)
declare -a NOWS=(2026-07-29T10:20:05Z 2026-07-29T11:06:20Z 2026-09-13T10:00:05Z)
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; now="${NOWS[$i]}"
  out="$TMP/$name.txt"
  if render "$LIVEFIX/$name.json" "$now" > "$out"; then
    ok "--once exits 0 on $name.json"
  else
    bad "--once exits 0 on $name.json"
  fi
  if diff -u "$EXPECTED/$name.txt" "$out" > "$TMP/$name.diff"; then
    ok "$name.json renders to fixtures/floor-tty/$name.txt"
  else
    bad "$name.json renders to fixtures/floor-tty/$name.txt"
    sed 's/^/       /' "$TMP/$name.diff" | head -40
  fi
  w="$(max_width "$out")"
  [ "$w" -le 100 ] && ok "$name render is at most 100 columns (widest $w)" \
    || bad "$name render is at most 100 columns (widest $w)"
  n="$(wc -l < "$out" | tr -d ' ')"
  [ "$n" -le 60 ] && ok "$name render is at most 60 lines ($n)" \
    || bad "$name render is at most 60 lines ($n)"
done

# The v3 fixture: the order of section 4, top to bottom.
V3="$TMP/floor-v3.txt"
order="$(grep -n -E '^(NEEDS YOU|NOW|UP NEXT|INITIATIVES|FAILED today|LANDED today)' "$V3" | cut -d: -f2 | tr '\n' '|')"
[ "$order" = "NEEDS YOU|NOW|UP NEXT|INITIATIVES|FAILED today|LANDED today|" ] \
  && ok "sections follow section 4: status, NEEDS YOU, NOW, UP NEXT, INITIATIVES, FAILED, LANDED" \
  || bad "sections follow section 4 (got: $order)"
head -1 "$V3" | grep -qE '^3 running, 3 up next, 2 landed, 1 failed, 1 aborted, needs you: 6, last event 3 s ago$' \
  && ok "status line carries running, up next, landed, failed, needs you, last event age" \
  || bad "status line carries the six figures"
grep -q 'check the log: run 20260913-094000-olympus-platform' "$V3" \
  && ok "a NEEDS YOU line carries its action and the run reference as text" \
  || bad "a NEEDS YOU line carries its action and the run reference"
grep -q 'open the comment: comment 9001 on issue 2340' "$V3" \
  && ok "a critic block names the comment and its issue as text" \
  || bad "a critic block names the comment and its issue"
grep -q 'merge: PR 2829' "$V3" \
  && ok "a ready PR names the PR as text" || bad "a ready PR names the PR"
grep -qE '^  olympus-platform: 2 seats live, 1 dispatch live$' "$V3" \
  && grep -qE '^  dev-agents: 1 seat live, 1 dispatch live$' "$V3" \
  && ok "NOW is grouped by repo with the per-repo counts" \
  || bad "NOW is grouped by repo with the per-repo counts"
grep -qE '^    olympus-platform  devops  #2800  .*  quiet for 7 min, .*  8 min in$' "$V3" \
  && ok "a seat line reads repo, role, issue, task, status sentence (quiet named), elapsed" \
  || bad "a seat line reads repo, role, issue, task, status sentence, elapsed"
grep -qE '^  1\.  olympus-platform  #2800  .*  blocked: S11 awaits sign-off$' "$V3" \
  && ok "a blocked queue row shows the reason in place" \
  || bad "a blocked queue row shows the reason in place"
grep -qE '^  olympus-platform  .*  failed after 8 min$' "$V3" \
  && grep -qE '^  olympus-platform  .*  aborted after 2 min$' "$V3" \
  && ok "FAILED today lists failed and aborted rows, failed section first" \
  || bad "FAILED today lists failed and aborted rows"
grep -qE '^  dev-agents  .*  landed after 1 h 6 min  PR 80 ' "$V3" \
  && ok "a landed row reads repo, purpose, outcome, duration, PR number and title" \
  || bad "a landed row reads repo, purpose, outcome, duration, PR"
grep -q 'docs-writer' "$V3" && bad "a settled seat never appears under NOW" || ok "a settled seat never appears under NOW"
grep -q 'feat/old-offline\|task_id 9' "$V3" && bad "an unknown seat never appears under NOW" || ok "an unknown seat never appears under NOW"

# A flooded projection stays within 60 lines and says how much is hidden.
python3 - "$LIVEFIX/floor-v3.json" "$TMP/flood.json" <<'PY'
import copy, json, sys
d = json.load(open(sys.argv[1]))
d["needs_you"] = [dict(d["needs_you"][i % len(d["needs_you"])], text="item %d needs a look" % i) for i in range(70)]
d["queue"] = [dict(d["queue"][0], position=i + 1, purpose="queued plan %d" % i, blocked=None) for i in range(40)]
d["today"] = [dict(d["today"][0], purpose="landing %d" % i) for i in range(50)] + [dict(d["today"][1], purpose="failure %d" % i) for i in range(20)]
seats = []
for i in range(30):
    s = copy.deepcopy(d["seats"][0]); s["task_id"] = str(i); s["repo"] = "repo-%d" % (i % 5); seats.append(s)
d["seats"] = seats
json.dump(d, open(sys.argv[2], "w"))
PY
if render "$TMP/flood.json" 2026-09-13T10:00:05Z > "$TMP/flood.txt"; then
  n="$(wc -l < "$TMP/flood.txt" | tr -d ' ')"; w="$(max_width "$TMP/flood.txt")"
  [ "$n" -le 60 ] && ok "a flooded projection renders within 60 lines ($n)" || bad "a flooded projection renders within 60 lines ($n)"
  [ "$w" -le 100 ] && ok "a flooded projection stays within 100 columns ($w)" || bad "a flooded projection stays within 100 columns ($w)"
  grep -q 'more not shown' "$TMP/flood.txt" && ok "trimmed sections say how many rows are not shown" || bad "trimmed sections say how many rows are not shown"
  grep -q '^NEEDS YOU' "$TMP/flood.txt" && grep -q '^LANDED today' "$TMP/flood.txt" \
    && ok "every section survives the trim" || bad "every section survives the trim"
else
  bad "a flooded projection renders"
fi

echo ""
echo "== Part B: honesty =="

# Shift every timestamp of the wave fixture so last_event_ts lands at now-200s
# (stale) and leave the stored staleness.state at "live": the stale sentence
# can only come from derivation, never from trusting the stored claim. A
# summary is planted so the status line carries a running figure to qualify
# (without one the page, and so the terminal, shows no figure at all).
python3 - "$LIVEFIX/wave.json" "$TMP/stale.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
ISO = "%Y-%m-%dT%H:%M:%SZ"
d = json.load(open(sys.argv[1]))
d["summary"] = {"running": 1, "queued": 0, "needs_you": 0}
last = datetime.strptime(d["last_event_ts"], ISO).replace(tzinfo=timezone.utc)
delta = datetime.now(timezone.utc) - timedelta(seconds=200) - last
def shift(node):
    if isinstance(node, dict):
        return {k: shift(v) for k, v in node.items()}
    if isinstance(node, list):
        return [shift(v) for v in node]
    if isinstance(node, str) and len(node) == 20 and node.endswith("Z") and node[10] == "T":
        try:
            return (datetime.strptime(node, ISO).replace(tzinfo=timezone.utc) + delta).strftime(ISO)
        except ValueError:
            return node
    return node
json.dump(shift(d), open(sys.argv[2], "w"))
PY
python3 "$TTY" --once --file "$TMP/stale.json" > "$TMP/stale.txt"
head -1 "$TMP/stale.txt" | grep -q '^Stale: no new event' \
  && ok "the stale fixture puts the stale sentence first, before any number" \
  || bad "the stale fixture puts the stale sentence first (got: $(head -1 "$TMP/stale.txt"))"
head -1 "$TMP/stale.txt" | grep -qE '^[^0-9]*Stale' \
  && ok "no digit precedes the word Stale on the first line" || bad "no digit precedes the word Stale"
[ "$(grep -c '(stale, as of the last event)' "$TMP/stale.txt")" -ge 4 ] \
  && ok "stale marks every section header" || bad "stale marks every section header"
grep -q 'running at last event' "$TMP/stale.txt" \
  && ok "the running figure is qualified at last event under stale" || bad "the running figure is qualified under stale"
grep -q 'was at work' "$TMP/stale.txt" \
  && ok "a seat sentence goes past tense under stale" || bad "a seat sentence goes past tense under stale"

# The fixture as stored is weeks old on the wall clock: offline.
python3 "$TTY" --once --file "$LIVEFIX/wave.json" > "$TMP/offline.txt"
head -1 "$TMP/offline.txt" | grep -q '^Offline: no new event' \
  && ok "an old fixture on the wall clock says Offline first" || bad "an old fixture says Offline first"
[ "$(grep -c '(offline, as of the last event)' "$TMP/offline.txt")" -ge 4 ] \
  && ok "offline marks every section header" || bad "offline marks every section header"

# A replay carries its watermark on every section and borrows no present.
python3 - "$LIVEFIX/floor-v3.json" "$TMP/replay.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["view"] = "replay"
d["replay"] = {"as_of_seq": 12, "total_events": 41, "max_seq": 41, "watermark": "REPLAY", "settled_run": False}
d["staleness"]["state"] = "replay"
d["summary"] = None; d["queue"] = []; d["today"] = []; d["needs_you"] = []; d["repos"] = []
for s in d["seats"]:
    s["now"] = None
json.dump(d, open(sys.argv[2], "w"))
PY
render "$TMP/replay.json" 2026-09-13T10:00:05Z > "$TMP/replay.txt"
head -1 "$TMP/replay.txt" | grep -q '^REPLAY: history at event 12 of 41, not the present' \
  && ok "a replay says REPLAY first with its position" || bad "a replay says REPLAY first"
[ "$(grep -c 'REPLAY' "$TMP/replay.txt")" -ge 5 ] \
  && ok "the REPLAY watermark is on the status line and every section" || bad "the REPLAY watermark is on every section"
grep -q 'up next\|last event' "$TMP/replay.txt" && bad "a replay claims no queue and no last-event age" || ok "a replay claims no queue and no last-event age"
grep -q ' live' "$TMP/replay.txt" && bad "a replay never says live" || ok "a replay never says live"

# Queued never reads as running: the UP NEXT rows of the v3 fixture.
sed -n '/^UP NEXT/,/^$/p' "$V3" | grep -q 'running' \
  && bad "a queued plan never reads as running" || ok "a queued plan never reads as running"
sed -n '/^UP NEXT/,/^$/p' "$V3" | grep -cE '^  [0-9]+\.  ' | grep -q '^3$' \
  && ok "UP NEXT lists the three queued plans by position" || bad "UP NEXT lists the three queued plans by position"

# Nothing that section 6 forbids: no stream path, plan path, log file, url,
# absolute path or home path. The fixture plants each of them.
for pat in 'logs/fleet-events' 'wave-plans/' '\.jsonl' '\.log' 'https\?://' '^/' ' /Users' ' /home' '[~]/'; do
  if grep -q -e "$pat" "$V3" "$TMP/stale.txt" "$TMP/replay.txt" "$TMP/flood.txt"; then
    bad "no forbidden token in any render ($pat)"
  else
    ok "no forbidden token in any render ($pat)"
  fi
done

echo ""
echo "== Part C: modes, exits, target, docs =="

render "$LIVEFIX/floor-v3.json" 2026-09-13T10:00:05Z --color > "$TMP/colour.txt"
grep -q $'\x1b\\[' "$TMP/colour.txt" && ok "--color adds colour codes" || bad "--color adds colour codes"
sed $'s/\x1b\\[[0-9;]*m//g' "$TMP/colour.txt" > "$TMP/colour-plain.txt"
diff -q "$TMP/colour-plain.txt" "$V3" > /dev/null \
  && ok "--color prints the same characters as the plain mode" || bad "--color prints the same characters as the plain mode"
grep -q $'\x1b\\[' "$V3" && bad "plain mode carries no escape code" || ok "plain mode carries no escape code"

if python3 "$TTY" --once --file "$TMP/does-not-exist.json" > "$TMP/missing.out" 2> "$TMP/missing.err"; then
  bad "a missing live.json exits non-zero"
else
  ok "a missing live.json exits non-zero"
fi
grep -q 'make desk-live' "$TMP/missing.err" && ok "a missing live.json names the command that writes it" \
  || bad "a missing live.json names the command that writes it"
grep -q "$TMP" "$TMP/missing.err" && bad "the hint never prints an absolute path" || ok "the hint never prints an absolute path"

printf 'not json' > "$TMP/broken.json"
if python3 "$TTY" --once --file "$TMP/broken.json" > /dev/null 2>&1; then
  bad "a broken live.json exits non-zero"
else
  ok "a broken live.json exits non-zero"
fi

python3 "$TTY" --help > "$TMP/help.txt" 2>&1 && ok "--help exits 0" || bad "--help exits 0"
grep -q -- '--once' "$TMP/help.txt" && grep -q -- '--color' "$TMP/help.txt" \
  && ok "--help documents --once and --color" || bad "--help documents --once and --color"

grep -qE '^floor:.*## ' "$REPO_DIR/Makefile" && ok "make floor target exists with a help comment" \
  || bad "make floor target exists with a help comment"
grep -q 'floor_tty.py' "$REPO_DIR/Makefile" && ok "make floor runs scripts/floor_tty.py" || bad "make floor runs scripts/floor_tty.py"
grep -q 'make floor' "$REPO_DIR/README.md" && ok "README documents make floor" || bad "README documents make floor"
grep -q 'make floor' "$REPO_DIR/docs/experience.md" && ok "docs/experience.md documents make floor next to make desk-live" \
  || bad "docs/experience.md documents make floor"

# The long dashes (U+2014, U+2013, U+2015) are named by code point so this
# file does not carry the characters it forbids.
if python3 - "$TTY" "$SCRIPT_DIR/run-floor-tty-tests.sh" "$EXPECTED"/*.txt "$LIVEFIX/floor-v3.json" <<'PY'
import sys
DASHES = ("\u2014", "\u2013", "\u2015")
bad = [p for p in sys.argv[1:] if any(ch in open(p, encoding="utf-8").read() for ch in DASHES)]
sys.exit(1 if bad else 0)
PY
then
  ok "no long dash in the renderer, the tests or the fixtures"
else
  bad "no long dash in the renderer, the tests or the fixtures"
fi

echo ""
echo "== Part D: the critic's round 2 fixtures =="

# 1. The refresh loop: a JSON value that is not an object (the critic planted
# []) must paint the Could not read line on a cleared screen, keep the
# process up, and leave no count of the earlier frame behind. stdin is not a
# tty here, so the loop sleeps between frames instead of waiting on a key.
WATCH="$TMP/watch-live.json"
cp "$LIVEFIX/floor-v3.json" "$WATCH"
python3 "$TTY" --file "$WATCH" --interval 1 --now 2026-09-13T10:00:05Z < /dev/null > "$TMP/watch.out" 2> "$TMP/watch.err" &
WPID=$!
sleep 1.5
printf '[]' > "$WATCH"
sleep 2.5
if kill -0 "$WPID" 2> /dev/null; then
  ok "the loop stays up after live.json becomes a JSON array"
else
  bad "the loop stays up after live.json becomes a JSON array (exited: $(tail -1 "$TMP/watch.err"))"
fi
kill "$WPID" 2> /dev/null || true
wait "$WPID" 2> /dev/null || true
# Frames are separated by the clear-screen sequence; the last one is what is on the terminal.
python3 - "$TMP/watch.out" "$TMP/watch-first.txt" "$TMP/watch-last.txt" <<'PY'
import sys
frames = [f for f in open(sys.argv[1], encoding="utf-8").read().split("\x1b[H\x1b[2J") if f.strip()]
open(sys.argv[2], "w").write(frames[0] if frames else "")
open(sys.argv[3], "w").write(frames[-1] if frames else "")
PY
grep -q '^3 running' "$TMP/watch-first.txt" && ok "the first frame painted the live counts" || bad "the first frame painted the live counts"
grep -q '^Could not read watch-live.json: not a live/1 projection' "$TMP/watch-last.txt" \
  && ok "the last frame is the Could not read line with the reason" || bad "the last frame is the Could not read line (got: $(head -1 "$TMP/watch-last.txt"))"
grep -q 'running\|up next\|needs you' "$TMP/watch-last.txt" && bad "no count of an earlier frame survives on screen" || ok "no count of an earlier frame survives on screen"
grep -q 'Traceback' "$TMP/watch.err" && bad "the loop prints no traceback" || ok "the loop prints no traceback"
for v in 'null' '"hello"' '1' 'true'; do
  printf '%s' "$v" > "$TMP/scalar.json"
  if python3 "$TTY" --once --file "$TMP/scalar.json" > "$TMP/scalar.out" 2> "$TMP/scalar.err"; then
    bad "--once on $v exits non-zero"
  else
    if grep -q 'not a live/1 projection' "$TMP/scalar.err" && ! grep -q Traceback "$TMP/scalar.err"; then
      ok "--once on $v exits non-zero with the reason and no traceback"
    else
      bad "--once on $v exits non-zero with the reason and no traceback"
    fi
  fi
done

# 2. INITIATIVES: the page's row (repo, title, wave n of m, open issues, last
# landed PR, exit sentence) and, on a fallback row, what the streams and the
# queue alone prove. The stock v3 fixture has none: the page's empty copy.
python3 - "$LIVEFIX/floor-v3.json" "$TMP/init.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["initiatives"] = [
    {"repo": "olympus-platform", "title": "Assistant Channel Track", "number": 3,
     "url": "https://github.com/testowner/olympus-platform/milestone/3", "lookup": "verified", "reason": None,
     "epic": 2300, "epic_title": "Epic: Assistant Channel", "exit": "five distinct testers complete a checkout",
     "exit_lookup": "verified", "waves": {"landed": 2, "planned": 4}, "open_issues": 5,
     "last_landed": {"number": 2829, "title": "feat(tile)"}, "updated_at": "2026-09-13T09:50:00Z", "plans": []},
    {"repo": "dev-agents", "title": "Floor", "number": None, "url": None, "lookup": "skipped",
     "reason": "gh unavailable", "exit": None, "exit_lookup": "skipped", "waves": {"landed": 1, "planned": 3},
     "open_issues": None, "last_landed": None, "plans": []}]
json.dump(d, open(sys.argv[2], "w"))
PY
render "$TMP/init.json" 2026-09-13T10:00:05Z > "$TMP/init.txt"
sed -n '/^INITIATIVES/,/^$/p' "$TMP/init.txt" > "$TMP/init-section.txt"
grep -qE '^  olympus-platform Assistant Channel Track: wave 2 of 4, 5 open issues, last landed #2829' "$TMP/init-section.txt" \
  && ok "an initiative row reads repo, title, wave n of m, open issues, last landed PR (the page's form)" \
  || bad "an initiative row reads repo, title, wave n of m, open issues, last landed PR (the page's form)"
grep -q 'exit: five distinct testers complete a checkout$' "$TMP/init.txt" \
  && ok "the exit sentence is on the row, whole" || bad "the exit sentence is on the row, whole"
grep -qE '^    [^ ]' "$TMP/init-section.txt" && ! grep -q '\.\.\.' "$TMP/init-section.txt" \
  && ok "a long initiative row wraps with a hanging indent instead of cutting a fact" \
  || bad "a long initiative row wraps with a hanging indent instead of cutting a fact"
[ "$(max_width "$TMP/init.txt")" -le 100 ] && ok "the initiatives render stays within 100 columns" \
  || bad "the initiatives render stays within 100 columns ($(max_width "$TMP/init.txt"))"
grep -qE '^  dev-agents Floor: wave 1 of 3, streams and queue alone, milestone not verified \(gh unavailable\)$' "$TMP/init-section.txt" \
  && ok "a fallback row says streams and queue alone and why" || bad "a fallback row says streams and queue alone and why"
grep -q 'github.com\|milestone/3' "$TMP/init.txt" && bad "the milestone url never reaches the output" || ok "the milestone url never reaches the output"
order="$(grep -n -E '^(UP NEXT|INITIATIVES|FAILED today)' "$TMP/init.txt" | cut -d: -f2 | tr '\n' '|')"
[ "$order" = "UP NEXT|INITIATIVES|FAILED today|" ] && ok "INITIATIVES sits between UP NEXT and the day (4.5)" || bad "INITIATIVES sits between UP NEXT and the day (got: $order)"
grep -q '^  No open milestone with recent activity is known to this projection.$' "$V3" \
  && ok "an empty initiatives list prints the page's empty copy" || bad "an empty initiatives list prints the page's empty copy"

# 3. A projection without summary, needs_you, queue or today (the wave page
# fixture): the strip figures need a summary on the page, so the status line
# prints no zero, and every list reads the page's empty copy, one story.
WAVE="$TMP/wave.txt"
head -1 "$WAVE" | grep -qE '^no counts: this projection carries no summary, last event 3 s ago$' \
  && ok "without a summary the status line says so and prints no figure" \
  || bad "without a summary the status line says so (got: $(head -1 "$WAVE"))"
head -1 "$WAVE" | grep -qE '[0-9]+ (running|up next|landed|failed)|needs you: [0-9]' \
  && bad "no zero on the status line for a key the projection lacks" || ok "no zero on the status line for a key the projection lacks"
grep -q 'Not in this projection' "$WAVE" && bad "no section calls a missing key absent while another counts it" \
  || ok "no section calls a missing key absent while another counts it"
if grep -q '^  Nothing needs you.$' "$WAVE" && grep -q '^  Nothing armed. The next dispatch is whatever the operator types.$' "$WAVE" \
  && grep -q '^  Nothing has landed today yet.$' "$WAVE" && grep -q '^  No open milestone' "$WAVE"; then
  ok "missing needs_you, queue, today and initiatives read the page's empty copy"
else
  bad "missing needs_you, queue, today and initiatives read the page's empty copy"
fi
grep -q '^  unknown: 1 seat live' "$WAVE" && ok "a seat without a repo groups under unknown, as on the page" \
  || bad "a seat without a repo groups under unknown, as on the page"
# With a summary, the same lists empty print the same copy (missing == empty).
python3 - "$LIVEFIX/floor-v3.json" "$TMP/empty.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["needs_you"] = []; d["queue"] = []; d["today"] = []; d["initiatives"] = []
d["summary"] = {"running": 3, "queued": 0, "needs_you": 0}
json.dump(d, open(sys.argv[2], "w"))
PY
render "$TMP/empty.json" 2026-09-13T10:00:05Z > "$TMP/empty.txt"
if head -1 "$TMP/empty.txt" | grep -qE '^3 running, 0 up next, 0 landed, 0 failed, needs you: 0, last event 3 s ago$' \
  && grep -q '^  Nothing armed' "$TMP/empty.txt" && grep -q '^  Nothing needs you.$' "$TMP/empty.txt"; then
  ok "with a summary, empty lists print the same copy under the summary's figures"
else
  bad "with a summary, empty lists print the same copy under the summary's figures"
fi

# 4. Off-schema: the same gate as the page. schema live/2 on the v3 fixture
# must not paint 3 running; it is refused with the reason, no traceback.
python3 - "$LIVEFIX/floor-v3.json" "$TMP/v2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["schema"] = "live/2"; json.dump(d, open(sys.argv[2], "w"))
PY
if python3 "$TTY" --once --file "$TMP/v2.json" --now 2026-09-13T10:00:05Z > "$TMP/v2.out" 2> "$TMP/v2.err"; then
  bad "a live/2 projection is refused (exit non-zero)"
else
  ok "a live/2 projection is refused (exit non-zero)"
fi
grep -q 'running' "$TMP/v2.out" && bad "a live/2 projection never paints a count" || ok "a live/2 projection never paints a count"
grep -q 'not a live/1 projection (schema "live/2")' "$TMP/v2.err" && ok "the refusal names the schema it found" \
  || bad "the refusal names the schema it found (got: $(cat "$TMP/v2.err"))"
python3 - "$LIVEFIX/floor-v3.json" "$TMP/noschema.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["schema"]; json.dump(d, open(sys.argv[2], "w"))
PY
if python3 "$TTY" --once --file "$TMP/noschema.json" > /dev/null 2> "$TMP/noschema.err"; then
  bad "a projection without a schema key is refused"
else
  grep -q 'schema missing' "$TMP/noschema.err" && ok "a projection without a schema key is refused" || bad "a projection without a schema key is refused"
fi
cp "$TMP/v2.json" "$WATCH"
python3 "$TTY" --file "$WATCH" --interval 1 --now 2026-09-13T10:00:05Z < /dev/null > "$TMP/watch2.out" 2> /dev/null &
WPID=$!
sleep 1.5
kill "$WPID" 2> /dev/null || true
wait "$WPID" 2> /dev/null || true
if grep -q 'Could not read watch-live.json: not a live/1 projection (schema "live/2")' "$TMP/watch2.out" \
  && ! grep -q 'running' "$TMP/watch2.out"; then
  ok "the loop refuses a live/2 projection with the same line"
else
  bad "the loop refuses a live/2 projection with the same line"
fi

# 5. An absolute path on needs_you[].source.file never reaches the output:
# the action stands alone. A checkout-relative citation still prints.
python3 - "$LIVEFIX/floor-v3.json" "$TMP/abs.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
planted = 0
for it in d["needs_you"]:
    src = it.get("source") or {}
    if src.get("kind") == "file" and "prd" in (src.get("file") or ""):
        src["file"] = "/Users/secret/docs/prd.md"; src["line"] = 118; planted += 1
    elif src.get("kind") == "file":
        src["file"] = "~/docs/operations/env-vars-iris.md"; planted += 1
assert planted == 2, planted
json.dump(d, open(sys.argv[2], "w"))
PY
render "$TMP/abs.json" 2026-09-13T10:00:05Z > "$TMP/abs.txt"
grep -q 'secret\|/Users\|prd.md\|[~]/' "$TMP/abs.txt" && bad "an absolute or home path on source.file never reaches the output" \
  || ok "an absolute or home path on source.file never reaches the output"
grep -qE '  approve or edit$' "$TMP/abs.txt" && grep -qE '  set it$' "$TMP/abs.txt" \
  && ok "the action stands alone when the citation is dropped" || bad "the action stands alone when the citation is dropped"
grep -q 'set it: docs/operations/env-vars-iris.md line 6' "$V3" \
  && ok "a checkout-relative citation still prints file and line" || bad "a checkout-relative citation still prints file and line"

echo ""
echo "floor tty: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
