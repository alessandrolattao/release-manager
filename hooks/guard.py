"""Keeps a tech lead and its spikes from developing, judging the command alone, without the model.

Only the commands the shell would run count: the words of a quoted string or of a here-document never do,
so a comment or a rule that talks about "git push" passes. The plugin's own scripts always pass, except the
ones a spike may not run.
Refused:
  - a command that changes code, branches or pull requests (git commit, push, merge, rebase, ...; gh pr
    create, merge, ...; claude --bg or -p; sed -i or perl -i on a file of the repository);
  - anything aimed at another repository but reading it with git (gh -R, gh search, links to it, writing or
    building inside it, its API: any repos/<other>/... in what the shell runs, whatever the method, but after a
    folder (a local path), inside a quoted string after other text, or in a comment; a local path that holds
    github.com/... is no link);
  - for a spike: moving the main checkout (git checkout, switch, pull) and starting agents.
A string that becomes code is judged as a command of its own: sh -c and bash -lc, eval, ssh's remote command,
what echo, printf or cat <<< prints into a shell (a pipe, a <(...)), a shell's <<< string, what source or .
reads from a <(...). A here-document is data, also into a shell.
Prints the reason and exits 1 when refused, exits 0 otherwise.
    python3 -I guard.py <role> <owner/name> <repo root> <cwd> <plugin root>   (command on stdin)
"""

import os
import re
import shlex
import subprocess
import sys

role, own, root, cwd, plugin = sys.argv[1], sys.argv[2].lower(), os.path.realpath(sys.argv[3]), sys.argv[4], os.path.realpath(sys.argv[5])
command = sys.stdin.read()

WRITE_GIT = {"commit", "push", "merge", "rebase", "cherry-pick", "revert", "am", "apply", "stash", "restore", "reset"}
READ_GIT = {"log", "show", "diff", "grep", "ls-files", "ls-tree", "blame", "branch", "fetch", "status", "rev-parse",
            "rev-list", "cat-file", "describe", "shortlog", "remote", "config", "worktree", "tag", "merge-base"}
BUILD = {"rm", "mv", "cp", "touch", "mkdir", "rmdir", "tee", "chmod", "chown", "ln", "install", "truncate", "npm", "npx",
         "bun", "bunx", "yarn", "pnpm", "go", "make", "cargo", "pip", "uv", "docker", "sst", "terraform", "cdk", "patch"}
SPIKE_FORBIDDEN_SCRIPTS = {"spike.sh", "start-dev.sh", "start-qa.sh", "merge.sh", "checkout.sh"}
# The API of a repository: repos/<owner>/<name>, refused by default wherever the shell runs it (gh api, curl,
# wget, a variable, a function, data piped into xargs: all alike). GraphQL names no repository: it is not judged.
REPOS = re.compile(r"repos/([\w.-]+/[\w.-]+)")
# What may come before repos/ in its word in an API call: nothing, slashes, or the API's host (any case, any
# scheme or user before it, a port).
ENDPOINT_PREFIX = re.compile(r"(?:\S*(?i:api\.github\.com)(?::\d+)?)?/*")
# The option that gives a shell its command: -c, alone or in a cluster (bash -lc, sh -ec).
SHELLS = ("sh", "bash", "zsh", "dash")
SHELL_COMMAND = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
# The commands that run a string as code, and ssh's options that take a value.
CODE_RUNNERS = SHELLS + ("eval", "source", ".", "ssh")
SSH_VALUE_FLAGS = set("bcDEeFIiJLlmOopQRSWw")
# A link to GitHub is a URL or an ssh remote (https://github.com/..., git@github.com:..., github.com/... as a
# word, any subdomain), never a folder of a local path (~/go/pkg/mod/github.com/...); api.github.com is the
# API rule's.
LINK = re.compile(r"(?:(?<=://)|(?<=@)|(?<![\w./-]))(?!(?i:api)\.)(?:[\w-]+\.)*github\.com[:/]([\w.-]+/[\w.-]+)")


def refuse(reason):
    print(reason)
    sys.exit(1)


def repo_of(ref):
    ref = ref.strip().lower().removesuffix(".git").rstrip("/")
    ref = re.sub(r"^(https?://|git@)?github\.com[:/]", "", ref)
    parts = [p for p in ref.split("/") if p]
    return "/".join(parts[:2]) if len(parts) >= 2 else None


