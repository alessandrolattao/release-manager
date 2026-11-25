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
reads from a <(...); also after a wrapper (timeout 5, xargs -I {}, sudo -u me), and a shell's -c string among
a command's arguments (find -exec sh -c). A here-document is data, also into a shell.
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
SPIKE_FORBIDDEN_SCRIPTS = {"spike.sh", "start-dev.sh", "start-qa.sh", "merge.sh", "merge-bot.sh", "checkout.sh"}
# The API of a repository: repos/<owner>/<name>, refused by default wherever the shell runs it (gh api, curl,
# wget, a variable, a function, data piped into xargs: all alike). GraphQL names no repository: it is not judged.
REPOS = re.compile(r"repos/([\w.-]+/[\w.-]+)")
# What may come before repos/ in its word in an API call: nothing, slashes, or the API's host (any case, any
# scheme or user before it, a port).
ENDPOINT_PREFIX = re.compile(r"(?:\S*(?i:api\.github\.com)(?::\d+)?)?/*")
# A variable or a substitution (blanked as $) right before repos/, with only slashes and .. between: it may
# stand for the API's host ($API/repos/..., $API/../repos/...). One at the start of a local path does not
# ($X/.../repos/), nor does $HOME, the home folder as ~ is.
VARIABLE_BEFORE = re.compile(r"\$(?:\{[^}]*\}|[A-Za-z_]\w*|[0-9@*#?!-])?(?:/+\.\.?)*/*$")
HOME_BEFORE = re.compile(r"\$HOME(?:/+\.\.?)*/*$")
# The option that gives a shell its command: -c, alone or in a cluster (bash -lc, sh -ec).
SHELLS = ("sh", "bash", "zsh", "dash")
SHELL_COMMAND = re.compile(r"-[A-Za-z]*c[A-Za-z]*")
# The commands that run a string as code, and ssh's options that take a value.
CODE_RUNNERS = SHELLS + ("eval", "source", ".", "ssh")
SSH_VALUE_FLAGS = set("bcDEeFIiJLlmOopQRSWw")
# Commands that run the command after them (timeout 5 sh, xargs -I {} sh -c, sudo -u me sh ...): their long
# options, all of them so that a prefix expands as getopt_long expands it (--us is --user), and the options
# that take a value as the next word (or the rest of a bundle: -nu me). env -S is apart: its string is the
# command, split into words.
WRAPPERS = {
    "sudo": ("--askpass --background --bell --chdir --chroot --close-from --command-timeout --edit --group --help "
             "--host --list --login --non-interactive --other-user --preserve-env --preserve-groups --prompt "
             "--remove-timestamp --reset-timestamp --role --set-home --shell --stdin --type --user --validate --version",
             "-u -g -C -D -h -p -r -R -t -T -U --chdir --chroot --close-from --command-timeout --group --host "
             "--other-user --prompt --role --type --user"),
    "doas": ("", "-u -C -a"),
    "env": ("--argv0 --block-signal --chdir --debug --default-signal --help --ignore-environment --ignore-signal "
            "--list-signal-handling --null --split-string --unset --version",
            "-u -C -P -a -S --argv0 --chdir --split-string --unset"),
    "time": ("--append --format --help --output --portability --quiet --verbose --version", "-f -o --format --output"),
    "nohup": ("--help --version", ""),
    "exec": ("", "-a"),
    "timeout": ("--foreground --help --kill-after --preserve-status --signal --verbose --version",
                "-s -k --kill-after --signal"),
    "nice": ("--adjustment --help --version", "-n --adjustment"),
    "ionice": ("--class --classdata --help --ignore --pgid --pid --uid --version",
               "-c -n -p -P -u --class --classdata --pgid --pid --uid"),
    "command": ("", ""),
    "builtin": ("", ""),
    "xargs": ("--arg-file --delimiter --eof --exit --help --interactive --max-args --max-chars --max-lines --max-procs "
              "--no-run-if-empty --null --open-tty --process-slot-var --replace --show-limits --verbose --version",
              "-I -L -n -P -s -d -E -a --arg-file --delimiter --max-args --max-chars --max-lines --max-procs "
              "--process-slot-var"),
    "stdbuf": ("--error --help --input --output --version", "-i -o -e --error --input --output"),
    "setsid": ("--ctty --fork --help --version --wait", ""),
}
WRAPPERS = {name: (longs.split(), set(values.split())) for name, (longs, values) in WRAPPERS.items()}
# A redirection operator, as the tokenizer splits it from its target (>, >>, 2> is 2 then >, &>, >&, <).
REDIRECT = re.compile(r"&?[<>]{1,2}[&|]?")
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
    # shlex runs punctuation together (;>, ;;>): separators and redirections come apart, <( and >| stay one word.
    tokens = [part for token in tokens
              for part in (re.findall(r"<\(|>\||[;|()]+|[<>&]+", token) if token and set(token) <= set(";&|()<>") else [token])]
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
        return restored(words[words.index("<<<") + 1]) if "<<<" in words[:-1] else None
    if head not in ("echo", "printf"):
        return None
    rest = words[1:]
    while rest and re.fullmatch(r"-[neE]+", rest[0]):
        rest = rest[1:]
    return restored(" ".join(rest[1:] if rest[:1] == ["--"] else rest).replace("\\n", "\n"))


