# Sourced by the hooks: reads the payload on stdin and tells which session it comes from and what it is
# in the team (its role, recorded by scripts/role.sh).
# shellcheck shell=sh disable=SC2034 # the variables are used by the hooks that source this file

payload=$(cat)
field() { printf '%s' "$payload" | sed -n "s/.*\"$1\" *: *\"\\([^\"]*\\)\".*/\\1/p" | head -1; }
sid=$(field session_id)
case "$sid" in
"" | *[!A-Za-z0-9-]*) exit 0 ;;
esac
scripts="${CLAUDE_PLUGIN_ROOT:?}/scripts"
transcript=$(field transcript_path)
# shellcheck source=scripts/session-dir.sh
. "$scripts/session-dir.sh"

# role: tech-lead, dev, qa, spike, or empty for a session outside the team.
role=$(cat "$sessions_dir/$sid/role" 2>/dev/null || true)