def toplevel(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 else None


def inside_repo(path):
    real = os.path.realpath(os.path.join(cwd, os.path.expanduser(path)))
    return real == root or real.startswith(root + os.sep)


def commands_of(text):
    """The commands of a shell text, each as its words and the separator before it (';', '|', '&&', ...): the
    words of a quoted string stay one word. A comment starts only where a word does, as in the shell (shlex
    would also start one inside a word: a#b)."""
    try:
        lexer = shlex.shlex(scan(text)[0], posix=True, punctuation_chars=";&|()<>")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError:
        tokens = text.split()
    commands, current, separator = [], [], ""
    for token in tokens:
        if token and set(token) <= set(";&|()"):
            if current:
                commands.append((current, separator))
                separator = ""
            current, separator = [], separator + token
        else:
            current.append(token)
    if current:
        commands.append((current, separator))
    return commands


def segments_of(text):
    """The commands of a shell text, each as its words."""
    return [words for words, _ in commands_of(text)]


def piped(separator):
    """Whether a command reads what the one before it prints: | or |&, not ||, also around a subshell's ( )."""
    tail = separator.rstrip("(")
    return tail.endswith(("|", "|&")) and not tail.endswith("||")


def printed(words):
    """What echo, printf or cat <<< prints into a pipe, near enough to read it as commands; None for any other
    command, or for one whose output the command does not show (a file, a here-document)."""
    words = bare(words)
    head = os.path.basename(words[0]) if words else ""
    if head == "cat":
        return words[words.index("<<<") + 1] if "<<<" in words[:-1] else None
    if head not in ("echo", "printf"):
        return None
    rest = words[1:]
    while rest and re.fullmatch(r"-[neE]+", rest[0]):
        rest = rest[1:]
    return " ".join(rest[1:] if rest[:1] == ["--"] else rest).replace("\\n", "\n")


def code_of(words, piped_from=None):
    """The text the first command in these words that runs a string as code runs: a shell's -c string (bash -lc
    too) or <<< string; what echo, printf or cat <<< prints into a shell, or into source or ., through a pipe or
    a <(...); eval's words; ssh's remote command. None when none of them runs one."""
    for i, word in enumerate(words):
        head, rest, code = os.path.basename(word), words[i + 1:], None
        if head == "eval":
            code = " ".join(rest)
        elif head == "ssh":
            code = remote_command(rest)
        elif head in CODE_RUNNERS:
            k = next((k for k, w in enumerate(rest)
                      if w in ("<<<", "<(") or (head in SHELLS and SHELL_COMMAND.fullmatch(w))), None)
            if k is None:
                code = printed(piped_from) if piped_from else None
            elif rest[k] == "<(":
                code = printed(rest[k + 1:])
            else:
                code = rest[k + 1] if k + 1 < len(rest) else ""
        if code is not None:
            return code
    return None


def remote_command(args):
    """ssh's remote command: the words after its options and its host, joined as ssh joins them; None when there
    is none."""
    j = 0
    while j < len(args) and args[j].startswith("-"):
        j += 2 if len(args[j]) == 2 and args[j][1] in SSH_VALUE_FLAGS else 1
    return " ".join(args[j + 1:]) if j + 1 < len(args) else None


def bare(words):
    """The words of a command without the assignments and wrappers before it (X=1, sudo, time, env, ...)."""
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "time", "env", "nohup", "exec")):
        words = words[1:]
    return words


def api_calls(text):
    """The repositories whose API a shell text may call: every repos/<owner>/<name> in what the shell runs (its
    commands, its substitutions, the strings it hands a shell), but after a folder, inside a quoted string after
    other text, or in a comment; a string that becomes code is read as code."""
    _, inners, plain, strings = scan(text)
    found = [repo for inner in inners for repo in api_calls(inner)]
    previous = None
    for words, separator in commands_of(text):
        inner = code_of(words, previous if piped(separator) else None)
        found += api_calls(inner) if inner is not None else []
        previous = words
    return found + [m.group(1) for m in REPOS.finditer(plain) if is_call(plain, m.start(), strings)]


def is_call(text, at, strings):
    """Whether the repos/ at this place of a shell text (its substitutions blanked as $) may be an API call:
    not after a folder (a local path, a URL to another host), not inside a quoted string after other text;
    unless what comes before it in its word is the API's host, slashes, or a variable or substitution that may
    stand for them (gh api "repos/...", "$API/repos/..."). strings holds where each quoted string's text starts
    and ends."""
    string = next((start for start, end in strings if start <= at < end), None)
    if string is not None:
        word = text[string:at]
        if re.search(r"\s", word):
            return False
    else:
        word = re.search(r"[^\s'\"=;&|()<>`]*$", text[:at]).group()
    if ENDPOINT_PREFIX.fullmatch(word) or "$" in word:
        return True
    return string is None and "/" not in word


