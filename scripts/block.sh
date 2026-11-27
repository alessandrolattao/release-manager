#!/bin/sh
# Adds or removes a GitHub "blocked by" relationship between two issues of this repository.
#   block.sh <issue> <blocking-issue>           issue is blocked by blocking-issue
#   block.sh --remove <issue> <blocking-issue>  takes the relationship away
# --remove may come anywhere among the arguments. Any other argument is refused with the usage, and no
# relationship changes.
set -eu

usage() {
	echo "usage: block.sh [--remove] <issue> <blocking-issue>" >&2
	exit 2
}
mutation=addBlockedBy issue="" blocking=""
while [ $# -gt 0 ]; do
	case "$1" in
	--remove) mutation=removeBlockedBy ;;
	-*)
		echo "unknown option '$1'" >&2
		usage
		;;
	*)
		if [ -z "$issue" ]; then
			issue=$1
		elif [ -z "$blocking" ]; then
			blocking=$1
		else
			echo "two issues: '$1' is one too many" >&2
			usage
		fi
		;;
	esac
	shift
done
[ -n "$issue" ] && [ -n "$blocking" ] || usage

id() { gh issue view "$1" --json id --jq .id; }
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
gh api graphql -f query="mutation(\$i: ID!, \$b: ID!) { $mutation(input: {issueId: \$i, blockingIssueId: \$b}) { clientMutationId } }" \
	-F i="$(id "$issue")" -F b="$(id "$blocking")" >/dev/null
if [ "$mutation" = addBlockedBy ]; then
	echo "issue $issue is now blocked by $blocking"
else
	echo "issue $issue is no longer blocked by $blocking"
fi
