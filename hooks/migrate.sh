#!/bin/sh
# SessionStart, once: moves what the plugin kept under its old name (release-manager) to the team's folders.
# Planners become tech leads; release managers are gone from the team, so their folders are dropped (no
# revive). Notes and spike reports move; the old inboxes stay where they were, for the record.
#   migrate.sh   (hook payload on stdin, unused)
set -eu

old_state="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager"
old_data="${XDG_DATA_HOME:-$HOME/.local/share}/release-manager"
# shellcheck source=scripts/session-dir.sh
. "${CLAUDE_PLUGIN_ROOT:?}/scripts/session-dir.sh"
[ -d "$old_state" ] || [ -d "$old_data" ] || exit 0
[ ! -e "$team_state/migrated" ] || exit 0
mkdir -p "$team_state" "$team_data"
mkdir "$team_state/migrate.lock" 2>/dev/null || exit 0
trap 'rmdir "$team_state/migrate.lock"' EXIT

for folder in "$old_state"/sessions/*/; do
	[ -d "$folder" ] || continue
	id=$(basename "$folder")
	case "$(cat "$folder/role" 2>/dev/null || true)" in
	planner)
		mkdir -p "$sessions_dir/$id"
		for f in cwd config alive; do [ ! -f "$folder$f" ] || cp "$folder$f" "$sessions_dir/$id/$f"; done
		echo tech-lead >"$sessions_dir/$id/role"
		;;
	esac
done
for repo in "$old_state"/*/; do
	[ -d "$repo" ] || continue
	key=$(basename "$repo")
	[ "$key" != sessions ] || continue
	mkdir -p "$team_state/repos/$key"
	[ ! -f "$repo/main-red" ] || cp "$repo/main-red" "$team_state/repos/$key/main-red"
done
[ ! -d "$old_data/notes" ] || cp -R "$old_data/notes" "$team_data/" 2>/dev/null || true
[ ! -d "$old_data/consults" ] || { mkdir -p "$team_data/spikes" && cp -R "$old_data/consults/." "$team_data/spikes/" 2>/dev/null || true; }
date +%s >"$team_state/migrated"
