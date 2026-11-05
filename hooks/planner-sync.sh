#!/bin/sh
# Keeps the planner's 🙋 and 🧠 counters right without the model: PostToolUse on Bash, in a planner
# session, after a command that touches the question or ready for development labels, or opens or closes an issue.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
printf '%s' "$payload" | grep -q -E 'gh issue (edit|close|reopen|create)|gh api|ready\.sh' || exit 0

name=$(session_name)
case "$name" in
"planner"*) ;;
*) exit 0 ;;
esac
cd "$cwd"
sh "$scripts/sync-names.sh" planner "$sid" >/dev/null 2>&1
