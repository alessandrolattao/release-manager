"""Whether a GitHub Actions workflow runs on a push, for main-ci.sh: reads the workflow file on stdin and prints
"no" when its top-level on: surely has no push trigger, "push" otherwise: a push trigger, whatever its branch,
tag and path filters (they are not interpreted), or a file it cannot read, so that main-ci.sh says NO CI only
when it knows there is none. Standard library only: the plugin needs python3, not PyYAML.
    python3 -I push-trigger.py < workflow.yml
It reads on: in its three forms: a name (on: push), a list (on: [push, pull_request], or one item per line)
and a map (on: with a push: key under it).
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


lines = sys.stdin.read().splitlines()
for at, line in enumerate(lines):
    found = ON.match(line.rstrip())
    if not found:
        continue
    value = bare(found.group(1) or "")
    if value[:1] in ("[", "{"):
        # A list or a map on the same line, or over the next ones up to its closing bracket.
        close = "]" if value[0] == "[" else "}"
        text, nxt = value, at + 1
        while text.count(value[0]) > text.count(close) and nxt < len(lines):
            text += " " + bare(lines[nxt])
            nxt += 1
        answer(re.search(r"\bpush\b", text) is not None)
    if value:
        # One event by name; anything else (an alias, a tag) it cannot tell.
        answer(value == "push" or not EVENT.fullmatch(value))
    # A block under on:: its events are the keys or the list items at the first indentation under it.
    indent, events = None, []
    for child in lines[at + 1:]:
        if not bare(child):
            continue
        if not child[:1].isspace() and not child.startswith("-"):
            break
        depth = len(child) - len(child.lstrip())
        if indent is None:
            indent = depth
        if depth != indent:
            continue
        item = bare(child)
        if item.startswith("-"):
            events.append(bare(item[1:]))
        else:
            events.append(bare(item.split(":", 1)[0]))
    answer(not events or "push" in events)
answer(True)
