#!/bin/sh
# Calls the user out loud through TitTieS with the sentence on stdin: who calls and what for.
#   call.sh <release-manager-session-id> <<'EOF'
#   The release manager of my-app has run out of work: 2 issues are waiting for your answer.
#   EOF
set -eu

id=${1:?session id}
exec sh "$(dirname "$0")/titties.sh" call "$id"
