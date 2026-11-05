#!/bin/sh
# Sets the color of a background session, the one /color sets, from inside it or from anywhere else.
#   color.sh <session-id> <red|blue|green|yellow|purple|orange|pink|cyan|default>
# Works for background sessions (claude --bg); the session keeps working while its color changes.
set -eu

id=${1:?session id}
color=${2:?color}
case "$color" in
red | blue | green | yellow | purple | orange | pink | cyan | default) ;;
*)
	echo "unknown color '$color': red, blue, green, yellow, purple, orange, pink, cyan or default" >&2
	exit 2
	;;
esac
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
claude=$(command -v claude) || {
	echo "claude not found" >&2
	exit 1
}
exec python3 -I "$(dirname "$0")/ui.py" "$claude" "$id" color "$color"
