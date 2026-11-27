#!/bin/sh
# The main checkout is one, and only one stack (sst dev and the like) runs on it: an agent that needs it to
# test takes it here, the others wait their turn.
#   checkout.sh take   puts the main checkout on your pushed branch (detached) and holds it for you. When
#                      another agent holds it you join the queue (exit 3): the plugin wakes you when it is free.
#   checkout.sh take --as-is   holds it the same way, without changing what is checked out there: to try what
#                      already runs in it (your change, merged, on a stack running on the default branch)
#   checkout.sh give   stop what you started there first: the checkout goes back to the default branch and
#                      the next in the queue is woken
#   checkout.sh who    who holds it (with as-is after its name when it took it as-is), since when, who waits
#   checkout.sh next   the dispatcher: when the checkout is free and someone waits, wakes the first of them
set -eu

action=${1:?take, give, who or next}
# take --as-is: hold the checkout as it is. Anything else after take is refused, so a mistyped option never
# moves the checkout.
as_is=""
if [ "$action" = take ] && [ $# -gt 1 ]; then
	[ "$2" = --as-is ] && [ $# -eq 2 ] || {
		echo "usage: checkout.sh take [--as-is]" >&2
		exit 2
	}
	as_is=1
fi
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
# A take of a branch fetches it, a give pulls the default branch, from the repository's remote: with none,
# they stop before the lock, the queue or the checkout change.
case "$action" in
take) [ -n "$as_is" ] || remote=$(repo_remote) || exit 1 ;;
give) remote=$(repo_remote) || exit 1 ;;
esac
lock="$repo_dir/checkout"
queue="$repo_dir/checkout.queue"
mutex="$repo_dir/checkout.mutex"
woken="$repo_dir/checkout.woken"
mkdir -p "$repo_dir"

# One script at a time reads and changes the lock and the queue. A mutex left by a killed run is dropped
# after two minutes.
n=0
until mkdir "$mutex" 2>/dev/null; do
	if [ -n "$(find "$mutex" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
		rmdir "$mutex" 2>/dev/null || true
		continue
	fi
	n=$((n + 1))
	[ "$n" -lt 120 ] || {
		echo "the checkout lock is busy, try again" >&2
		exit 1
	}
	sleep 1
done
trap 'rmdir "$mutex" 2>/dev/null || true' EXIT INT TERM
touch "$queue"

# usable <session-id>: not done, with a heartbeat from the last 10 minutes, so a session restarted (a
# plugin update, a resume) keeps its place in the checkout and in the queue.
usable() {
	[ -f "$sessions_dir/$1/status" ] || return 1
	[ "$(jq -r '.state // ""' "$sessions_dir/$1/status" 2>/dev/null)" != done ] || return 1
	t=$(cat "$sessions_dir/$1/alive" 2>/dev/null || true)
	case "$t" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - t)) -le 600 ]
}

# held_by <session-id>: the holder as comments name it, with as-is after its name when it took the checkout
# as it is (the lock's fourth line).
held_by() {
	printf '%s%s\n' "$(address_of "$1")" "$([ "$(sed -n 4p "$lock" 2>/dev/null)" != as-is ] || echo " as-is")"
}

# wake_next: drops from the queue who is gone or done, and wakes the first one left.
wake_next() {
	: >"$queue.tmp"
	while read -r waiting; do
		[ -n "$waiting" ] || continue
		usable "$waiting" && echo "$waiting" >>"$queue.tmp"
	done <"$queue"
	mv "$queue.tmp" "$queue"
	next=$(head -1 "$queue")
	[ -n "$next" ] || return 0
	printf '%s\tcheckout\tthe main checkout is free: take it now with checkout.sh take\t\n' "$(date +%s)" >>"$sessions_dir/$next/wake"
	printf '%s\n%s\n' "$next" "$(date +%s)" >"$woken"
}

holder=$(sed -n 1p "$lock" 2>/dev/null || true)
# A holder that is gone, or done, holds nothing any more: the next in the queue is woken.
if [ -n "$holder" ] && [ "$holder" != "$me" ] && ! usable "$holder"; then
	holder=""
	rm -f "$lock"
	wake_next
fi

