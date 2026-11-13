#!/bin/sh
# Stop in a planner session: when the planner ends its turn asking the user something (a "needs input:"
# line, or a last line that asks), records the question and when it was asked. remind.sh has the planner
# say it out loud if the user has not written to it within 30 minutes.
#   planner-asks.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
role_is "planner" is-planner || exit 0

text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
[ -n "$text" ] || exit 0
question=$(printf '%s\n' "$text" | sed -n 's/^needs input:[[:space:]]*//p' | tail -1)
if [ -z "$question" ]; then
	last=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -1)
	case "$last" in
	*\?*) question=$last ;;
	*) exit 0 ;;
	esac
fi
short=$(printf '%s' "$question" | sed -E 's/[`*_#>]//g; s/\[([^]]*)\]\([^)]*\)/\1/g' | cut -c1-140)
printf '%s\n%s\n' "$(date +%s)" "$short" >"$state_dir/$sid.asked"
rm -f "$state_dir/$sid.asked.called"
