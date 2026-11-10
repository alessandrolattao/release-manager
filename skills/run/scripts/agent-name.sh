#!/bin/sh
# Prints the session name of an agent: its state, the issue's icons and its branch.
#   agent-name.sh <branch> <dev|review|test|fix|ask>   ->   [test]🔥🐛 12-fix-the-login
# Icons: 🔥 Priority Urgent; 🐛 Bug, ✨ Feature, 🔧 Task (the GitHub issue type).
set -eu

branch=${1:?branch}
state=${2:?state}
issue=${branch%%-*}
icons=""
case "$issue" in
"" | *[!0-9]*) ;;
*)
	repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	icons=$(gh api graphql -f query='query($o: String!, $n: String!, $i: Int!) { repository(owner: $o, name: $n) {
		issue(number: $i) { issueType { name }
			issueFieldValues(first: 10) { nodes { ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } } } } } } }' \
		-F o="${repo%/*}" -F n="${repo#*/}" -F i="$issue" --jq '.data.repository.issue |
			(if ([.issueFieldValues.nodes[] | select(.field.name? == "Priority") | .name][0]) == "Urgent" then "🔥" else "" end)
			+ ({"Bug": "🐛", "Feature": "✨", "Task": "🔧"}[.issueType.name // ""] // "")' 2>/dev/null) || icons=""
	# Anything but icons (an error from GitHub, an issue that does not exist) means no icons.
	case "$icons" in *[A-Za-z{}]*) icons="" ;; esac
	;;
esac
printf '[%s]%s %s\n' "$state" "$icons" "$branch"
