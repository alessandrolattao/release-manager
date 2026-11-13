#!/bin/sh
# Sets the color of a session, the one /color sets, from inside it or from anywhere else.
#   color.sh <session-id> <red|blue|green|yellow|purple|orange|pink|cyan|default>
# Nothing is typed into the session: the plugin's hooks module, inside it, applies the color as soon as
# the session is between turns (a color asked mid-turn shows when the turn ends) and hides /color's rows.
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
# shellcheck source=skills/run/scripts/session-dir.sh
. "$(dirname "$0")/session-dir.sh"
want "$id" color "$color"
