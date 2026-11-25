#!/bin/sh
# Sets an issue's own status on GitHub (not a project's), and keeps the Status of every project board the
# issue is on in line with it, when the board has the matching option.
#   issue-status.sh <issue> todo|in_progress|in_review
# todo: Todo (Todo on boards); in_progress: In progress (In Progress); in_review: In review (In Review).
# A board that lacks the option is named on the same line, with the status its card stays in:
#   issue 42: In review (board "Roadmap" has no "In Review" status: its card stays in "In Progress")
set -eu

issue=${1:?issue number}
want=${2:?todo, in_progress or in_review}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"

case "$want" in
todo) name="Todo" board="Todo" stage="todo" ;;
in_progress) name="In progress" board="In Progress" stage="in progress" ;;
in_review) name="In review" board="In Review" stage="in review" ;;
*)
	echo "usage: issue-status.sh <issue> todo|in_progress|in_review" >&2
	exit 2
	;;
esac

# The repository's statuses, asked once.
statuses="$repo_dir/issue-statuses.json"
if [ ! -s "$statuses" ]; then
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	gh api graphql -f query='query($o: String!, $n: String!) { repository(owner: $o, name: $n) {
		planningStatuses(first: 30) { nodes { id name } } } }' -F o="${repo_full%/*}" -F n="${repo_full#*/}" \
		--jq '.data.repository.planningStatuses.nodes' >"$statuses.$$" && mv "$statuses.$$" "$statuses"
fi
status_id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' "$statuses" 2>/dev/null | head -1)
[ -n "$status_id" ] || {
	rm -f "$statuses"
	echo "this repository has no issue status '$name'" >&2
	exit 1
}
# shellcheck disable=SC2016
issue_id=$(gh api graphql -f query='query($o: String!, $n: String!, $i: Int!) { repository(owner: $o, name: $n) {
	issue(number: $i) { id } } }' -F o="${repo_full%/*}" -F n="${repo_full#*/}" -F i="$issue" --jq .data.repository.issue.id)
# shellcheck disable=SC2016
gh api graphql -f query='mutation($i: ID!, $s: ID!) { setIssueStatus(input: {issueId: $i, statusId: $s}) {
	issue { number } } }' -F i="$issue_id" -F s="$status_id" >/dev/null
moves=$(sh "$here/project.sh" "$issue" "$board" 2>/dev/null) || true
# The boards that lack the option, one part each, inside the parentheses of the same line.
lacks=$(printf '%s\n' "$moves" | grep '^board "' | awk 'NR > 1 { printf "; " } { printf "%s", $0 }') || true
echo "issue $issue: $name${lacks:+ ($lacks)}"
printf '%s\n' "$moves" | grep -v -e '^board "' -e '^$' || true
# The developer and QA agent of the issue on this machine say the new stage in their names.
for id in $(sessions_of dev "$issue") $(sessions_of qa "$issue"); do
	f="$sessions_dir/$id/status"
	[ "$(jq -r .state "$f")" != done ] || continue
	title=$(jq -r '.title // ""' "$f")
	if [ "$(jq -r .role "$f")" = dev ]; then new=$(dev_name "$issue" "$title" "$stage"); else new=$(qa_name "$issue" "$title" "$stage"); fi
	status_set "$id" --arg s "$stage" --arg n "$new" '.stage = $s | .name = $n'
	want "$id" name "$new"
done
