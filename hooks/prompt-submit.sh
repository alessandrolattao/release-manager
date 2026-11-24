#!/bin/sh
# UserPromptSubmit in a team session: the user is writing to it, so it works with them, and whatever it
# waited on is over (hooks/sessions.tsx would otherwise put the wait back when the turn ends).
# In a tech lead, when the user comes back after a pause and another repository left messages for this
# one's tech leads (tell.sh), one line of context says so. The messages never enter the conversation here.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
case "$role" in tech-lead | dev | qa | spike) ;; *) exit 0 ;; esac
state_set "$sid" working "con te"
status_set "$sid" 'del(.resume_to)'
[ "$role" = tech-lead ] || exit 0

pause_minutes=15
last="$state_dir/$sid.last-prompt"
now=$(date +%s)
before=$(cat "$last" 2>/dev/null || echo 0)
echo "$now" >"$last"
[ $((now - before)) -ge $((pause_minutes * 60)) ] || exit 0

cd "$cwd"
box="$team_data/inbox/$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')/new"
n=$(find "$box" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 0 ] || exit 0
jq -n --arg n "$n" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
	additionalContext: ("📨 " + $n + " message(s) from other repositories wait in your inbox (inbox.sh). Mention it in one line before answering, do not read them unless the user wants to; answer what the user asked.")}}'
