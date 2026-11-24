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
[ -n "$issue" ] || issue=$(jq -r '.issue // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
[ -n "$issue" ] || refuse "#$pr closes no issue and this session has none: write Closes #<issue> in its description"

[ "$(cut -f1 "$repo_dir/review/$pr" 2>/dev/null || true)" = "$head" ] ||
	refuse "no decision review for the current head: run the reviewer (briefs/reviewer.md), then review.sh pass $pr \"...\""
needed=$(sh "$here/qa.sh" needed "$issue" 2>/dev/null || true)
case "$needed" in
yes)
	[ "$(cut -f1,2 "$repo_dir/qa/$pr" 2>/dev/null || true)" = "pass	$head" ] ||
		refuse "issue #$issue carries the label qa and the QA has not passed this head: qa.sh request $pr"
	;;
no) ;;
*) refuse "could not read the labels of #$issue: try again" ;;
esac
[ "$(printf '%s' "$info" | jq -r .mergeable)" != CONFLICTING ] ||
	refuse "#$pr conflicts with the default branch: merge it into your branch (no rebase, no force push), push, and start over"
# gh exits non-zero for pending or failing checks too: only an answer that is not a list, other than "no
# checks reported", is a failure to read them, and that refuses.
err=$(mktemp)
checks=$(gh pr checks "$pr" --json state,name 2>"$err") || true
if ! printf '%s' "$checks" | jq -e 'type == "array"' >/dev/null 2>&1; then
	if grep -qi 'no checks reported' "$err"; then
		checks='[]'
	else
		reason=$(head -1 "$err")
		rm -f "$err"
		refuse "could not read the checks of #$pr: ${reason:-no answer}"
	fi
fi
rm -f "$err"
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

# Only the head that was reviewed and checked: a push in between makes GitHub refuse the merge.
gh pr merge "$pr" "--$method" --match-head-commit "$head"
echo "merged #$pr ($method)"
[ -z "$me" ] || state_set "$me" working "merged #$pr, waits for the default branch's CI"
echo "next: sh \"$here/main-ci.sh\" --wait, in the background"
