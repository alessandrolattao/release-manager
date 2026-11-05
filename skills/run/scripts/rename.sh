#!/bin/sh
# Renames a background session, as /rename does, from inside it or from anywhere else.
#   rename.sh <session-id> "<new name>"
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
claude=$(command -v claude) || {
	echo "claude not found" >&2
	exit 1
}
exec python3 -I "$(dirname "$0")/ui.py" "$claude" "$id" rename "$name"