def command_words(words):
    """A command's words from the command itself on, past assignments and wrappers with their options (sudo -u
    me, sudo -nu me, timeout -s KILL 5, xargs -I {}, nice -n 5, env X=1), read as getopt reads them; whether env
    -S gave them (its string, split into words, is the command); and the wrappers that came before it."""
    words, wrapper, split, wrappers = unredirected(words), None, False, set()
    while words:
        word, value = words[0], None
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            words = words[1:]
        elif os.path.basename(word) in WRAPPERS:
            wrapper, words = os.path.basename(word), words[1:]
            wrappers.add(wrapper)
        elif wrapper and word.startswith("--"):
            longs, values = WRAPPERS[wrapper]
            name, eq, given = word.partition("=")
            names = [o for o in longs if o.startswith(name)] if name not in longs and name != "--" else [name]
            name = names[0] if len(names) == 1 else name
            takes = name in values
            value, words = (given, words[1:]) if eq or not takes else (words[1] if len(words) > 1 else "", words[2:])
            if wrapper == "env" and name == "--split-string":
                words, split = split_words(value) + words, True
        elif wrapper and word.startswith("-") and len(word) > 1:
            words = words[1:]
            for i, c in enumerate(word[1:], 2):
                if "-" + c in WRAPPERS[wrapper][1]:
                    value = word[i:] or (words[0] if words else "")
                    words = words if word[i:] else words[1:]
                    if wrapper == "env" and c == "S":
                        words, split = split_words(value) + words, True
                    break
        elif wrapper == "timeout" and re.fullmatch(r"\d+(?:\.\d+)?[smhd]?", word):
            words = words[1:]
        else:
            break
    return words, split, wrappers


def split_words(text):
    """A string split into words as the shell would split it (env -S)."""
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def code_of(words, stdin=None):
    """The text a command runs as code: a shell's -c string (bash -lc too, -- skipped); what a shell reads from
    its stdin (stdin, what is printed into its pipe, or its <<< string), also as the -c string xargs gives it;
    what echo, printf or cat <<< prints into a <(...) for a shell, source or .; eval's words; ssh's remote
    command; the command env -S's string makes; and with any of these, what its substitutions print. The
    command is the word command_words finds: a later word that only names one is an argument (sudo git commit -m
    eval, grep -c sh, jq .). None when the command runs no code."""
    command, split, wrappers = command_words(words)
    if not command:
        return None
    head, rest = os.path.basename(command[0]), command[1:]
    if head == "eval":
        code = " ".join(rest)
    elif head == "ssh":
        code = remote_command(rest)
    elif head not in CODE_RUNNERS:
        code = shlex.join(command) if split else None
    else:
        fed = rest[rest.index("<<<") + 1] if "<<<" in rest[:-1] else stdin
        c = next((k for k, w in enumerate(rest) if head in SHELLS and SHELL_COMMAND.fullmatch(w)), None)
        if c is not None:
            string = given_string(rest[c + 1:])
            code = string if string is not None else (fed if "xargs" in wrappers else "")
        elif "<(" in rest:
            code = printed(rest[rest.index("<(") + 1:])
        else:
            code = fed
    return with_printed(code)


