#!/bin/bash
set -euo pipefail
# Codex CLI launcher (subscription login via 'codex login', no API keys).
# Contract: see providers/lib.sh header.
#
# Charter injection mirrors the kimi and grok launchers: `codex exec` has no
# --agent equivalent, so roles/<role>.md rides at the top of the prompt.
#
# Headless flags, verified against codex-cli 0.154.0 (2026-09-25):
#   exec          non-interactive; the prompt comes from argv, the transcript
#                 is plain text on stdout (header, the prompt echoed under a
#                 "user" line, the answer under "codex", then "tokens used").
#   --dangerously-bypass-approvals-and-sandbox
#                 approvals off and no sandbox. A seat works inside its own
#                 git worktree and needs git push, gh, npm and the network,
#                 which the codex sandbox modes block or prompt for. This is
#                 the permission level the other launchers already run with:
#                 claude passes --dangerously-skip-permissions, kimi -p runs
#                 with --auto, grok -p performs edits headless.
#   --color never plain log lines for tee and the classifier.
# Not passed: --skip-git-repo-check (every seat runs inside a git worktree;
# a run outside one should fail loud, not silently work in the wrong place).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Existence-checked source: on bash 3.2 (macOS /bin/bash, the ssh worker
# shell), `source missing 2>/dev/null || source ...` dies silently under set -e.
# shellcheck source=../lib.sh
if [ -f "$SCRIPT_DIR/../lib.sh" ]; then
    source "$SCRIPT_DIR/../lib.sh"
else
    source "$SCRIPT_DIR/lib.sh"
fi

ROLE="${1:?usage: launch.sh <role> <task>}"
TASK="${2:?usage: launch.sh <role> <task>}"

command -v codex >/dev/null 2>&1 || {
    echo "codex CLI not found: install the Codex CLI (brew install codex), then 'codex login' on this machine" >&2
    exit "$EXIT_UNAVAILABLE"
}

ROLES_DIR="${ROLES_DIR:-$SCRIPT_DIR/../../roles}"
# Decision: the catch-all seat gets a real charter (roles/claude.md) rather than
# a special case here, so every dispatched role name resolves to a file.
# Resolve the charter explicitly anyway: a role with no file under roles/ must
# leave CHARTER_FILE empty and quoted, never a half-built word the shell runs.
CHARTER_FILE=""
if [ -n "${ROLE:-}" ] && [ -n "${ROLES_DIR:-}" ] && [ -f "$ROLES_DIR/$ROLE.md" ]; then
    CHARTER_FILE="$ROLES_DIR/$ROLE.md"
fi

PROMPT="$TASK"
if [ -n "$CHARTER_FILE" ]; then
    PROMPT="## Your Role Charter
$(strip_frontmatter "$CHARTER_FILE")

## Task
$TASK"
else
    echo "WARNING: no charter for role '$ROLE' under $ROLES_DIR, running without a role charter" >&2
fi

# Codex treats charter scope lines as hard stops and then asks a question a
# headless seat cannot answer (2026-09-25: seats "succeeded" with no changes).
# The dispatched task is owner-approved, so it wins on file scope and process.
PROMPT="## Run rules
This is a non-interactive run. Nobody can answer questions, so never stop to ask; decide and act.
The task below was approved by the repository owner. Where it names files, directories or kinds of change outside the charter's usual scope, the task wins.
If a helper the charter mentions (for example scripts/task-worktree.sh or PAPERCLIP_TASK_ID) does not exist, work in the current directory and branch you were started in.
Finish the task end to end: change the code, run the tests it names, commit, push and open the pull request it asks for.
Never create or commit handoff, notes or summary files (for example handoff.md); put what a reviewer needs in the pull request description.
Never use adb, emulators or any connected phone or device, and never install or launch apps on a device; the owner's phone is in use. Verify with tests, typecheck and exports only.

$PROMPT"

# Claude tier / product aliases are meaningless here; pass through vendor-native
# IDs only (-m). Failover must not forward claude-fable-5 / opus / sonnet.
MODEL_FLAG=()
case "${AGENT_MODEL:-}" in
    ""|opus|sonnet|haiku|claude-fable-5|claude-*|fable-*) ;;
    *) MODEL_FLAG=(-m "$AGENT_MODEL") ;;
esac

# `codex exec` appends piped stdin to the prompt as a <stdin> block. Under
# run-remote the worker shell is still reading the dispatch script from that
# descriptor, so detach stdin before the CLI can read it.
exec 0</dev/null

# ${arr[@]+...} guard: empty-array expansion errors under `set -u` on bash 3.2 (macOS).
# A shell variable, not an export: the classifier drops output lines that
# appear verbatim in the prompt (codex echoes the whole prompt back under its
# "user" line), and the CLI must not carry a second copy.
# shellcheck disable=SC2034  # read by run_and_classify in the sourced lib.sh
AGENT_PROMPT_TEXT="$PROMPT"
run_and_classify codex \
    codex exec --dangerously-bypass-approvals-and-sandbox --color never \
        ${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"} -- "$PROMPT"
