#!/bin/sh
# Adds or removes a GitHub "blocked by" relationship between two issues of this repository.
#   block.sh <issue> <blocking-issue>           issue is blocked by blocking-issue
#   block.sh --remove <issue> <blocking-issue>  takes the relationship away
set -eu

mutation=addBlockedBy
if [ "${1:-}" = --remove ]; then
	mutation=removeBlockedBy
	shift
fi
issue=${1:?issue number}
blocking=${2:?blocking issue number}

id() { gh issue view "$1" --json id --jq .id; }
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
gh api graphql -f query="mutation(\$i: ID!, \$b: ID!) { $mutation(input: {issueId: \$i, blockingIssueId: \$b}) { clientMutationId } }" \
	-F i="$(id "$issue")" -F b="$(id "$blocking")" >/dev/null
if [ "$mutation" = addBlockedBy ]; then
	echo "issue $issue is now blocked by $blocking"
else
	echo "issue $issue is no longer blocked by $blocking"
fi
