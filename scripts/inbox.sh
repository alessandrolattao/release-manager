#!/bin/sh
# The messages other repositories left for this repository's tech leads (tell.sh).
#   inbox.sh list   the unread messages, one line each (kind, from, first line)
#   inbox.sh read   prints them in full, oldest first, and marks them read (new/ to cur/)
set -eu

action=${1:?list or read}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
box=$(inbox_dir "$repo_full")
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
		echo "usage: inbox.sh list|read" >&2
		exit 2
		;;
	esac
done
