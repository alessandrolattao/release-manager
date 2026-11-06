#!/bin/sh
# Keeps the planner a planner, without relying on the model: in a session whose name starts with
# "planner", PreToolUse refuses anything that develops. The planner creates and prepares issues
# (text, comments, labels, fields, relationships); building them is the release manager's agents' job.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"

role_is "planner" is-planner || exit 0

tool=$(field tool_name)
deny() {
	jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: ("The planner creates and prepares issues, it never develops: " + $r
		+ ". Put what you were about to do in an issue for the release manager.")}}'
	exit 0
}

case "$tool" in
Edit | Write | MultiEdit | NotebookEdit)
	# Notes, memory and temporary files are fine; the repository and its worktrees are not.
	file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
	[ -n "$file" ] || exit 0
	file=$(realpath -m "$file" 2>/dev/null || printf '%s' "$file")
	for tree in $(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'); do
		tree=$(realpath -m "$tree" 2>/dev/null || printf '%s' "$tree")
		case "$file" in
		"$tree" | "$tree"/*) deny "no file of the repository is edited from the planner (notes go in ~/.local/share/release-manager/notes/)" ;;
		esac
	done
	exit 0
	;;
Bash) ;;
*) exit 0 ;;
esac

command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# Only this repository's issues: no gh on another one, no search across them; another repository
# may be read with git (for ports), never changed.
repo_cache="$state_dir/$sid.repo"
if [ ! -f "$repo_cache" ]; then
	url=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
	top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
	own=$(printf '%s' "$url" | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '[:upper:]' '[:lower:]')
	[ -n "$own" ] && [ -n "$top" ] && printf '%s\n%s\n' "$own" "$top" >"$repo_cache"
fi
if [ -f "$repo_cache" ]; then
	own=$(sed -n 1p "$repo_cache")
	top=$(sed -n 2p "$repo_cache")
	if ! why=$(printf '%s' "$command" | python3 -I "${CLAUDE_PLUGIN_ROOT}/hooks/own-repo.py" "$own" "$top" "$cwd"); then
		jq -n --arg r "$why" --arg own "$own" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
			permissionDecisionReason: ("The planner works only on its own repository, " + $own + ": " + $r
			+ ". Anything about another repository goes to that repository'"'"'s planner, as a message in its inbox (tell.sh planner <kind> --to-repo <owner/name>), or to the user.")}}'
		exit 0
	fi
fi
if printf '%s' "$command" | grep -q -E \
	'git[[:space:]]+(commit|push|merge|rebase|cherry-pick|revert|am|apply|stash|restore|reset|checkout[[:space:]]+-b|switch[[:space:]]+(-c|--create)|branch[[:space:]]+[^-[:space:]]|worktree[[:space:]]+add)|gh[[:space:]]+pr[[:space:]]+(create|merge|edit|close|review)|gh[[:space:]]+issue[[:space:]]+develop|claude[[:space:]]+(--bg|-p)|(^|[;&|[:space:]])(sed|perl)[[:space:]]+-i'; then
	deny "this command changes code, branches or pull requests"
fi
exit 0
