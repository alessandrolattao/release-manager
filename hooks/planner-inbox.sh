#!/bin/sh
# UserPromptSubmit in a planner session: when the user comes back after a pause (a new interaction,
# not the middle of a discussion) and the inbox has unread messages, add one line of context saying
# so. The messages themselves never enter the conversation from here.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
role_is "planner" is-planner || exit 0

pause_minutes=15
last="$state_dir/$sid.last-prompt"
now=$(date +%s)
before=$(cat "$last" 2>/dev/null || echo 0)
echo "$now" >"$last"
[ $((now - before)) -ge $((pause_minutes * 60)) ] || exit 0

cd "$cwd"
box="${XDG_DATA_HOME:-$HOME/.local/share}/release-manager/inbox/$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')/planner/new"
n=$(find "$box" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 0 ] || exit 0
jq -n --arg n "$n" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
	additionalContext: ("📨 " + $n + " unread message(s) in your inbox. Mention it in one line before answering, do not read them unless the user wants to; answer what the user asked.")}}'
