#!/bin/sh
# The GitHub project boards of the repository and their Status field.
#   project.sh <issue-number> "<status, e.g. In Progress>"
#       sets the issue's Status on every board it is on, when the board has that option; for a board that
#       lacks it, says so with the status its card stays in
#   project.sh check
#       prints each board linked to the repository whose Status field lacks one of the statuses the plugin
#       sets (Todo, In Progress, In Review, Done), with what it lacks and, when the user was already asked
#       about it, their answer: (asked: yes|no); otherwise what to do: ask the user, then project.sh asked.
#       Nothing when every board has them or there is no board
#   project.sh asked <project number> yes|no
#       records the user's answer about adding a board's missing statuses, so it is asked once
#   project.sh add-status <project number> "<status>"
#       adds the option to the board's Status field, keeping every existing option and every card's value
# Option names are compared without case.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
tab=$(printf '\t')

move() {
	issue=$1
	status=$2
	# One line per board the issue is on: "move", its project, item, field and option ids and its title; or
	# "lack", its title and the status the card has now (empty when it has none).
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	items=$(gh api graphql -f query='query($o: String!, $n: String!, $i: Int!) { repository(owner: $o, name: $n) {
		issue(number: $i) { projectItems(first: 10) { nodes { id
			fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
			project { id title field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } } } } } } } }' \
		-F o="${repo_full%/*}" -F n="${repo_full#*/}" -F i="$issue" 2>/dev/null |
		jq -r --arg s "$status" '.data.repository.issue.projectItems.nodes[]
			| ([.project.field.options[]? | select((.name | ascii_downcase) == ($s | ascii_downcase)) | .id][0]) as $opt
			| if $opt then ["move", .project.id, .id, .project.field.id, $opt, .project.title]
			  else ["lack", .project.title, (.fieldValueByName.name // "")] end
			| @tsv' 2>/dev/null) || items=""
	[ -n "$items" ] || return 0
	printf '%s\n' "$items" | while IFS="$tab" read -r kind a b c d e; do
		case "$kind" in
		move)
			# shellcheck disable=SC2016 # GraphQL variables, not shell ones
			gh api graphql -f query='mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) { updateProjectV2ItemFieldValue(input: {
				projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { clientMutationId } }' \
				-F p="$a" -F i="$b" -F f="$c" -F o="$d" >/dev/null
			echo "issue $issue: $status on $e"
			;;
		lack)
			if [ -n "$b" ]; then
				echo "board \"$a\" has no \"$status\" status: its card stays in \"$b\""
			else
				echo "board \"$a\" has no \"$status\" status: its card has no status"
			fi
			;;
		esac
	done
}

check() {
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	gh api graphql -f query='query($o: String!, $n: String!) { repository(owner: $o, name: $n) {
		projectsV2(first: 50) { nodes { number title
			field(name: "Status") { ... on ProjectV2SingleSelectField { options { name } } } } } } }' \
		-F o="${repo_full%/*}" -F n="${repo_full#*/}" |
		jq -r '.data.repository.projectsV2.nodes[]
			| if .field.options == null then "\(.number)\tboard \(.number) \"\(.title)\" has no Status field\tit"
			  else ([.field.options[].name | ascii_downcase]) as $have
				| [("Todo", "In Progress", "In Review", "Done") | select(ascii_downcase as $w | $have | index($w) | not)] as $lack
				| select($lack | length > 0)
				| "\(.number)\tboard \(.number) \"\(.title)\" lacks: \($lack | join(", "))\t\(if ($lack | length) == 1 then "it" else "them" end)" end' |
		while IFS="$tab" read -r number line what; do
			answer=$(cat "$repo_dir/board-asked.$number" 2>/dev/null || true)
			# A board never asked about says what to do with it.
			if [ -n "$answer" ]; then
				echo "$line (asked: $answer)"
			else
				echo "$line. Ask the user whether to add $what, then: project.sh asked $number yes|no"
			fi
		done
}

