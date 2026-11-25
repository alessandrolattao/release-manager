#!/bin/sh
# The developer merges its own pull request, once everything holds for its current head:
#   - the decision review passed (review.sh);
#   - the QA passed, when the issue carries the label qa (qa.sh);
#   - neither was recorded before the issue's latest `## Technical decisions` comment;
#   - every check of the pull request is green.
# The review and QA records are keyed by the pull request's issue, since they are taken on the branch before
# the pull request exists; each counts only for the head it names.
# A red default branch stops nobody: it is red for many reasons, most of them someone else's.
# The method is the one the repository's own instructions ask for (--rebase, --squash); without one, a merge
# commit when the repository allows it, else the method it allows.
# Then run main-ci.sh <pr> --wait in the background: it follows the CI and deploy of the merge.
#   merge.sh <pr> [--merge|--rebase|--squash]
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

method=$(merge_method "${2:-}") || {
	echo "usage: merge.sh <pr> [--merge|--rebase|--squash]" >&2
	exit 2
}

info=$(gh pr view "$pr" --json headRefOid,state,mergeable,closingIssuesReferences)
[ "$(printf '%s' "$info" | jq -r .state)" = OPEN ] || refuse "#$pr is not open"
head=$(printf '%s' "$info" | jq -r .headRefOid)
issue=$(printf '%s' "$info" | jq -r '.closingIssuesReferences[0].number // empty')
[ -n "$issue" ] || issue=$(jq -r '.issue // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
[ -n "$issue" ] || refuse "#$pr closes no issue and this session has none: write Closes #<issue> in its description"

[ "$(cut -f1 "$repo_dir/review/$issue" 2>/dev/null || true)" = "$head" ] ||
	refuse "no decision review for the current head: run the reviewer (briefs/reviewer.md), then review.sh pass $issue \"...\""
# A review or a QA pass recorded before the issue's latest `## Technical decisions` checked older decisions. The
# times are UTC in GitHub's own format, so they compare as text; a record of an older version, with no time,
# is older than any decision.
decided=$(gh issue view "$issue" --json comments \
	--jq '[.comments[] | select(.body | startswith("## Technical decisions")) | .createdAt] | max // empty' 2>/dev/null) ||
	refuse "could not read the comments of #$issue: try again"
# before_decisions <recorded time>: succeeds when the latest decisions are newer than it.
before_decisions() {
	[ -n "$decided" ] || return 1
	case "$1" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
	*) return 0 ;;
	esac
	jq -n -e --arg at "$1" --arg decided "$decided" '$decided > $at' >/dev/null
}
if before_decisions "$(cut -f2 "$repo_dir/review/$issue")"; then
	refuse "the decisions changed after the review: run the decision review again"
fi
needed=$(sh "$here/qa.sh" needed "$issue" 2>/dev/null || true)
case "$needed" in
yes)
	[ "$(cut -f1,2 "$repo_dir/qa/$issue" 2>/dev/null || true)" = "pass	$head" ] ||
		refuse "issue #$issue carries the label qa and the QA has not passed this head: qa.sh request $issue"
	if before_decisions "$(cut -f3 "$repo_dir/qa/$issue")"; then
		refuse "the decisions changed after the QA: qa.sh request $issue"
	fi
	;;
no) ;;
*) refuse "could not read the labels of #$issue: try again" ;;
esac
[ "$(printf '%s' "$info" | jq -r .mergeable)" != CONFLICTING ] ||
	refuse "#$pr conflicts with the default branch: bring it into your branch the way the repository's instructions say (a merge when they say nothing, a rebase with a force push of your own branch only where they ask for it), push, and start over"
bad=$(checks_not_green "$pr") || refuse "could not read the checks of #$pr: ${bad:-no answer}"
[ -z "$bad" ] || refuse "checks not green: $bad"

# Only the head that was reviewed and checked: a push in between makes GitHub refuse the merge.
gh pr merge "$pr" "--$method" --match-head-commit "$head"
echo "merged #$pr ($method)"
[ -z "$me" ] || state_set "$me" working "merged #$pr, waits for its CI and deploy"
echo "next: sh \"$here/main-ci.sh\" $pr --wait, in the background"
