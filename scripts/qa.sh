#!/bin/sh
# QA for a delicate task: an issue with the label `qa` is tested by a separate agent before its merge.
#   qa.sh request <pr>        the developer: asks for it once the pull request is ready; you wait (purple)
#                             and the plugin starts a QA agent, which writes its outcome on the pull request
#   qa.sh pass <pr> | fail <pr>   the QA agent: records the outcome for the pull request's current head, with
#                             its time (UTC)
#   qa.sh needed <issue>      prints yes when the issue carries the label qa
# merge.sh refuses a pull request of a `qa` issue that has no pass for its head, or a pass recorded before the
# issue's latest `## Technical decisions`.
set -eu

action=${1:?request, pass, fail or needed}
number=${2:?pull request or issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
mkdir -p "$repo_dir/qa"

case "$action" in
needed)
	gh issue view "$number" --json labels --jq 'if any(.labels[]; .name == "qa") then "yes" else "no" end'
	;;
request)
	head=$(gh pr view "$number" --json headRefOid --jq .headRefOid)
	issue=$(jq -r '.issue // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	printf 'requested\t%s\t%s\t%s\n' "$head" "${issue:-?}" "$me" >"$repo_dir/qa/$number"
	[ -z "$me" ] || state_set "$me" others "waits for QA on PR #$number"
	echo "QA requested for #$number at ${head%"${head#???????}"}: the plugin starts a QA agent"
	;;
pass | fail)
	# The head the QA agent tested in the main checkout (checkout.sh take records it); a push made while it
	# tested is not passed with it.
	head=$(jq -r '.tested_head // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	[ -n "$head" ] || head=$(gh pr view "$number" --json headRefOid --jq .headRefOid)
	printf '%s\t%s\t%s\n' "$action" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$repo_dir/qa/$number"
	echo "QA $action recorded for #$number at ${head%"${head#???????}"}"
	;;
*)
	echo "usage: qa.sh request|pass|fail <pr> | needed <issue>" >&2
	exit 2
	;;
esac
