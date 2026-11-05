#!/bin/sh
# Puts the main checkout on a pull request's code to test it, and moves its agent to [test].
#   qa-start.sh <branch>
set -eu

branch=${1:?branch}
here=$(cd "$(dirname "$0")" && pwd)
[ -z "$(git status --porcelain)" ] || {
	echo "the main checkout has uncommitted changes: test nothing until it is clean" >&2
	exit 1
}
git fetch -q origin "$branch"
git switch -q --detach "origin/$branch"
echo "main checkout on origin/$branch ($(git rev-parse --short HEAD))"
sh "$here/set-state.sh" "$branch" test
