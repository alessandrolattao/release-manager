#!/bin/sh
# Sets the organization issue fields Priority and Effort of an issue.
#   set-fields.sh <issue-number> <Urgent|High|Medium|Low> <High|Medium|Low>
# Repositories of a personal account have no issue fields: the script says so and changes nothing.
set -eu

issue=${1:?issue number}
priority=${2:?Urgent, High, Medium or Low}
effort=${3:?High, Medium or Low}
repo=$(gh repo view --json nameWithOwner,owner --jq '"\(.nameWithOwner) \(.owner.login)"')
owner=${repo#* }
repo=${repo% *}

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
fields=$(gh api graphql -f query='query($o: String!) { organization(login: $o) { issueFields(first: 20) {
	nodes { ... on IssueFieldSingleSelect { id name options { id name } } } } } }' -F o="$owner" \
	--jq '.data.organization.issueFields.nodes' 2>/dev/null || echo null)
if [ "$fields" = null ] || [ -z "$fields" ]; then
	echo "$owner has no issue fields: Priority and Effort not set"
	exit 0
fi

pick() { echo "$fields" | jq -r --arg f "$1" --arg o "$2" '.[] | select(.name == $f) | .id as $fid
	| .options[] | select(.name == $o) | "\($fid) \(.id)"'; }
p=$(pick Priority "$priority")
e=$(pick Effort "$effort")
[ -n "$p" ] && [ -n "$e" ] || {
	echo "unknown Priority '$priority' or Effort '$effort'" >&2
	exit 1
}

id=$(gh issue view "$issue" -R "$repo" --json id --jq .id)
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
gh api graphql -f query='mutation($i: ID!, $pf: ID!, $po: ID!, $ef: ID!, $eo: ID!) {
	setIssueFieldValue(input: {issueId: $i, issueFields: [
		{fieldId: $pf, singleSelectOptionId: $po}, {fieldId: $ef, singleSelectOptionId: $eo}]}) { clientMutationId } }' \
	-F i="$id" -F pf="${p% *}" -F po="${p#* }" -F ef="${e% *}" -F eo="${e#* }" >/dev/null
echo "issue $issue: Priority $priority, Effort $effort"
