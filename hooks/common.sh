# Sourced by the hooks: reads the payload on stdin and finds the session's name in `claude agents`.
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

# session_name prints this session's name, or nothing when it is not a background session.
session_name() {
	claude agents --json 2>/dev/null | jq -r --arg s "$sid" '[.[] | select(.sessionId == $s) | .name][0] // empty'
}
