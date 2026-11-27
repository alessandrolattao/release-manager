#!/bin/sh
# Ends this session's work: its state becomes done (no color) and the plugin removes the session soon after,
# with its worktree. The conversation stays: `claude --resume` finds it.
# A developer whose pull request merged tells the tech lead first, "merged as #<pr>" (comment.sh --fyi): the
# plugin wakes the tech lead with it, as with any comment written to it.
#   done.sh "<how it ended, one line>"
set -eu

detail=${1:?how it ended}
me=${CLAUDE_CODE_SESSION_ID:?run it from the session}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
for lock in "$team_state"/repos/*/checkout; do
	[ -f "$lock" ] || continue
	[ "$(sed -n 1p "$lock")" != "$me" ] || {
		echo "you still hold the main checkout: checkout.sh give first" >&2
		exit 1
	}
done
# A QA agent ends only with its outcome recorded, or its developer would wait on it forever.
if [ "$(jq -r '.role // ""' "$sessions_dir/$me/status" 2>/dev/null)" = qa ]; then
	issue=$(jq -r '.issue // ""' "$sessions_dir/$me/status")
	repo=$(jq -r '.repo // ""' "$sessions_dir/$me/status" | tr '/' '_')
	case "$(cut -f1 "$team_state/repos/$repo/qa/$issue" 2>/dev/null)" in
	pass | fail) ;;
	*)
		echo "record the outcome first: qa.sh pass $issue or qa.sh fail $issue" >&2
		exit 1
		;;
	esac
fi
if [ "$(jq -r '.role // ""' "$sessions_dir/$me/status" 2>/dev/null)" = dev ]; then
	issue=$(jq -r '.issue // ""' "$sessions_dir/$me/status")
	branch=$(jq -r '.branch // ""' "$sessions_dir/$me/status")
	pr=""
	[ -z "$branch" ] || pr=$(gh pr list --head "$branch" --state merged --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null || true)
	if [ -n "$issue" ] && [ -n "$pr" ]; then
		echo "merged as #$pr" | sh "$here/comment.sh" "$issue" "tech lead" --fyi >/dev/null ||
			echo "could not tell the tech lead that #$pr merged: tell it with comment.sh $issue \"tech lead\" --fyi" >&2
	fi
fi
state_set "$me" done "$(printf '%s' "$detail" | tr '\n' ' ')"
echo "done: this session goes away in a few minutes"
