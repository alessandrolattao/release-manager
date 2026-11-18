#!/bin/sh
# The pull requests in [ready], waiting for the user to test or merge them.
#   ready-sweep.sh                looks at each one: merged, its agent moves to [done]; closed, it is forgotten
#   ready-sweep.sh --tested <pr>  the user tested it: it leaves the planner's 🙋, the tag waits for the merge
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
waiting="$counters_dir/waiting"

if [ "${1:-}" = --tested ]; then
	pr=${2:?pull request number}
	[ -f "$waiting/ready-$pr" ] || {
		echo "pull request $pr is not waiting for the user" >&2
		exit 1
	}
	touch "$waiting/ready-$pr.tested"
	sh "$here/sync-names.sh" planner >/dev/null 2>&1 || true
	exit 0
fi

changed=no
for record in "$waiting"/ready-*; do
	[ -f "$record" ] || continue
	case "$record" in *.called | *.tested) continue ;; esac
	pr=${record##*ready-}
	state=$(gh pr view "$pr" --json state --jq .state 2>/dev/null || true)
	case "$state" in
	MERGED) sh "$here/set-state.sh" "$(sed -n 3p "$record")" "done" >/dev/null 2>&1 || true ;;
	CLOSED) ;;
	*) continue ;;
	esac
	rm -f "$record" "$record.called" "$record.tested"
	changed=yes
done
if [ "$changed" = yes ]; then
	sh "$here/sync-names.sh" planner >/dev/null 2>&1 || true
fi
