---
name: dispatcher
description: "Starts, stops or shows the team's dispatcher for the repository you are in, on this machine: the process that starts developers on ready issues, wakes the sessions with the comments written to them and keeps the board's summary. It runs only when started by hand, and goes on after this session ends. Use on a machine that should work on this repository, from its checkout."
argument-hint: "[start|stop|status]"
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/scripts/dispatcher.sh" "$ARGUMENTS"`

Tell the user, in one line, what the line above says. There is nothing else to do: the dispatcher runs on its own, also after this session ends, until it is stopped or the machine restarts.
