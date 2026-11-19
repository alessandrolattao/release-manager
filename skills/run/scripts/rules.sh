#!/bin/sh
# The user's standing rules for this repository, the ones that hold from now on for its release manager,
# planner and developer agents ("up to 3 agents at once", "the PR opens when the work is ready"). They live
# in one pinned issue, "Release manager rules" with the label `release-manager-rules`, assigned to nobody,
# so no queue or counter takes it. A message never carries a rule.
#   rules.sh show [--context]   prints the rules, one per line (--context: framed for a session's context)
#   rules.sh add "<rule>"       adds one rule with today's date; creates and pins the issue the first time
#   rules.sh remove "<words>"   removes the rules that contain these words
# Only the planner changes them, and only with what the user said.
set -eu

action=${1:?show, add or remove}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
label=release-manager-rules
cache="$counters_dir/rules.md"
header="Standing rules the user gave for this repository. The release manager, the planner and the developer agents follow them until the user changes them, through the planner. One rule per line."

# The issue's number and body, through the REST list (a label search could lag behind a fresh issue).
number=$(gh api "repos/$repo_full/issues?labels=$label&state=open&per_page=1" --jq '.[0].number // empty' 2>/dev/null || true)
body=""
[ -z "$number" ] || body=$(gh issue view "$number" --json body --jq .body 2>/dev/null || true)
rules() { printf '%s\n' "$body" | grep '^- ' || true; }

case "$action" in
show)
	if [ -n "$number" ]; then
		mkdir -p "$counters_dir"
		{ echo "$number"; rules; } >"$cache"
	elif [ -f "$cache" ] && ! gh api user --jq .login >/dev/null 2>&1; then
		# GitHub out of reach: the last copy seen.
		number=$(sed -n 1p "$cache")
		body=$(sed -n '2,$p' "$cache")
	fi
	if [ "${2:-}" = --context ]; then
		if [ -z "$(rules)" ]; then
			echo "No standing rules of the user are recorded for this repository yet (rules.sh)."
		else
			echo "The user's standing rules for this repository (issue #$number). They hold until the user changes them and win over any default of the skills:"
			rules
		fi
	else
		rules
	fi
	;;
add)
	rule=${2:?the rule, one line}
	case "$rule" in *"
"*)
		echo "a rule is one line" >&2
		exit 2
		;;
	esac
	if [ -z "$number" ]; then
		gh label list --limit 200 --json name --jq '.[].name' | grep -qx "$label" ||
			gh label create "$label" --description "The user's standing rules for the release manager, the planner and the agents" >/dev/null
		url=$(gh issue create --title "Release manager rules" --label "$label" --body "$header")
		number=${url##*/}
		gh issue pin "$number" >/dev/null 2>&1 || true
		body=$header
	fi
	printf '%s\n\n- %s (%s)\n' "$(printf '%s\n' "$body" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" "$rule" "$(date +%F)" |
		gh issue edit "$number" --body-file - >/dev/null
	echo "rule added to issue #$number"
	sh "$0" show >/dev/null 2>&1 || true
	;;
remove)
	words=${2:?words of the rule to remove}
	[ -n "$number" ] || {
		echo "no rules issue in $repo_full" >&2
		exit 1
	}
	gone=$(rules | grep -F -i -c -- "$words" || true)
	[ "${gone:-0}" -gt 0 ] || {
		echo "no rule contains '$words'" >&2
		exit 1
	}
	printf '%s\n' "$body" | awk -v w="$(printf '%s' "$words" | tr '[:upper:]' '[:lower:]')" \
		'!(/^- / && index(tolower($0), w) > 0)' | gh issue edit "$number" --body-file - >/dev/null
	echo "$gone rule(s) removed from issue #$number"
	sh "$0" show >/dev/null 2>&1 || true
	;;
*)
	echo "usage: rules.sh show [--context] | add \"<rule>\" | remove \"<words>\"" >&2
	exit 2
	;;
esac
