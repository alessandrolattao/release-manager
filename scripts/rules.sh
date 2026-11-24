#!/bin/sh
# The user's own rules for a repository: they are theirs, so they live on this machine and never in the
# repository or on GitHub. One file per repository, $team_data/rules/<owner>_<name>.md, one rule per line.
# One rule is also read by the scripts, written as "<key>: <value>":
#   merge: merge|rebase|squash|user    how pull requests land; "user" means the user merges them
#   rules.sh show [--context]   prints the rules (--context: framed for a session's context)
#   rules.sh add "<rule>"       adds one rule, with today's date
#   rules.sh remove "<words>"   removes the rules that contain these words
# Only the tech lead changes them, and only with what the user said.
set -eu

action=${1:?show, add or remove}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
mkdir -p "$(dirname "$rules_file")"
rules() { grep '^- ' "$rules_file" 2>/dev/null || true; }

case "$action" in
show)
	if [ "${2:-}" = --context ]; then
		if [ -z "$(rules)" ]; then
			echo "No rules of the user are recorded for this repository yet (rules.sh)."
		else
			echo "The user's own rules for this repository. They hold until the user changes them and win over any default of the plugin's skills:"
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
	printf -- '- %s (%s)\n' "$rule" "$(date +%F)" >>"$rules_file"
	echo "rule added to $rules_file"
	;;
remove)
	words=${2:?words of the rule to remove}
	gone=$(rules | grep -F -i -c -- "$words" || true)
	[ "${gone:-0}" -gt 0 ] || {
		echo "no rule contains '$words'" >&2
		exit 1
	}
	awk -v w="$(printf '%s' "$words" | tr '[:upper:]' '[:lower:]')" '!(/^- / && index(tolower($0), w) > 0)' "$rules_file" >"$rules_file.tmp"
	mv "$rules_file.tmp" "$rules_file"
	echo "$gone rule(s) removed"
	;;
*)
	echo "usage: rules.sh show [--context] | add \"<rule>\" | remove \"<words>\"" >&2
	exit 2
	;;
esac
