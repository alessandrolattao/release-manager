#!/bin/sh
# Makes this tech lead the one who follows an issue: the developer's and the QA agent's comments to
# "tech lead" on it reach this session, and the board shows the issue under it.
#   follow.sh <issue> [<issue>...]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:?run it from the tech lead session}
address=$(address_of "$me")
for issue in "$@"; do
	mkdir -p "$repo_dir/issues/$issue"
	printf '%s\n' "$address" >"$repo_dir/issues/$issue/tech-lead"
	echo "#$issue followed by $address"
done
