#!/bin/sh
# Records that the decision review passed for a pull request's current head: a reviewer with a clean
# context (the Agent tool, with briefs/reviewer.md) found the change faithful to the issue's
# `## Technical decisions` and acceptance criteria. merge.sh refuses a head without it.
#   review.sh pass <pr> "<one line: what the reviewer checked>"
set -eu

[ "${1:-}" = pass ] || {
	echo "usage: review.sh pass <pr> \"<what the reviewer checked>\"" >&2
	exit 2
}
pr=${2:?pull request number}
summary=${3:?one line: what the reviewer checked}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
mkdir -p "$repo_dir/review"
printf '%s\t%s\n' "$head" "$summary" >"$repo_dir/review/$pr"
echo "decision review recorded for #$pr at ${head%"${head#???????}"}"