asked() {
	number=$1
	answer=$2
	if ! printf '%s' "$number" | grep -q '^[0-9][0-9]*$' || { [ "$answer" != yes ] && [ "$answer" != no ]; }; then
		echo "usage: project.sh asked <project number> yes|no" >&2
		exit 2
	fi
	printf '%s\n' "$answer" >"$repo_dir/board-asked.$number"
	echo "board $number: the user's answer is recorded ($answer)"
}

add_status() {
	number=$1
	status=$2
	case "$number" in "" | *[!0-9]*)
		echo "usage: project.sh add-status <project number> \"<status>\"" >&2
		exit 2
		;;
	esac
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	board=$(gh api graphql -f query='query($o: String!, $n: String!, $p: Int!) { repository(owner: $o, name: $n) {
		projectV2(number: $p) { title field(name: "Status") { ... on ProjectV2SingleSelectField { id
			options { id name color description } } } } } }' \
		-F o="${repo_full%/*}" -F n="${repo_full#*/}" -F p="$number" --jq '.data.repository.projectV2')
	[ -n "$board" ] && [ "$board" != null ] || {
		echo "the repository has no board $number" >&2
		exit 1
	}
	title=$(printf '%s' "$board" | jq -r .title)
	[ "$(printf '%s' "$board" | jq -r '.field.id // empty')" ] || {
		echo "board $number \"$title\" has no Status field" >&2
		exit 1
	}
	if printf '%s' "$board" | jq -e --arg s "$status" \
		'any(.field.options[]; (.name | ascii_downcase) == ($s | ascii_downcase))' >/dev/null; then
		echo "board $number \"$title\" already has \"$status\""
		return 0
	fi
	# The whole list goes back: the existing options with their ids (so no card loses its value), and the new
	# one before the first existing one that comes after it in the plugin's order (Todo, In Progress, In
	# Review, Done), otherwise at the end. GitHub shows a board's columns in this order.
	# shellcheck disable=SC2016 # GraphQL variables, not shell ones
	query='mutation($f: ID!, $o: [ProjectV2SingleSelectFieldOptionInput!]) {
		updateProjectV2Field(input: {fieldId: $f, singleSelectOptions: $o}) {
			projectV2Field { ... on ProjectV2SingleSelectField { options { id name } } } } }'
	sent=$(printf '%s' "$board" | jq -c --arg s "$status" --arg q "$query" '
		[.field.options[] | {id, name, color, description}] as $old
		| ["todo", "in progress", "in review", "done"] as $order
		| ($order | index($s | ascii_downcase)) as $r
		| ([range(0; $old | length) as $i | ($order | index($old[$i].name | ascii_downcase)) as $k
			| select($r != null and $k != null and $k > $r) | $i][0] // ($old | length)) as $at
		| {query: $q, variables: {f: .field.id,
			o: ($old[0:$at] + [{name: $s, color: "GRAY", description: ""}] + $old[$at:])}}')
	after=$(printf '%s' "$sent" | gh api graphql --input - --jq '.data.updateProjectV2Field.projectV2Field.options')
	# Every option it had keeps its id, and the new one is there.
	printf '%s' "$board" | jq -e --argjson after "$after" --arg s "$status" \
		'([.field.options[].id] - [$after[].id] | length == 0) and any($after[]; .name == $s)' >/dev/null || {
		echo "board $number \"$title\": the Status field did not come back as expected: $after" >&2
		exit 1
	}
	echo "board $number \"$title\": \"$status\" added to its Status"
}

case "${1:-}" in
check) check ;;
asked) asked "${2:-}" "${3:-}" ;;
add-status) add_status "${2:-}" "${3:?status}" ;;
"" | *[!0-9]*)
	echo "usage: project.sh <issue> \"<status>\" | check | asked <project number> yes|no | add-status <project number> \"<status>\"" >&2
	exit 2
	;;
*) move "$1" "${2:?status}" ;;
esac
