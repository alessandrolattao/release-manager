#!/bin/sh
# Sets the color of a background session, the one /color sets, from inside it or from anywhere else.
#   color.sh <session-id> <red|blue|green|yellow|purple|orange|pink|cyan|default>
# Only the user can type /color, so this attaches to the session in a pseudo-terminal, types the
# command as the user would, and detaches. Works for background sessions (claude --bg), which
# `claude attach` opens; the session keeps working while its color changes.
set -eu

id=${1:?session id}
color=${2:?color}
case "$color" in
red | blue | green | yellow | purple | orange | pink | cyan | default) ;;
*)
	echo "unknown color '$color': red, blue, green, yellow, purple, orange, pink, cyan or default" >&2
	exit 2
	;;
esac
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
claude=$(command -v claude) || {
	echo "claude not found" >&2
	exit 1
}

# `claude attach` takes the short id: the first 8 characters of the session id.
python3 -I - "$claude" "$(printf '%s' "$id" | cut -c1-8)" "$color" "$id" <<'EOF'
import os, pty, select, signal, sys, time

claude, target, color, session = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") or k == "CLAUDE_CONFIG_DIR"}
env.update(TERM="xterm-256color", COLUMNS="120", LINES="40")

pid, fd = pty.fork()
if pid == 0:
    os.execve(claude, ["claude", "attach", target], env)

out = b""
def pump(seconds, until=None):
    global out
    end = time.time() + seconds
    while time.time() < end:
        if until and until in out:
            return True
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return False
    return bool(until and until in out)

pump(6)  # let the session view draw
for ch in "/color " + color:
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

# Confirm from the session's transcript: the last color it recorded is the one asked for.
import glob, json
config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
last = None
for path in glob.glob(os.path.join(config, "projects", "*", session + ".jsonl")):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"agent-color"' in line:
                try:
                    last = json.loads(line).get("agentColor")
                except ValueError:
                    pass
wanted = None if color == "default" else color
if last == wanted or (wanted is None and last in (None, "default")):
    print(f"session color set to {color}")
else:
    print(f"could not confirm the color change to {color} (last recorded: {last})", file=sys.stderr)
    sys.exit(1)
EOF
