# Sourced by the hooks: reads the payload on stdin and tells which session it comes from.
# shellcheck shell=sh disable=SC2034 # the variables are used by the hooks that source this file

payload=$(cat)
field() { printf '%s' "$payload" | sed -n "s/.*\"$1\" *: *\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
sid=$(field session_id)
cwd=$(field cwd)
case "$sid" in
"" | *[!A-Za-z0-9-]*) exit 0 ;;
esac
state_dir="${TMPDIR:-/tmp}/release-manager-$(id -u)"
mkdir -p "$state_dir"
scripts="${CLAUDE_PLUGIN_ROOT:?}/skills/run/scripts"

transcript=$(field transcript_path)

# session_name prints this session's current name, or nothing when it cannot be told.
# The transcript (its path comes with the hook payload) holds what --name and /rename set;
# `claude agents` is the fallback, since from inside a session it may not list it right away.
session_name() {
	name=""
	if [ -n "$transcript" ] && [ -f "$transcript" ]; then
		name=$(grep -E '"type":"(custom-title|agent-name)"' "$transcript" 2>/dev/null | tail -1 |
			jq -r '.customTitle // .agentName // empty' 2>/dev/null || true)
	fi
	[ -n "$name" ] || name=$(claude agents --json 2>/dev/null | jq -r --arg s "$sid" '[.[] | select(.sessionId == $s) | .name][0] // empty' 2>/dev/null || true)
	printf '%s' "$name"
}

# role_is <name prefix> <cache tag>: true when this session's name starts with the prefix.
# Only a yes is cached: a session can start under another name and rename itself a few seconds
# later (the skills do), so until it matches, the name is read again at every event.
role_is() {
	cache="$state_dir/$sid.$2"
	[ "$(cat "$cache" 2>/dev/null)" = yes ] && return 0
	current=$(session_name)
	case "$current" in
	"$1"*)
		echo yes >"$cache"
		return 0
		;;
	esac
	return 1
}