case "$action" in
who)
	if [ -n "$holder" ]; then
		echo "held by $(held_by "$holder") since $(date -d "@$(sed -n 2p "$lock")" +%H:%M 2>/dev/null || sed -n 2p "$lock"), on $(sed -n 3p "$lock")"
	else
		echo "free, on $(git -C "$root" rev-parse --abbrev-ref HEAD)"
	fi
	while read -r waiting; do
		[ -n "$waiting" ] && echo "waiting: $(address_of "$waiting")"
	done <"$queue"
	;;
next)
	# Free with someone waiting: wake the first, again every 10 minutes while nobody takes it.
	[ -z "$holder" ] || exit 0
	[ -s "$queue" ] || exit 0
	at=$(sed -n 2p "$woken" 2>/dev/null || echo 0)
	case "$at" in "" | *[!0-9]*) at=0 ;; esac
	[ $(($(date +%s) - at)) -ge 600 ] || exit 0
	wake_next
	;;
take)
	[ -n "$me" ] || {
		echo "run it from an agent's session" >&2
		exit 2
	}
	if [ -n "$holder" ] && [ "$holder" != "$me" ]; then
		grep -qx "$me" "$queue" || echo "$me" >>"$queue"
		state_set "$me" others "queued for the checkout (held by $(held_by "$holder"))"
		echo "QUEUED: $(held_by "$holder") holds the checkout; you are in the queue and the plugin wakes you when it is yours"
		exit 3
	fi
	if [ -z "$as_is" ]; then
		branch=$(jq -r '.branch // ""' "$sessions_dir/$me/status")
		[ -n "$branch" ] || {
			echo "no branch recorded for this session" >&2
			exit 1
		}
	fi
	if [ "$holder" != "$me" ] && [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]; then
		echo "the main checkout has local changes: they are not yours, ask the tech lead (comment.sh <issue> \"tech lead\")" >&2
		exit 1
	fi
	if [ -z "$as_is" ]; then
		git -C "$root" fetch -q "$remote" "$branch"
		git -C "$root" switch -q --detach FETCH_HEAD
	else
		# As it is: what is checked out there stays, and the lock says so on its fourth line.
		branch=$(git -C "$root" rev-parse --abbrev-ref HEAD)
	fi
	tested=$(git -C "$root" rev-parse HEAD)
	{
		printf '%s\n%s\n%s\n' "$me" "$(date +%s)" "$branch"
		[ -z "$as_is" ] || echo as-is
	} >"$lock"
	grep -vx "$me" "$queue" >"$queue.tmp" || true
	mv "$queue.tmp" "$queue"
	# What QA passes or fails is the head tested here (qa.sh), not whatever the branch has by then.
	status_set "$me" --arg p checkout --arg h "$tested" '.place = $p | .tested_head = $h'
	state_set "$me" working "testing in the checkout"
	if [ -z "$as_is" ]; then
		echo "TAKEN: the main checkout $root is on $branch at $(git -C "$root" rev-parse --short HEAD), detached; test there, then checkout.sh give"
	else
		echo "TAKEN as-is: the main checkout $root stays on $branch at $(git -C "$root" rev-parse --short HEAD); test there, then checkout.sh give"
	fi
	;;
give)
	[ -n "$me" ] && [ "$holder" = "$me" ] || {
		echo "you do not hold the checkout" >&2
		exit 1
	}
	if [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]; then
		echo "the main checkout has local changes: commit and push them on your branch, or drop them, then give it back" >&2
		exit 1
	fi
	base=$(base_branch)
	git -C "$root" switch -q "$base"
	git -C "$root" pull -q --ff-only "$remote" "$base" || true
	rm -f "$lock"
	cwd=$(cat "$sessions_dir/$me/cwd" 2>/dev/null || true)
	if is_worktree "$cwd"; then
		status_set "$me" --arg p "worktree $(basename "$cwd" | cut -d- -f1)" '.place = $p'
	else
		status_set "$me" '.place = ""'
	fi
	state_set "$me" working "gave the checkout back"
	wake_next
	next=$(head -1 "$queue")
	echo "given back: the checkout is on $base${next:+, $(address_of "$next") is next}"
	;;
*)
	echo "usage: checkout.sh take [--as-is]|give|who|next" >&2
	exit 2
	;;
esac
