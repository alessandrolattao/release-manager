#!/bin/sh
# The developer merges its own pull request, once everything holds for its current head:
#   - the decision review passed (review.sh);
#   - the QA passed, when the issue carries the label qa (qa.sh);
#   - every check of the pull request is green.
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

case "${2:-}" in
--merge | --rebase | --squash) method=${2#--} ;;
"")
	allowed=$(gh api "repos/$repo_full" --jq '[if .allow_merge_commit then "merge" else empty end,
		if .allow_rebase_merge then "rebase" else empty end, if .allow_squash_merge then "squash" else empty end] | join(" ")' 2>/dev/null || true)
	case " $allowed " in
	*" merge "* | "  ") method=merge ;;
	*) method=${allowed%% *} ;;
	esac
	;;
*)
	echo "usage: merge.sh <pr> [--merge|--rebase|--squash]" >&2
	exit 2
	;;
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
	refuse "#$pr conflicts with the default branch: bring it into your branch the way the repository's instructions say (a merge when they say nothing, a rebase with a force push of your own branch only where they ask for it), push, and start over"
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

# Only the head that was reviewed and checked: a push in between makes GitHub refuse the merge.
gh pr merge "$pr" "--$method" --match-head-commit "$head"
echo "merged #$pr ($method)"
[ -z "$me" ] || state_set "$me" working "merged #$pr, waits for its CI and deploy"
echo "next: sh \"$here/main-ci.sh\" $pr --wait, in the background"
