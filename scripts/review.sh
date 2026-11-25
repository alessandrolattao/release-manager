#!/bin/sh
# Records that the decision review passed for the head of the developer's branch: a reviewer with a clean
# context (the Agent tool, with briefs/reviewer.md) found the change on the branch faithful to the issue's
# `## Technical decisions` and acceptance criteria. It runs on the branch, before the pull request exists, so
# the record is keyed by the issue, with the head the reviewer read (the worktree's HEAD). merge.sh finds it
# through the pull request's issue and refuses a pull request whose head is not that one.
#   review.sh pass <issue> "<one line: what the reviewer checked>"    (from the developer's worktree)
set -eu

[ "${1:-}" = pass ] || {
	echo "usage: review.sh pass <issue> \"<what the reviewer checked>\"" >&2
	exit 2
}
issue=${2:?issue number}
summary=${3:?one line: what the reviewer checked}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
head=$(git rev-parse HEAD)
mkdir -p "$repo_dir/review"
printf '%s\t%s\n' "$head" "$summary" >"$repo_dir/review/$issue"
echo "decision review recorded for issue #$issue at ${head%"${head#???????}"}"