def given_string(args):
    """The string after a shell's -c, past a --; None when none comes (xargs gives it, or a redirection
    follows: a word of <, >, & alone, as the tokenizer splits them; '>/dev/null git push' is a string)."""
    args = args[1:] if args[:1] == ["--"] else args
    return args[0] if args and not re.fullmatch(r"[<>&]+\(?", args[0]) else None


def with_printed(code):
    """Code, and what the echo, printf or cat <<< of its substitutions print, which becomes code too
    (eval "$(echo '...')", bash -c "$(printf '...')")."""
    if code is None:
        return None
    code = restored(code)
    return "\n".join([code] + [text for inner in scan(code)[1] for words in segments_of(inner)
                                if (text := printed(words)) is not None])


def piped_text(commands, n):
    """What the echo, printf or cat <<< of the pipeline before the command at n print into its pipe: past
    filters (tee, grep ...) and into a { group; } or a ( subshell ) of it; None when nothing known is piped in."""
    if not piped(commands[n][1]):
        return None
    texts, depth, i = [], commands[n][1].count(")"), n - 1
    while i >= 0:
        words, separator = commands[i]
        depth += words == ["}"]
        text = printed([w for w in words if w != "{"]) if words != ["}"] else None
        texts += [text] if text is not None else []
        depth += separator.count(")") - separator.count("(") - (words[:1] == ["{"])
        if depth <= 0 and not piped(separator):
            break
        i -= 1
    return "\n".join(reversed(texts)) if texts else None


def shell_inside(words):
    """The -c string of a shell among a command's arguments (find -exec sh -c '...', parallel bash -lc '...'),
    with what its substitutions print; None when there is none."""
    for i, word in enumerate(words):
        if os.path.basename(word) in SHELLS:
            for k in range(i + 1, len(words)):
                if not words[k].startswith("-"):
                    break
                if SHELL_COMMAND.fullmatch(words[k]):
                    string = given_string(words[k + 1:])
                    return with_printed(string if string is not None else "")
    return None


def remote_command(args):
    """ssh's remote command: the words after its host and its options, which may come before or after the host
    (-- ends them), joined as ssh joins them; None when there is none."""
    j, host = 0, None
    while j < len(args):
        word = args[j]
        if word == "--":
            j += 1
            if host is None and j < len(args):
                host, j = args[j], j + 1
            break
        if word.startswith("-") and len(word) > 1:
            j += 2 if len(word) == 2 and word[1] in SSH_VALUE_FLAGS else 1
        elif host is None:
            host, j = word, j + 1
        else:
            break
    return " ".join(args[j:]) if host is not None and j < len(args) else None


def unredirected(words):
    """A command's words without its redirections, operator and target (>/dev/null git push is git push), and
    the descriptor number written against one (2>/dev/null; in git branch 2 >/dev/null, 2 is a word)."""
    out, i = [], 0
    while i < len(words):
        if REDIRECT.fullmatch(words[i]):
            if out and re.fullmatch(r"[\ue100-\ue109]+", out[-1]):
                out.pop()
            i += 1 if words[i + 1:i + 2] == ["<("] else 2
        else:
            out.append(words[i])
            i += 1
    return out


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
    commands = commands_of(text)
    for n, (words, _) in enumerate(commands):
        for inner in {code_of(words, piped_text(commands, n)), shell_inside(words)} - {None}:
            found += api_calls(inner)
    return found + [m.group(1) for m in REPOS.finditer(plain) if is_call(plain, m.start(), strings)]