def scan(text):
    """Reads a shell text as the shell does, near enough. Gives the text, as long as it was, with its comments
    blanked; the command texts of its substitutions; the text with its substitutions blanked too, as $; and
    where the text of each quoted string starts and ends. A substitution is $(...) or `...`, bare or double-quoted; inside
    single quotes or escaped (an odd number of backslashes) it is text. A comment starts where a word does (not
    in a#b, nor right after a substitution: $(x)#b) and ends with its line."""
    out, plain, inners, strings = list(text), list(text), [], []
    quote, opened, i, after = None, 0, 0, -1
    while i < len(text):
        c = text[i]
        if quote == "'" and c != "'":
            i += 1
        elif c == "\\" and quote != "'":
            i += 2
        elif c in "'\"" and quote in (None, c):
            if quote:
                strings.append((opened, i))
            quote, opened = (None, 0) if quote else (c, i + 1)
            i += 1
        elif c == "#" and quote is None and i != after and (i == 0 or text[i - 1] in " \t\n;&|()<>"):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            out[i:end] = plain[i:end] = " " * (end - i)
            i = end
        elif quote != "'" and (text.startswith("$(", i) or c == "`"):
            start = i + (2 if c == "$" else 1)
            end = closing(text, start) if c == "$" else closing_backtick(text, start)
            inners.append(text[start:end])
            plain[i:end + 1] = "$" * (min(end + 1, len(text)) - i)
            i = after = end + 1
        else:
            i += 1
    if quote:
        strings.append((opened, len(text)))
    return "".join(out), inners, "".join(plain), strings


def closing(text, i):
    """Where the ) that closes a $( is, from just after the $(: past nested parentheses and quoted ones; the end
    of the text when none closes it."""
    depth, quote = 1, None
    while i < len(text):
        c = text[i]
        if quote == "'":
            quote = None if c == "'" else quote
        elif c == "\\":
            i += 1
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c == "'" and quote is None:
            quote = "'"
        elif c in "()" and quote is None:
            depth += 1 if c == "(" else -1
            if depth == 0:
                return i
        i += 1
    return len(text)


def closing_backtick(text, i):
    """Where the backtick that closes a `...` is, from just after the opening one; the end of the text when none
    closes it."""
    while i < len(text) and text[i] != "`":
        i += 2 if text[i] == "\\" else 1
    return min(i, len(text))


