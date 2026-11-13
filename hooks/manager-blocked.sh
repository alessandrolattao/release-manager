#!/bin/sh
# The release manager stuck on a permission prompt, which in a background session waits in silence:
#   manager-blocked.sh ask   PermissionRequest: records it in the session's folder and leaves the planner a
#                            question in its inbox; remind.sh has the planner say it out loud after 30 minutes.
#   manager-blocked.sh go    PostToolUse: the session went on, the record goes.
# Only for a session whose name starts with "release manager"; it never answers the prompt itself.
set -eu

mode=${1:?ask or go}
# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"
record="$sessions_dir/$sid/blocked"

if [ "$mode" = go ]; then
	[ -f "$record" ] || exit 0
	rm -f "$record" "$record.called"
	exit 0
fi

role_is "release manager" is-manager || exit 0
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
what=$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // empty' 2>/dev/null | head -1 | cut -c1-80 || true)
cd "$cwd"
# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
want "$sid" blocked "$(printf '%s\nIl release manager di %s è fermo su un permesso: %s.' "$(date +%s)" "$repo_short" "${what:-$tool}")"
rm -f "$record.called"
printf 'The release manager is stopped on a permission prompt and waits for the user to answer it in its session (claude attach "%s").\nTool: %s\nWhat: %s\n' \
	"$manager_prefix" "$tool" "${what:-?}" | sh "$scripts/tell.sh" planner question --from "$manager_prefix" >/dev/null 2>&1 || true
