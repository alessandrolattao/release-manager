#!/bin/sh
# Ends a failed test: back to the default branch, and the agent to [fix].
# Send the agent what failed yourself, with SendMessage, to its new name (printed below).
#   qa-fail.sh <branch>
set -eu

branch=${1:?branch}
here=$(cd "$(dirname "$0")" && pwd)
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
git switch -q "$base"
sh "$here/set-state.sh" "$branch" fix
