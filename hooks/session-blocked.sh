#!/bin/sh
# A team session stopped on a permission prompt, which in a background session waits in silence:
#   session-blocked.sh ask   PermissionRequest: its state becomes "waits on you" (yellow), with what it asks;
#                            Claude Code's own notification tells the user
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
	state_set "$sid" working "riprende dopo il permesso"
	exit 0
fi

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
what=$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // empty' 2>/dev/null | head -1 | cut -c1-80 || true)
want "$sid" blocked "$(date +%s)"
state_set "$sid" you "permesso: ${what:-$tool}"
