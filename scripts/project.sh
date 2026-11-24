#!/bin/sh
# Sets the Status of an issue on every GitHub project board it is on, when the board has that option.
#   board.sh <issue-number> "<status, e.g. In Progress>"
set -eu

issue=${1:?issue number}
status=${2:?status}
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
items=$(gh api graphql -f query='query($o: String!, $n: String!, $i: Int!) { repository(owner: $o, name: $n) {
	issue(number: $i) { projectItems(first: 10) { nodes { id project { id title
		field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } } } } } } } }' \
	-F o="${repo%/*}" -F n="${repo#*/}" -F i="$issue" 2>/dev/null |
	jq -r --arg s "$status" '.data.repository.issue.projectItems.nodes[]
		| select(.project.field != null)
		| (.project.field.options[] | select(.name == $s) | .id) as $opt
		| "\(.project.id) \(.id) \(.project.field.id) \($opt) \(.project.title)"' 2>/dev/null) || items=""
[ -n "$items" ] || {
	echo "issue $issue is on no board with a Status '$status'"
	exit 0
}
printf '%s\n' "$items" | while read -r project item field option title; do
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	gh api graphql -f query='mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) { updateProjectV2ItemFieldValue(input: {
		projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { clientMutationId } }' \
		-F p="$project" -F i="$item" -F f="$field" -F o="$option" >/dev/null
	echo "issue $issue: $status on $title"
done
