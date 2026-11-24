#!/bin/sh
# Lists the open issues of this repository assigned to you, best first, as one JSON object per line:
#   {"number":12,"title":"...","priority":"High","effort":"Low","blockedBy":[34],"question":false,"ready":true,"backlog":false,"workable":true}
# ready is true when the issue carries the label "ready for development"; without it the issue is in the backlog.
# workable is true when it is ready, no open issue blocks it and it does not carry the question label.
# Order: Priority Urgent, High, Medium, Low, then none (Priority only orders, it does not make an issue ready); oldest first.
set -eu

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
owner=${repo%/*}
name=${repo#*/}
me=$(gh api user --jq .login)

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
query='query($owner: String!, $name: String!, $me: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 50, after: $endCursor, filterBy: {assignee: $me}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        labels(first: 30) { nodes { name } }
        blockedBy(first: 20) { nodes { number state repository { nameWithOwner } } }
        issueFieldValues(first: 10) {
          nodes { ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } } }
        }
      }
    }
  }
}'

gh api graphql --paginate -f query="$query" -F owner="$owner" -F name="$name" -F me="$me" \
	--jq '.data.repository.issues.nodes[]' |
	jq -c --arg repo "$repo" '
		def field($f): [.issueFieldValues.nodes[] | select(.field.name? == $f) | .name][0];
		{
			number,
			title,
			priority: field("Priority"),
			effort: field("Effort"),
			blockedBy: [.blockedBy.nodes[] | select(.state == "OPEN")
				| if .repository.nameWithOwner == $repo then .number else "\(.repository.nameWithOwner)#\(.number)" end],
			question: ([.labels.nodes[].name] | index("question") != null),
			ready: ([.labels.nodes[].name] | index("ready for development") != null)
		}
		| .backlog = (.ready | not)
		| .workable = ((.backlog | not) and (.blockedBy | length) == 0 and (.question | not))
	' |
	jq -s -c 'sort_by((.priority | {"Urgent": 0, "High": 1, "Medium": 2, "Low": 3}[. // ""] // 4), .number) | .[]'
