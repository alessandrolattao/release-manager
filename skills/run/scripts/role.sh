#!/bin/sh
# Records that a session is the release manager or the planner of the repository it runs in. From then on
# the plugin's hooks module gives it its goal (/goal) each time it starts and keeps its heartbeat, and
# hooks/revive.sh resumes it after the machine restarts if it was running when the machine went down.
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
# The goals never come true while the project lives: they keep the session awake, waiting for work.
case "$role" in
manager) goal="Triage and test every issue the planner assigns to you, coordinating with the planner and the developers." ;;
planner) goal="Do the technical analyses and set up the work so that the release manager can coordinate development." ;;
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
want "$id" goal "$goal"
