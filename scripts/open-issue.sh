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
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/rest.sh
. "$here/rest.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "the body comes on stdin" >&2
	exit 2
}
# The REST API takes a login: @me is the team's GitHub account.
[ "$assignee" != @me ] || assignee=$(gh api user --jq .login)
url=$(printf '%s\n' "$body" | rest_body "repos/$repo_full/issues" -f title="$title" -f "assignees[]=$assignee" --jq .html_url)
echo "$url"

