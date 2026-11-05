#!/bin/sh
# Has the planner of this repository say the sentence on stdin out loud through TitTieS.
#   call.sh <<'EOF'
#   The release manager of my-app has run out of work: 2 issues are waiting for your answer.
#   EOF
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
planner=$(session_of "$planner_prefix")
if [ -z "$planner" ]; then
	echo "no planner running for $repo_short: nothing said"
	exit 0
fi
exec sh "$here/titties.sh" call "$(printf '%s' "$planner" | cut -f1)"
