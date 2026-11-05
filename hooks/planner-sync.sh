#!/bin/sh
# Keeps the planner's 🙋 counter right without the model: PostToolUse on Bash, in a planner session,
# after a command that adds or removes the question label.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
case "$payload" in
*question*) ;;
*) exit 0 ;;
esac
printf '%s' "$payload" | grep -q -E 'gh issue (edit|close|reopen)|gh api' || exit 0

name=$(session_name)
case "$name" in
"planner"*) ;;
*) exit 0 ;;
esac
cd "$cwd"
sh "$scripts/sync-names.sh" planner "$sid" >/dev/null 2>&1
