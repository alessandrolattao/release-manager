#!/bin/sh
# Marks an issue ready for development (label "ready for development", created when missing), or takes it back.
#   ready.sh <issue-number>           the issue enters the queue: the dispatcher starts a developer on it
#   ready.sh --remove <issue-number>  back to the backlog
# --remove may come anywhere among the arguments. Any other argument is refused with the usage, and nothing
# changes on the issue.
set -eu

usage() {
	echo "usage: ready.sh [--remove] <issue-number>" >&2
	exit 2
}
action=add issue=""
while [ $# -gt 0 ]; do
	case "$1" in
	--remove) action=remove ;;
	-*)
		echo "unknown option '$1'" >&2
		usage
		;;
	*)
		[ -z "$issue" ] || {
			echo "one issue: '$1' is one too many" >&2
			usage
		}
		issue=$1
		;;
	esac
	shift
done
[ -n "$issue" ] || usage

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/rest.sh
. "$here/rest.sh"
label="ready for development"
if [ "$action" = add ]; then
	# The label lets a developer take the issue: never before its technical decisions are posted.
	decided=$(gh issue view "$issue" --json comments --jq '[.comments[].body | select(startswith("## Technical decisions"))] | length')
	[ "${decided:-0}" -gt 0 ] || {
		echo "issue $issue has no '## Technical decisions' comment yet: post the decisions first, then mark it ready" >&2
		exit 1
	}
	gh label list --limit 200 --json name --jq '.[].name' | grep -qxF "$label" ||
		rest "repos/$repo_full/labels" -f name="$label" -f color=0E8A16 -f description="Technical decisions taken: a developer may build it" >/dev/null
	rest "repos/$repo_full/issues/$issue/labels" -f "labels[]=$label" >/dev/null
	echo "issue $issue: ready for development"
else
	# An issue without the label is already in the backlog: GitHub answers "Label does not exist" (404).
	err=$(rest -X DELETE "repos/$repo_full/issues/$issue/labels/$(printf '%s' "$label" | jq -sRr @uri)" 2>&1 >/dev/null) ||
		case "$err" in *"Label does not exist"*) ;; *)
			printf '%s\n' "$err" >&2
			exit 1
			;;
		esac
	echo "issue $issue: back to the backlog"
fi
