"""Types a slash command into a background Claude Code session, as the user would, and confirms it.

Only the user can type /color or /rename, so this opens `claude attach` in a pseudo-terminal,
types the command, detaches, and checks the session's transcript for the result.
    python3 -I ui.py <claude-binary> <session-id> color <color>
    python3 -I ui.py <claude-binary> <session-id> rename <name>
"""

import glob
import json
import os
import pty
import select
import signal
import sys
import time

claude, session, kind, value = sys.argv[1:5]
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") or k == "CLAUDE_CONFIG_DIR"}
env.update(TERM="xterm-256color", COLUMNS="160", LINES="40")

pid, fd = pty.fork()
if pid == 0:
    # `claude attach` takes the short id: the first 8 characters of the session id.
    os.execve(claude, ["claude", "attach", session[:8]], env)


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                os.read(fd, 65536)
            except OSError:
                return


pump(6)  # let the session view draw
for ch in f"/{kind} {value}":
    os.write(fd, ch.encode())
    time.sleep(0.03)
pump(1)
os.write(fd, b"\r")
pump(4)
os.kill(pid, signal.SIGTERM)
pump(0.5)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass

# Confirm from the transcript: the last value the session recorded is the one asked for.
entry, field = {"color": ("agent-color", "agentColor"), "rename": ("custom-title", "customTitle")}[kind]
config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
last = None
for path in glob.glob(os.path.join(config, "projects", "*", session + ".jsonl")):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if f'"{entry}"' in line:
                try:
                    last = json.loads(line).get(field)
                except ValueError:
                    pass
wanted = value
if kind == "color" and value == "default":
    ok = last in (None, "default")
else:
    ok = last == wanted
if ok:
    print(f"session {kind} set to {value}")
else:
    print(f"could not confirm {kind} {value} (last recorded: {last})", file=sys.stderr)
    sys.exit(1)
