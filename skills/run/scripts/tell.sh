#!/bin/sh
# Leaves a message in the inbox of a planner or a release manager, instead of interrupting it:
# it reads its inbox when its current topic is over. The message is a file, written atomically
# (Maildir: tmp/ then new/), and the receiver's 📨 counter goes up.
#   tell.sh <planner|manager> <question|unblocked|info> [--to-repo owner/name] [--from "<sender>"] [--recorded] <<'EOF'
#   the message
#   EOF
# Without --to-repo the receiver is this repository's; with it, another repository's (planner to planner).
# --from names the sender when it is not a role session, such as a Pulse check ("Pulse · monthly audit").
# A question for the planner counts in its 🙋 until it is read, and its first line is said out loud if it
# is still unread after 30 minutes (hooks/remind.sh). --recorded is for a caller that keeps its own record.
set -eu

to=${1:?planner or manager}
kind=${2:?question, unblocked or info}
shift 2
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
target=$repo_full
sender=""
recorded=no
while [ $# -gt 0 ]; do
	case "$1" in
	--recorded)
		recorded=yes
		shift
		;;
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

# Who is writing: this very session, never another one in the same folder (the release manager, the planner
# and the consultants all run in the main checkout). Its recorded role first, then its name.
# shellcheck source=skills/run/scripts/session-dir.sh
. "$here/session-dir.sh"
from="session"
me=${CLAUDE_CODE_SESSION_ID:-}
case "$(cat "$sessions_dir/$me/role" 2>/dev/null || true)" in
manager) from="release manager · $repo_short" ;;
planner) from="planner · $repo_short" ;;
*)
	name=$(claude agents --json 2>/dev/null | jq -r --arg s "$me" '[.[] | select(.sessionId == $s) | .name][0] // empty' 2>/dev/null || true)
	case "$name" in
	"planner"*) from="planner · $repo_short" ;;
	"release manager"*) from="release manager · $repo_short" ;;
	"[plan]"*) from="consultant · $repo_short" ;;
	"["*)
		branch=${name#* }
		from="agent of #${branch%%-*}"
		;;
	esac
	;;
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

# receiver_alive: true when a session with that role works on the target repository, on any account: its
# heartbeat (hooks/sessions.tsx, every minute) is at most 3 minutes old.
receiver_alive() {
	now=$(date +%s)
	wanted=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
	for folder in "$sessions_dir"/*/; do
		[ "$(cat "${folder}role" 2>/dev/null || true)" = "$to" ] || continue
		at=$(cat "${folder}alive" 2>/dev/null || true)
		case "$at" in "" | *[!0-9]*) continue ;; esac
		[ $((now - at)) -le 180 ] || continue
		dir=$(cat "${folder}cwd" 2>/dev/null || true)
		[ -d "$dir" ] || continue
		repo=$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '[:upper:]' '[:lower:]' || true)
		[ "$repo" != "$wanted" ] || return 0
	done
	return 1
}
if ! receiver_alive; then
	echo "NOT READ YET: no $to of $target is running, the message waits in its inbox until one starts. If it cannot wait, tell the user."
fi

if [ "$to" = planner ] && [ "$kind" = question ] && [ "$recorded" = no ]; then
	waiting="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager/$(printf '%s' "$target" | tr '/' '_')/waiting"
	mkdir -p "$waiting"
	printf '%s\n%s\n' "$(date +%s)" "$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -1)" >"$waiting/told-$file"
fi

# The receiver's 📨 counter: only for this repository, where the names are kept.
if [ "$target" = "$repo_full" ]; then
	sh "$here/sync-names.sh" "$to" >/dev/null 2>&1 || true
else
	other=$(claude agents --json 2>/dev/null | jq -r --arg p "$to" --arg r "${target#*/}" \
		'[.[] | select((.name // "") | startswith((if $p == "planner" then "planner · " else "release manager · " end) + $r))][0].cwd // empty' 2>/dev/null || true)
	[ -n "$other" ] && (cd "$other" && sh "$here/sync-names.sh" "$to" >/dev/null 2>&1) || true
fi
