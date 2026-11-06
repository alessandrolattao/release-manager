#!/bin/sh
# Lists or reads the inbox of this repository's planner or release manager.
#   inbox.sh list <planner|manager>   the unread messages, one line each (kind, from, first line)
#   inbox.sh read <planner|manager>   prints them in full, oldest first, and marks them read (new/ to cur/)
set -eu

action=${1:?list or read}
role=${2:?planner or manager}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
box=$(inbox_dir "$role")
mkdir -p "$box/new" "$box/cur"
files=$(find "$box/new" -type f 2>/dev/null | sort)
if [ -z "$files" ]; then
	echo "no new messages"
	exit 0
fi
for f in $files; do
	kind=$(sed -n 's/^Kind: //p' "$f" | head -1)
	from=$(sed -n 's/^From: //p' "$f" | head -1)
	case "$action" in
	list) printf '%s · %s · %s\n' "$kind" "$from" "$(sed -n '5p' "$f" | cut -c1-100)" ;;
	read)
		printf '=== %s · %s\n' "$kind" "$from"
		sed -n '5,$p' "$f"
		mv "$f" "$box/cur/"
		;;
	*)
		echo "usage: inbox.sh list|read planner|manager" >&2
		exit 2
		;;
	esac
done
[ "$action" = read ] && sh "$here/sync-names.sh" "$role" >/dev/null 2>&1 || true
