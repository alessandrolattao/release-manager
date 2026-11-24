#!/bin/sh
# UserPromptSubmit in a tech lead session: when the user comes back after a pause and another repository
# left messages for this one's tech leads (tell.sh), one line of context says so. The messages themselves
# never enter the conversation from here.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
[ "$role" = tech-lead ] || exit 0

pause_minutes=15
last="$state_dir/$sid.last-prompt"
now=$(date +%s)
before=$(cat "$last" 2>/dev/null || echo 0)
echo "$now" >"$last"
state_set "$sid" working "con te"
[ $((now - before)) -ge $((pause_minutes * 60)) ] || exit 0

cd "$cwd"
box="$team_data/inbox/$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')/new"
n=$(find "$box" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 0 ] || exit 0
jq -n --arg n "$n" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
	additionalContext: ("📨 " + $n + " message(s) from other repositories wait in your inbox (inbox.sh). Mention it in one line before answering, do not read them unless the user wants to; answer what the user asked.")}}'