# Here-documents are data: their bodies go before anything is parsed. A line ending in an odd number of
# backslashes goes on in the next one, as in the shell.
lines, skipping, goes_on = [], None, False
for line in command.split("\n"):
    if skipping is not None:
        if line.strip() == skipping:
            skipping = None
        continue
    if goes_on:
        lines[-1] = lines[-1][:-1] + line
    else:
        lines.append(line)
    # A backslash inside a comment continues nothing.
    logical = scan(lines[-1])[0]
    goes_on = (len(logical) - len(logical.rstrip("\\"))) % 2 == 1
    # `<<<word` is a here-string, on its own line: nothing after it is skipped.
    match = re.search(r"(?<!<)<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
    if match:
        skipping = match.group(1)
script = ";\n".join(lines)

commands = commands_of(script)
segments = [words for words, _ in commands]

if any(s[:2] == ["gh", "search"] for s in segments):
    refuse("gh search looks across repositories")
for repo in api_calls(script):
    if repo.lower() != own:
        refuse(f"it calls the API of {repo}")
for match in LINK.finditer(script):
    if repo_of(match.group(1)) not in (None, own):
        refuse(f"it links {match.group(1)}")

where = cwd
for n, (words, separator) in enumerate(commands):
    words = bare(words)
    if not words:
        continue
    head = os.path.basename(words[0])

    # The plugin's own scripts: they hold their own rules.
    target = words[1] if head in ("sh", "bash") and len(words) > 1 else words[0]
    real = os.path.realpath(os.path.join(where, os.path.expanduser(target)))
    if real.startswith(plugin + os.sep) and real.endswith(".sh"):
        if role == "spike" and os.path.basename(real) in SPIKE_FORBIDDEN_SCRIPTS:
            refuse(f"a spike only reads: it does not run {os.path.basename(real)}")
        continue

    # A string that becomes code (sh -c '...', echo '...' | sh, source <(...), eval '...', ssh host '...') is
    # checked as a command of its own.
    inner = code_of(words, commands[n - 1][0] if n and piped(separator) else None) if head in CODE_RUNNERS else None
    if inner is not None:
        nested = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]],
                                input=f"cd {shlex.quote(where)}\n{inner}", capture_output=True, text=True)
        if nested.returncode != 0:
            sys.stdout.write(nested.stdout)
            sys.stderr.write(nested.stderr)
            sys.exit(nested.returncode)
        continue

    if head == "cd" and len(words) > 1:
        where = os.path.realpath(os.path.join(where, os.path.expanduser(words[1])))
        continue

    for i, w in enumerate(words):
        value = None
        if w in ("-R", "--repo") and i + 1 < len(words):
            value = words[i + 1]
        elif w.startswith("--repo="):
            value = w.split("=", 1)[1]
        if value is not None and repo_of(value) not in (None, own):
            refuse(f"it points gh at {value}")

    top = toplevel(where)
    other = top if top and top != root and not top.startswith(root + os.sep) else None

    if head == "git":
        j, gitdir = 1, where
        while j < len(words) and words[j].startswith("-"):
            if words[j] == "-C" and j + 1 < len(words):
                gitdir = os.path.realpath(os.path.join(where, os.path.expanduser(words[j + 1])))
                j += 2
            elif words[j] == "-c":
                j += 2
            else:
                j += 1
        sub = words[j] if j < len(words) else ""
        rest = words[j + 1:]
        gtop = toplevel(gitdir)
        elsewhere = gtop if gtop and gtop != root and not gtop.startswith(root + os.sep) else None
        if elsewhere:
            if sub in ("switch", "checkout", "restore", "pull"):
                refuse(f"it moves another repository ({elsewhere}); read another branch with git -C <repo> show <branch>:<file>")
            # git symbolic-ref <ref> only prints where the ref points; with a target or --delete it changes it.
            options = [a for a in rest if a.startswith("-")]
            reads_ref = sub == "symbolic-ref" and set(options) <= {"--short", "-q", "--quiet"} and len(rest) - len(options) == 1
            if sub not in READ_GIT and not reads_ref:
                refuse(f"git {sub} changes another repository ({elsewhere}); there you may only read")
            continue
        creates_branch = sub == "branch" and any(not a.startswith("-") for a in rest) and not any(
            a in ("-a", "-r", "--list", "--all", "--remotes", "--contains", "--merged", "--no-merged", "-v", "-vv") for a in rest)
        if (sub in WRITE_GIT or creates_branch
                or (sub == "checkout" and "-b" in rest) or (sub == "switch" and ("-c" in rest or "--create" in rest))
                or (sub == "worktree" and rest[:1] == ["add"])):
            refuse(f"git {sub} changes code or branches")
        if role == "spike" and sub in ("checkout", "switch", "pull"):
            refuse("the main checkout stays where it is (read another branch with git show <branch>:<path>)")
        continue

    if head == "gh" and len(words) > 2:
        if words[1] == "pr" and words[2] in ("create", "merge", "edit", "close", "review", "checkout"):
            refuse(f"gh pr {words[2]} is a developer's work")
        if words[1:3] == ["issue", "develop"]:
            refuse("gh issue develop is a developer's work")
        continue

    if head == "claude" and any(w in ("--bg", "--background", "-p", "--print") for w in words[1:]):
        refuse("agents start through the plugin's scripts (start-dev.sh, spike.sh), never by hand")

    if head in ("sed", "perl") and any(w in ("-i", "--in-place") or w.startswith("-i") for w in words[1:]):
        files = [w for w in words[1:] if not w.startswith("-")]
        # Without -e or -f the first word is the script, the rest are files.
        if not any(w in ("-e", "--expression", "-f", "--file") or w in ("-pe", "-ne", "-pi", "-npe") for w in words[1:]):
            files = files[1:]
        if any(inside_repo(f) for f in files):
            refuse(f"{head} -i edits a file of the repository")

    if other:
        if head in BUILD:
            refuse(f"{head} could change another repository ({other}); there you may only read")
        if any(re.match(r"^\d*>>?$", w) for w in words):
            refuse(f"it writes a file while in another repository ({other})")
sys.exit(0)
