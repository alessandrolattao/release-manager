#!/bin/sh
# Opens an issue in this repository's backlog (no "ready for development"): a new topic the work brought
# up, or a bug of the default branch's CI. The tech leads prepare it with the user.
#   open-issue.sh "<title>" <assignee login or @me> <<'EOF'
#   the body, written with the repository's conventions
#   EOF
# Prints the new issue's URL.
set -eu

title=${1:?title}
assignee=${2:?assignee login or @me}
here=$(cd "$(dirname "$0")" && pwd)
body=$(cat)
[ -n "$body" ] || {
	echo "the body comes on stdin" >&2
	exit 2
}
url=$(printf '%s\n' "$body" | gh issue create --title "$title" --assignee "$assignee" --body-file -)
echo "$url"

