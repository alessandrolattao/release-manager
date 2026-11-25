"""Whether a GitHub Actions workflow runs on a push, for main-ci.sh: reads the workflow file on stdin and prints
"no" when its top-level on: surely has no push trigger, "push" otherwise: a push trigger, whatever its branch,
tag and path filters (they are not interpreted), or a file it cannot read, so that main-ci.sh says NO CI only
when it knows there is none. Standard library only: the plugin needs python3, not PyYAML.
    python3 -I push-trigger.py < workflow.yml
It reads on: in its three forms, on its own line or under it: a name (on: push), a list (on: [push,
pull_request], or one item per line) and a map (on: with a push: key under it). An event it cannot read as a
name (an alias, a tag, a nested list) it cannot tell, so push.
"""

import re
import sys

ON = re.compile(r"""^(?:on|"on"|'on')[ \t]*:(?:[ \t]+(.*))?$""")
EVENT = re.compile(r"[a-z_]+")


def bare(text):
    """The text without its comment and its quotes."""
    text = re.sub(r"(^|\s)#.*$", "", text).strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        text = text[1:-1]
    return text


def answer(push):
    print("push" if push else "no")
    sys.exit(0)


def flow(text, nxt):
    """A list or a map in brackets, starting with text, over the next lines up to its closing bracket: whether
    push is in it."""
    close = "]" if text[0] == "[" else "}"
    while text.count(text[0]) > text.count(close) and nxt < len(lines):
        text += " " + bare(lines[nxt])
        nxt += 1
    return re.search(r"\bpush\b", text) is not None


def events_push(events):
    """Whether these events, read as names, hold push or one it cannot tell."""
    return not events or any(event == "push" or not EVENT.fullmatch(event) for event in events)


lines = sys.stdin.read().splitlines()
for at, line in enumerate(lines):
    found = ON.match(line.rstrip())
    if not found:
        continue
    value = bare(found.group(1) or "")
    if value[:1] in ("[", "{"):
        answer(flow(value, at + 1))
    if value:
        answer(events_push([value]))
    # Under on:: a list or a map in brackets, or the keys and the list items at its first indentation.
    indent, events = None, []
    for nxt in range(at + 1, len(lines)):
        child = lines[nxt]
        item = bare(child)
        if not item:
            continue
        if not child[:1].isspace() and not child.startswith("-"):
            break
        depth = len(child) - len(child.lstrip())
        if indent is None:
            indent = depth
            if item[:1] in ("[", "{"):
                answer(flow(item, nxt + 1))
        if depth != indent:
            continue
        events.append(bare(item[1:]) if item.startswith("-") else bare(item.split(":", 1)[0]))
    answer(events_push(events))
answer(True)
