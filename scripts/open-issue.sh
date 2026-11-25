#!/bin/sh
# Opens an issue in this repository's backlog (no "ready for development"): a new topic the work brought
# up, or a bug of the default branch's CI. The tech leads prepare it with the user.
#   open-issue.sh "<title>" <assignee login or @me> [--repo <owner/name>] <<'EOF'
#   the body, written with the repository's conventions
#   EOF
#   --repo <owner/name>   on ANOTHER repository, from a tech lead only: what must become true there, its body
#                         signed `<!-- team · tech lead of <this repository> -->`, so its dispatcher wakes its
#                         tech lead with it. Its technical analysis stays with that tech lead.
# Prints the new issue's URL.
set -eu

title=${1:?title}
assignee=${2:?assignee login or @me}
shift 2
elsewhere=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo)
		elsewhere=${2:?owner/name of the other repository}
		shift 2
		;;
	*)
		echo "unknown option '$1'" >&2
		exit 2
		;;
	esac
done
here=$(cd "$(dirname "$0")" && pwd)
body=$(cat)
[ -n "$body" ] || {
	echo "the body comes on stdin" >&2
	exit 2
}
if [ -n "$elsewhere" ]; then
	# shellcheck source=scripts/repo.sh
	. "$here/repo.sh"
	may_write_elsewhere "${CLAUDE_CODE_SESSION_ID:-}" "$elsewhere"
	url=$(printf '%s\n\n<!-- team · %s -->\n' "$body" "$signer_elsewhere" |
		gh issue create -R "$elsewhere" --title "$title" --assignee "$assignee" --body-file -)
	echo "$url"
	exit 0
fi
url=$(printf '%s\n' "$body" | gh issue create --title "$title" --assignee "$assignee" --body-file -)
echo "$url"
