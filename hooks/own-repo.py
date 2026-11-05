"""Tells whether a shell command reaches outside the session's own repository.

Used by planner-guard.sh: prints a reason and exits 1 when the command points gh at another
repository (-R/--repo, gh api repos/..., github.com/... links), searches across repositories
(gh search), or moves into another repository (cd, git -C). Exits 0 when it stays home.
    python3 -I own-repo.py <owner/name> <repo root> <cwd>   (command on stdin)
"""

import os
import re
import shlex
import subprocess
import sys

own, root, cwd = sys.argv[1].lower(), os.path.realpath(sys.argv[2]), sys.argv[3]
command = sys.stdin.read()


def repo_of(ref):
    ref = ref.strip().lower().removesuffix(".git").rstrip("/")
    ref = re.sub(r"^(https?://|git@)?github\.com[:/]", "", ref)
    parts = [p for p in ref.split("/") if p]
    return "/".join(parts[:2]) if len(parts) >= 2 else None


def outside(reason):
    print(reason)
    sys.exit(1)


try:
    words = shlex.split(command, posix=True)
except ValueError:
    words = command.split()

if re.search(r"\bgh\s+search\b", command):
    outside("gh search looks across repositories")

for i, w in enumerate(words):
    value = None
    if w in ("-R", "--repo") and i + 1 < len(words):
        value = words[i + 1]
    elif w.startswith("--repo="):
        value = w.split("=", 1)[1]
    if value is not None and repo_of(value) not in (None, own):
        outside(f"it points gh at {value}")

for match in re.finditer(r"repos/([\w.-]+/[\w.-]+)", command):
    if match.group(1).lower() != own:
        outside(f"it calls the API of {match.group(1)}")
for match in re.finditer(r"github\.com[:/]([\w.-]+/[\w.-]+)", command):
    if repo_of(match.group(1)) != own:
        outside(f"it links {match.group(1)}")


def toplevel(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 else None


for i, w in enumerate(words):
    target = None
    if w == "cd" and i + 1 < len(words):
        target = words[i + 1]
    elif w == "-C" and i > 0 and words[i - 1] == "git" and i + 1 < len(words):
        target = words[i + 1]
    if not target or target.startswith("-"):
        continue
    path = os.path.realpath(os.path.join(cwd, os.path.expanduser(target)))
    top = toplevel(path)
    if top and top != root and not top.startswith(root + os.sep):
        outside(f"it moves into another repository ({top})")
sys.exit(0)
