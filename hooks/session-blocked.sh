#!/bin/sh
# A release manager or a developer agent stuck on a permission prompt, which in a background session waits
# in silence:
#   session-blocked.sh ask   PermissionRequest: records it in the session's folder and leaves the planner a
#                            question in its inbox; remind.sh has the planner say it out loud after 30 minutes.
#   session-blocked.sh go    PostToolUse: the session went on, the record goes.
# Every other session exits at once. It never answers the prompt itself.
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

issue=$(agent_issue)
if [ -z "$issue" ]; then
	role_is "release manager" is-manager || exit 0
fi
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
what=$(printf '%s' "$payload" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.url // empty' 2>/dev/null | head -1 | cut -c1-80 || true)
cd "$cwd"
# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
if [ -n "$issue" ]; then
	job=$(claude agents --json 2>/dev/null | jq -r --arg s "$sid" '[.[] | select(.sessionId == $s) | .id][0] // empty' 2>/dev/null || true)
	who="The developer agent of issue #$issue"
	sentence="L'agente della issue $issue di $repo_short è fermo su un permesso: ${what:-$tool}."
	attach=${job:-${sid%%-*}}
	from="agent of #$issue"
else
	who="The release manager"
	sentence="Il release manager di $repo_short è fermo su un permesso: ${what:-$tool}."
	attach=$manager_prefix
	from=$manager_prefix
fi
want "$sid" blocked "$(printf '%s\n%s' "$(date +%s)" "$sentence")"
rm -f "$record.called"
printf '%s is stopped on a permission prompt and waits for the user to answer it in its session (claude attach "%s").\nTool: %s\nWhat: %s\n' \
	"$who" "$attach" "$tool" "${what:-?}" | sh "$scripts/tell.sh" planner question --recorded --from "$from" >/dev/null 2>&1 || true
