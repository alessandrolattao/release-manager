#!/bin/sh
# The main checkout is one, and only one stack (sst dev and the like) runs on it: an agent that needs it to
# test takes it here, the others wait their turn.
#   checkout.sh take   puts the main checkout on your pushed branch (detached) and holds it for you. When
#                      another agent holds it you join the queue (exit 3): the plugin wakes you when it is free.
#   checkout.sh give   stop what you started there first: the checkout goes back to the default branch and
#                      the next in the queue is woken
#   checkout.sh who    who holds it, since when, who waits
set -eu

action=${1:?take, give or who}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
lock="$repo_dir/checkout"
queue="$repo_dir/checkout.queue"
touch "$queue"
holder=$(sed -n 1p "$lock" 2>/dev/null || true)

# A holder that is gone, or done, holds nothing any more.
if [ -n "$holder" ] && [ "$holder" != "$me" ]; then
	held_state=$(jq -r '.state // ""' "$sessions_dir/$holder/status" 2>/dev/null || true)
	if ! alive "$holder" || [ "$held_state" = done ]; then
		holder=""
		rm -f "$lock"
	fi
fi

case "$action" in
who)
	if [ -n "$holder" ]; then
		echo "held by $(address_of "$holder") since $(date -d "@$(sed -n 2p "$lock")" +%H:%M 2>/dev/null || sed -n 2p "$lock"), on $(sed -n 3p "$lock")"
	else
		echo "free, on $(git -C "$root" rev-parse --abbrev-ref HEAD)"
	fi
	while read -r waiting; do
		[ -n "$waiting" ] && echo "waiting: $(address_of "$waiting")"
	done <"$queue"
	;;
take)
	[ -n "$me" ] || {
		echo "run it from an agent's session" >&2
		exit 2
	}
	if [ -n "$holder" ] && [ "$holder" != "$me" ]; then
		grep -qx "$me" "$queue" || echo "$me" >>"$queue"
		state_set "$me" others "in coda per il checkout (lo tiene $(address_of "$holder"))"
		echo "QUEUED: $(address_of "$holder") holds the checkout; you are in the queue and the plugin wakes you when it is yours"
		exit 3
	fi
	branch=$(jq -r '.branch // ""' "$sessions_dir/$me/status")
	[ -n "$branch" ] || {
		echo "no branch recorded for this session" >&2
		exit 1
	}
	if [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]; then
		echo "the main checkout has local changes: they are the user's, ask them (comment.sh <issue> you)" >&2
		exit 1
	fi
	git -C "$root" fetch -q origin "$branch"
	git -C "$root" switch -q --detach FETCH_HEAD
	printf '%s\n%s\n%s\n' "$me" "$(date +%s)" "$branch" >"$lock"
	grep -vx "$me" "$queue" >"$queue.tmp" || true
	mv "$queue.tmp" "$queue"
	status_set "$me" --arg p checkout '.place = $p'
	state_set "$me" working "prova nel checkout"
	echo "TAKEN: the main checkout $root is on $branch at $(git -C "$root" rev-parse --short HEAD), detached; test there, then checkout.sh give"
	;;
give)
	[ -n "$me" ] && [ "$holder" = "$me" ] || {
		echo "you do not hold the checkout" >&2
		exit 1
	}
	base=$(base_branch)
	git -C "$root" switch -q "$base"
	git -C "$root" pull -q --ff-only origin "$base" || true
	rm -f "$lock"
	cwd=$(cat "$sessions_dir/$me/cwd" 2>/dev/null || true)
	case "$cwd" in
	"$root/.claude/worktrees/"*) status_set "$me" --arg p "worktree $(basename "$cwd" | cut -d- -f1)" '.place = $p' ;;
	*) status_set "$me" '.place = ""' ;;
	esac
	state_set "$me" working "ha liberato il checkout"
	next=$(head -1 "$queue")
	if [ -n "$next" ]; then
		printf '%s\tcheckout\tthe main checkout is free: take it now with checkout.sh take\t\n' "$(date +%s)" >>"$sessions_dir/$next/wake"
	fi
	echo "given back: the checkout is on $base${next:+, $(address_of "$next") is next}"
	;;
*)
	echo "usage: checkout.sh take|give|who" >&2
	exit 2
	;;
esac
