#!/bin/sh
# Keeps a tech lead and its spikes what they are, without relying on the model: PreToolUse refuses what
# develops (files of the repository, commands that change code, branches or pull requests) and what reaches
# another repository but reading it. Developing is the developers' work; the tech lead prepares it.
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
case "$role" in
tech-lead) who="A tech lead prepares the work, it never develops" ;;
spike) who="A spike only reads and thinks, it never develops" ;;
*) exit 0 ;;
esac

deny() {
	jq -n --arg r "$1" --arg who "$who" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: ($who + ": " + $r + ". What has to be built goes in an issue for a developer.")}}'
	exit 0
}

case "$(field tool_name)" in
Edit | Write | MultiEdit | NotebookEdit)
	# Notes, memory and temporary files are fine; the repository and its worktrees are not.
	file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
	[ -n "$file" ] || exit 0
	file=$(realpath -m "$file" 2>/dev/null || printf '%s' "$file")
	for tree in $(git -C "$cwd" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'); do
		tree=$(realpath -m "$tree" 2>/dev/null || printf '%s' "$tree")
		case "$file" in
		"$tree" | "$tree"/*) deny "no file of the repository is edited from here (notes go in $team_data/notes/)" ;;
		esac
	done
	exit 0
	;;
Bash) ;;
*) exit 0 ;;
esac

command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
repo_cache="$state_dir/$sid.repo"
if [ ! -f "$repo_cache" ]; then
	url=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
	top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
	own=$(printf '%s' "$url" | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '[:upper:]' '[:lower:]')
	[ -n "$own" ] && [ -n "$top" ] && printf '%s\n%s\n' "$own" "$top" >"$repo_cache"
fi
[ -f "$repo_cache" ] || exit 0
own=$(sed -n 1p "$repo_cache")
top=$(sed -n 2p "$repo_cache")
if ! why=$(printf '%s' "$command" | python3 -I "${CLAUDE_PLUGIN_ROOT}/hooks/guard.py" "$role" "$own" "$top" "$cwd" "$CLAUDE_PLUGIN_ROOT"); then
	deny "$why"
fi
exit 0
