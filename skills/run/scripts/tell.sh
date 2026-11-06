#!/bin/sh
# Leaves a message in the inbox of a planner or a release manager, instead of interrupting it:
# it reads its inbox when its current topic is over. The message is a file, written atomically
# (Maildir: tmp/ then new/), and the receiver's 📨 counter goes up.
#   tell.sh <planner|manager> <question|unblocked|info> [--to-repo owner/name] [--from "<sender>"] <<'EOF'
#   the message
#   EOF
# Without --to-repo the receiver is this repository's; with it, another repository's (planner to planner).
# --from names the sender when it is not a role session, such as a Pulse check ("Pulse · monthly audit").
set -eu

to=${1:?planner or manager}
kind=${2:?question, unblocked or info}
shift 2
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
target=$repo_full
sender=""
while [ $# -gt 0 ]; do
	case "$1" in
	--to-repo)
		target=${2:?owner/name}
		shift 2
		;;
	--from)
		sender=${2:?sender}
		shift 2
		;;
	*)
		echo "unknown option '$1'" >&2
		exit 2
		;;
	esac
done
case "$to" in planner | manager) ;; *)
	echo "unknown receiver '$to': planner or manager" >&2
	exit 2
	;;
esac
case "$kind" in question | unblocked | info) ;; *)
	echo "unknown kind '$kind': question, unblocked or info" >&2
	exit 2
	;;
esac
body=$(cat)
[ -n "$body" ] || {
	echo "the message comes on stdin" >&2
	exit 2
}

# Who is writing: the role of this session, read from its name.
from="session"
name=$(claude agents --json 2>/dev/null | jq -r --arg c "$PWD" '[.[] | select(.cwd == $c) | .name][0] // empty' 2>/dev/null || true)
case "$name" in
"planner"*) from="planner · $repo_short" ;;
"release manager"*) from="release manager · $repo_short" ;;
esac
[ -n "$sender" ] && from=$sender

box=$(inbox_dir "$to" "$target")
mkdir -p "$box/tmp" "$box/new" "$box/cur"
file="$(date +%Y%m%dT%H%M%S)-$$-$kind.md"
{
	printf 'From: %s\nKind: %s\nDate: %s\n\n' "$from" "$kind" "$(date '+%Y-%m-%d %H:%M')"
	printf '%s\n' "$body"
} >"$box/tmp/$file"
mv "$box/tmp/$file" "$box/new/$file"
echo "message left for the $to of $target ($kind)"

# The receiver's 📨 counter: only for this repository, where the names are kept.
if [ "$target" = "$repo_full" ]; then
	sh "$here/sync-names.sh" "$to" >/dev/null 2>&1 || true
else
	other=$(claude agents --json 2>/dev/null | jq -r --arg p "$to" --arg r "${target#*/}" \
		'[.[] | select((.name // "") | startswith((if $p == "planner" then "planner · " else "release manager · " end) + $r))][0].cwd // empty' 2>/dev/null || true)
	[ -n "$other" ] && (cd "$other" && sh "$here/sync-names.sh" "$to" >/dev/null 2>&1) || true
fi
