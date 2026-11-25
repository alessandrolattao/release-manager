#!/bin/sh
# A comment for the record, written to nobody in particular: an issue's `## Technical decisions`, findings, what
# was settled. It goes out with the user's GitHub account, as every comment of the team, so a hidden last line
# signs it (`<!-- team · <address> -->`): the plugin then knows it is not the user's, wakes nobody for its
# author, and tells the developer and the QA agent of that issue. The session's `commented` records it
# (session-dir.sh commented_on): a wake for a comment the user wrote on that thread before is not delivered.
#   note.sh <issue-or-pr> <<'EOF'
#   ## Technical decisions
#   ...
#   EOF
# Prints the comment's link.
set -eu

target=${1:?issue or pull request number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/rest.sh
. "$here/rest.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "the comment comes on stdin" >&2
	exit 2
}
me=${CLAUDE_CODE_SESSION_ID:-}
printf '%s\n\n<!-- team · %s -->\n' "$body" "$(address_of "$me")" |
	rest_body "repos/$repo_full/issues/$target/comments" --jq .html_url
commented_on "$me" "$(thread_of "$target")"
