---
name: update
description: "Updates the team plugin on this machine and moves the team onto the new version: the plugin on every Claude Code account the team uses here, then every running dispatcher, then every live team session restarted on it once it is quiet. Use after a new version of the plugin is published, on each machine."
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/update.sh" start`

Tell the user, in one line, what the line above says. There is nothing else to do: the update goes on by itself and restarts this session too, once it is quiet.
