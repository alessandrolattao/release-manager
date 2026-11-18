#!/bin/sh
# Records that a session is the release manager or the planner of the repository it runs in. From then on
# the plugin's hooks module keeps its heartbeat, the plugin's monitor wakes it between turns when there is
# something for it, and hooks/revive.sh resumes it after the machine restarts if it was running when the
# machine went down.
#   role.sh <session-id> manager|planner     (from the session's own folder, as the skills run it)
set -eu

id=${1:?session id}
role=${2:?manager or planner}
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
case "$role" in
manager | planner) ;;
*)
	echo "usage: role.sh <session-id> manager|planner" >&2
	exit 2
	;;
esac
# shellcheck source=skills/run/scripts/session-dir.sh
. "$(dirname "$0")/session-dir.sh"
want "$id" role "$role"
want "$id" cwd "$(pwd)"
want "$id" config "${CLAUDE_CONFIG_DIR:-}"