def is_call(text, at, strings):
    """Whether the repos/ at this place of a shell text (its substitutions blanked as $) may be an API call:
    not after a folder (a local path, a URL to another host), not inside a quoted string after other text;
    unless what comes before it in its word is the API's host, slashes, or a variable or substitution that may
    stand for them (gh api "repos/...", "$API/repos/..."). strings holds where each quoted string's text starts
    and ends."""
    string = next((start for start, end in strings if start <= at < end), None)
    inside = text[string:at] if string is not None else ""
    # Spaces at the start of the string are no other text (' repos/...' still starts with the endpoint).
    if re.search(r"\s", inside.lstrip()):
        return False
    if inside != inside.lstrip():
        word = inside.lstrip()
    else:
        word = word_before(text, string - 1 if string is not None else at, strings) + inside
    # A command that names HOME but to read it ($HOME, ${HOME}) may set it (HOME=, export, read, for, ${HOME:=}):
    # then ~ and $HOME are no home folder.
    home_set = bool(re.search(r"\bHOME\b", re.sub(r"\$HOME\b|\$\{HOME\}", "", command)))
    for made in expanded(word):
        made = folded(re.sub(r"^~(?=/|$)", "$HOME", made) if home_set else made)
        home = HOME_BEFORE.search(made) and not home_set
        if ENDPOINT_PREFIX.fullmatch(made) or (VARIABLE_BEFORE.search(made) and not home) or (not inside and "/" not in made):
            return True
    return False


def word_before(text, end, strings):
    """What comes before this place in its shell word, quoted parts included and their quotes removed
    ('~/.local/state/team'/repos/... gives ~/.local/state/team/)."""
    closing = {stop: start for start, stop in strings}
    out, i = [], end - 1
    while i >= 0:
        if i in closing and text[i] in "'\"":
            out.append(text[closing[i]:i])
            i = closing[i] - 2
        elif text[i] in " \t\n;&|()<>`=":
            break
        else:
            out.append(text[i])
            i -= 1
    return "".join(reversed(out))


def expanded(word):
    """The words the shell makes of a word: its backslashes gone, its braces expanded ({a,b} gives a and b; a
    brace left open, one that goes on past repos/, goes), ${X} kept as $X and ${...} as a variable ($V); 64 at
    most."""
    words = [re.sub(r"\$\{[^}]*\}", "$V", re.sub(r"\$\{(\w+)\}", r"$\1", word)).replace("\\", "")]
    while len(words) < 64 and any(re.search(r"\{[^{}]*,[^{}]*\}", w) for w in words):
        made = []
        for w in words:
            group = re.search(r"\{([^{}]*,[^{}]*)\}", w)
            made += [w[:group.start()] + alt + w[group.end():] for alt in group.group(1).split(",")] if group else [w]
        words = made
    return [w.replace("{", "").replace("}", "") for w in words]


def scan(text):
    """Reads a shell text as the shell does, near enough. Gives the text, as long as it was, with its comments
    blanked and its unquoted new lines turned into ; (they end a command); the command texts of its
    substitutions; the text with its substitutions blanked too, as $; and where the text of each quoted string
    starts and ends. A substitution is $(...) or `...`, bare or double-quoted; inside single quotes or escaped
    (an odd number of backslashes) it is text. A comment starts where a word does (not in a#b, nor right after a
    substitution: $(x)#b) and ends with its line."""
    out, plain, inners, strings = list(text), list(text), [], []
    quote, opened, i, after = None, 0, 0, -1
    while i < len(text):
        c = text[i]
        if quote == "'" and c != "'":
            out[i] = marked(c)
            i += 1
        elif c == "\\" and quote != "'":
            if i + 1 < len(text):
                out[i + 1] = marked(text[i + 1])
            i += 2
        elif c in "'\"" and quote in (None, c):
            if quote:
                strings.append((opened, i))
            quote, opened = (None, 0) if quote else (c, i + 1)
            i += 1
        elif c == "\n" and quote is None:
            out[i] = ";"
            i += 1
        elif quote is None and c.isdigit() and (i == 0 or text[i - 1] in " \t\n;&|()") and re.match(r"\d+[<>]", text[i:]):
            # A descriptor number written against its operator (2>, not 2 >): unredirected() drops it.
            end = re.match(r"\d+", text[i:]).end() + i
            out[i:end] = [chr(0xE100 + ord(d) - ord("0")) for d in text[i:end]]
            i = end
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
            if quote:
                out[i] = marked(c)
            i += 1
    if quote:
        strings.append((opened, len(text)))
    return "".join(out), inners, "".join(plain), strings


