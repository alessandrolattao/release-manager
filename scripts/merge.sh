#!/bin/sh
# The developer merges its own pull request, once everything holds for its current head:
#   - the decision review passed (review.sh);
#   - the QA passed, when the issue carries the label qa (qa.sh);
#   - every check of the pull request is green;
#   - the default branch's CI is not red, unless this pull request closes the bug opened for it.
# The method comes from the user's rules for the repository ("merge: merge|rebase|squash", merge commit when
# none); "merge: user" means the user merges here: hand the pull request over with comment.sh <pr> you.
# Then run main-ci.sh --wait in the background: the default branch's CI is yours until it is green.
#   merge.sh <pr>
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
refuse() {
	echo "NOT MERGED: $1" >&2
	exit 1
}

method=$(rule merge)
method=${method:-merge}
case "${method:-merge}" in
merge | rebase | squash) ;;
user) refuse "the user merges in this repository: hand the pull request over with comment.sh $pr you" ;;
*) refuse "the user's rules say 'merge: $method', which is not merge, rebase, squash or user" ;;
esac

info=$(gh pr view "$pr" --json headRefOid,state,mergeable,closingIssuesReferences)
[ "$(printf '%s' "$info" | jq -r .state)" = OPEN ] || refuse "#$pr is not open"
head=$(printf '%s' "$info" | jq -r .headRefOid)
issue=$(printf '%s' "$info" | jq -r '.closingIssuesReferences[0].number // empty')

[ "$(cut -f1 "$repo_dir/review/$pr" 2>/dev/null || true)" = "$head" ] ||
	refuse "no decision review for the current head: run the reviewer (briefs/reviewer.md), then review.sh pass $pr \"...\""
if [ -n "$issue" ] && [ "$(sh "$here/qa.sh" needed "$issue")" = yes ]; then
	[ "$(cut -f1,2 "$repo_dir/qa/$pr" 2>/dev/null || true)" = "pass	$head" ] ||
		refuse "issue #$issue carries the label qa and the QA has not passed this head: qa.sh request $pr"
fi
[ "$(printf '%s' "$info" | jq -r .mergeable)" != CONFLICTING ] ||
	refuse "#$pr conflicts with the default branch: merge it into your branch (no rebase, no force push), push, and start over"
if ! checks=$(gh pr checks "$pr" --json state,name 2>/dev/null); then
	checks='[]'
fi
bad=$(printf '%s' "$checks" | jq -r '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED" and .state != "NEUTRAL") | "\(.name): \(.state)"] | join(", ")')
[ -z "$bad" ] || refuse "checks not green: $bad"

if [ -f "$repo_dir/main-red" ]; then
	bug=$(sed -n 2p "$repo_dir/main-red")
	closes=$(printf '%s' "$info" | jq -r '[.closingIssuesReferences[].number] | map(tostring) | join(" ")')
	case " $closes " in
	*" $bug "*) ;;
	*) refuse "the default branch's CI is red (issue #$bug): only the pull request that closes #$bug merges now" ;;
	esac
fi

gh pr merge "$pr" "--$method"
echo "merged #$pr ($method)"
[ -z "$me" ] || state_set "$me" working "mergiata #$pr, aspetta la CI di main"
echo "next: sh \"$here/main-ci.sh\" --wait, in the background"
