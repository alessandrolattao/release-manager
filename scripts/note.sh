#!/bin/sh
# A comment for the record, written to nobody in particular: an issue's `## Technical decisions`, findings, what
# was settled. It goes out with the user's GitHub account, as every comment of the team, so a hidden last line
# signs it (`<!-- team · <address> -->`): the plugin then knows it is not the user's, wakes nobody for its
# author, and tells the developer and the QA agent of that issue.
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
body=$(cat)
[ -n "$body" ] || {
	echo "the comment comes on stdin" >&2
	exit 2
}
printf '%s\n\n<!-- team · %s -->\n' "$body" "$(address_of "${CLAUDE_CODE_SESSION_ID:-}")" | gh issue comment "$target" --body-file -
