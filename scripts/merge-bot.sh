#!/bin/sh
# The tech lead merges a dependency bot's pull request, when the user asks for it, once everything holds for its
# current head:
#   - its author is a known dependency bot: dependabot[bot] or renovate[bot];
#   - it is open, not a draft, and mergeable;
#   - every check of the pull request is green.
# Anything else is refused with the reason.
# The method is the one merge.sh picks: the one the repository's own instructions ask for (--rebase, --squash);
# without one, a merge commit when the repository allows it, else the method it allows.
#   merge-bot.sh <pr> [--merge|--rebase|--squash]
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
refuse() {
	echo "NOT MERGED: $1" >&2
	exit 1
}

method=$(merge_method "${2:-}") || {
	echo "usage: merge-bot.sh <pr> [--merge|--rebase|--squash]" >&2
	exit 2
}

# The REST API names a bot by its login, dependabot[bot]; gh pr view would call it app/dependabot.
info=$(gh api "repos/$repo_full/pulls/$pr" 2>/dev/null) || refuse "could not read #$pr: try again"
author=$(printf '%s' "$info" | jq -r '.user.login // empty')
case "$author" in
"dependabot[bot]" | "renovate[bot]") ;;
*) refuse "#$pr is by ${author:-nobody known}, not by a dependency bot (dependabot[bot], renovate[bot])" ;;
esac
[ "$(printf '%s' "$info" | jq -r .state)" = open ] || refuse "#$pr is not open"
[ "$(printf '%s' "$info" | jq -r .draft)" = false ] || refuse "#$pr is a draft"
# GitHub works out whether it is mergeable in the background: null until it knows.
case "$(printf '%s' "$info" | jq -r .mergeable)" in
true) ;;
false) refuse "#$pr is not mergeable: it conflicts with the default branch" ;;
*) refuse "GitHub does not know yet whether #$pr is mergeable: try again in a minute" ;;
esac
head=$(printf '%s' "$info" | jq -r .head.sha)
bad=$(checks_not_green "$pr") || refuse "could not read the checks of #$pr: ${bad:-no answer}"
[ -z "$bad" ] || refuse "checks not green: $bad"

# Only the head that was read and checked: a push in between makes GitHub refuse the merge.
gh pr merge "$pr" "--$method" --match-head-commit "$head"
echo "merged #$pr ($method)"
