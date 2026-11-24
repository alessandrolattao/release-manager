#!/bin/sh
# A team session stopped on a permission prompt, which in a background session waits in silence:
#   session-blocked.sh ask   PermissionRequest: a tech lead waits on the user (yellow); an agent is stuck (red),
#                            since only the tech lead waits on the user: the permission belongs in the settings.
#                            Either way it says what it asks, and Claude Code's own notification tells the user
#   session-blocked.sh go    PostToolUse: the session went on, it works again
# It never answers the prompt itself.
set -eu

mode=${1:?ask or go}
# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
[ -n "$role" ] || exit 0
record="$sessions_dir/$sid/blocked"

if [ "$mode" = go ]; then
	[ -f "$record" ] || exit 0
	rm -f "$record"
	state_set "$sid" working "going on after the permission"
	exit 0
fi

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
what=$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // empty' 2>/dev/null | head -1 || true)
want "$sid" blocked "$(date +%s)"
if [ "$role" = tech-lead ]; then
	state_set "$sid" you "permission: ${what:-$tool}"
else
	state_set "$sid" stuck "waits for a permission: ${what:-$tool}"
fi
