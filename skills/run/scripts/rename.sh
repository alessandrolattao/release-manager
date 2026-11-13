#!/bin/sh
# Renames a session, as /rename does, from inside it or from anywhere else.
#   rename.sh <session-id> "<new name>"
# Nothing is typed into the session: the plugin's hooks module, inside it, applies the name as soon as
# the session is between turns (a name asked mid-turn shows when the turn ends) and hides /rename's rows.
# After a rename the old name no longer reaches the session: message it by the new one.
set -eu

id=${1:?session id}
name=${2:?new name}
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
case "$name" in
*"
"*)
	echo "a name is one line" >&2
	exit 2
	;;
esac
# shellcheck source=skills/run/scripts/session-dir.sh
. "$(dirname "$0")/session-dir.sh"
want "$id" name "$name"