def folded(word):
    """A word with its /./ and dir/../ folded, as a URL client folds them (api.github.com/x/../repos/...); a
    leading ./ or ../ stays, a local path's own, and so does a .. after ~ or a variable, whose folder is not
    known here (~/../repos/... is a local path)."""
    while True:
        fold = re.sub(r"(?<=/)\./", "", word)
        fold = re.sub(r"(?:(?<=/)|^)(?!\.\.?/)(?![~$])[^/]+/\.\./", "", fold)
        if fold == word:
            return word
        word = fold


def marked(c):
    """An operator character as the tokenizer must see it when quoted or escaped: a word's, not an operator
    ('>', a backslash before >, "a;b"). restored() gives it back where the text becomes code."""
    return chr(0xE000 + ord(c)) if c in ";&|()<>" else c


def restored(text):
    """Text with its marked operators and descriptor numbers given back (the -c string of sh -c 'a; b' is a; b
    again)."""
    text = re.sub(r"[\ue100-\ue109]", lambda m: chr(ord(m.group()) - 0xE100 + ord("0")), text)
    return re.sub(r"[\ue000-\ue0ff]", lambda m: chr(ord(m.group()) - 0xE000), text)


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
for n, (written, _) in enumerate(commands):
    words = [restored(w) for w in bare(unredirected(bare(written)))]
    if not words:
        # Nothing but a redirection (> out.txt, (ls) > out.txt): main took it for the command and refused it in
        # another repository; so does this.
        top = toplevel(where)
        if (top and top != root and not top.startswith(root + os.sep)
                and any(re.match(r"^\d*>>?$", restored(w)) for w in written)):
            refuse(f"it writes a file while in another repository ({top})")
        continue
    head = os.path.basename(words[0])

    # The plugin's own scripts: they hold their own rules.
    target = words[1] if head in ("sh", "bash") and len(words) > 1 else words[0]
    real = os.path.realpath(os.path.join(where, os.path.expanduser(target)))
    if real.startswith(plugin + os.sep) and real.endswith(".sh"):
        if role == "spike" and os.path.basename(real) in SPIKE_FORBIDDEN_SCRIPTS:
            refuse(f"a spike only reads: it does not run {os.path.basename(real)}")
        continue

    # A string that becomes code (sh -c '...', echo '...' | sh, source <(...), eval '...', ssh host '...', find
    # -exec sh -c '...') is checked as a command of its own; the command that runs it is still judged by its own
    # rules below (in another repository, bash -c 'ls' > file writes a file).
    for code in {code_of(commands[n][0], piped_text(commands, n)), shell_inside(commands[n][0])} - {None}:
        nested = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]],
                                input=f"cd {shlex.quote(where)}\n{code}", capture_output=True, text=True)
        if nested.returncode != 0:
            sys.stdout.write(nested.stdout)
            sys.stderr.write(nested.stderr)
            sys.exit(nested.returncode)

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
    # A redirection before the command (>out.txt git log): main took it for the command and refused it in
    # another repository; so does this.
    if other and [restored(w) for w in bare(written)[:1]] != words[:1] and any(
            re.match(r"^\d*>>?$", restored(w)) for w in written):
        refuse(f"it writes a file while in another repository ({other})")

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
        if any(re.match(r"^\d*>>?$", restored(w)) for w in written):
            refuse(f"it writes a file while in another repository ({other})")
sys.exit(0)
