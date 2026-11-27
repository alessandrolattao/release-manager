---
name: update
description: "Updates the team plugin on this machine and moves the team onto the new version: the plugin on every Claude Code account the team uses here, then every running dispatcher; every live team session then reloads it in place, and one too old to reload by itself restarts on it once it is quiet; one already on it is left as it is. Use after a new version of the plugin is published, on each machine."
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/update.sh" start`

Tell the user, in one line, what the line above says. There is nothing else to do: the update goes on by itself, and this session reloads the new version too, between turns, unless it already runs it.
