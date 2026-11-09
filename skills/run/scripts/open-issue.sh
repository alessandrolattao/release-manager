#!/bin/sh
# Opens an issue from the release manager: it goes to the backlog (no "ready for development") and
# the planner's 🧠 counter goes up.
#   open-issue.sh "<title>" <assignee login or @me> <<'EOF'
#   the body, written with the repository's conventions
#   EOF
# Prints the new issue's URL.
set -eu

title=${1:?title}
assignee=${2:?assignee login or @me}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "the body comes on stdin" >&2
	exit 2
}
url=$(printf '%s\n' "$body" | gh issue create --title "$title" --assignee "$assignee" --body-file -)
echo "$url"

planner=$(session_of "$planner_prefix")
[ -n "$planner" ] || exit 0
id=$(printf '%s' "$planner" | cut -f1)
sh "$here/sync-names.sh" planner "$id" >/dev/null 2>&1 || true
