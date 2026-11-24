#!/bin/sh
# Leaves a message for the tech leads of ANOTHER repository, which this repository's sessions may not
# touch on GitHub, or for this repository's own from outside the team (a Pulse check, with --from).
# Inside one repository the team talks on its issues (comment.sh), never here.
# The message is a file, written atomically (Maildir: tmp/ then new/); the first tech lead of that
# repository to read its inbox takes it.
#   tell.sh <owner/name> <question|info> [--from "<sender>"] <<'EOF'
#   the message
#   EOF
# Prints NOT READ YET when no tech lead of that repository is running: the message waits until one starts.
set -eu

target=${1:?owner/name of the other repository}
kind=${2:?question or info}
shift 2
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
sender=""
while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		sender=${2:?sender}
		shift 2
		;;
	*)
		echo "unknown option '$1'" >&2
		exit 2
		;;
	esac
done
case "$kind" in question | info) ;; *)
	echo "unknown kind '$kind': question or info" >&2
	exit 2
	;;
esac
# Inside one repository the sessions talk on its issues; only a sender outside the team (--from, such as a
# Pulse check) writes to this repository's own tech leads.
[ "$target" != "$repo_full" ] || [ -n "$sender" ] || {
	echo "inside $repo_full the team talks on the issues: comment.sh <issue> <to>" >&2
	exit 2
}
body=$(cat)
[ -n "$body" ] || {
	echo "the message comes on stdin" >&2
	exit 2
}
from=${sender:-"$(address_of "${CLAUDE_CODE_SESSION_ID:-}") of $repo_full"}

box=$(inbox_dir "$target")
mkdir -p "$box/tmp" "$box/new" "$box/cur"
file="$(date +%Y%m%dT%H%M%S)-$$-$kind.md"
{
	printf 'From: %s\nKind: %s\nDate: %s\n\n' "$from" "$kind" "$(date '+%Y-%m-%d %H:%M')"
	printf '%s\n' "$body"
} >"$box/tmp/$file"
mv "$box/tmp/$file" "$box/new/$file"
echo "message left for the tech leads of $target ($kind)"

# Read yet? A tech lead of that repository is alive when its heartbeat is recent, on any account.
wanted=$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
for f in "$sessions_dir"/*/status; do
	[ -f "$f" ] || continue
	jq -e --arg r "$wanted" '.role == "tech-lead" and ((.repo // "") | ascii_downcase) == $r' "$f" >/dev/null 2>&1 || continue
	alive "$(basename "$(dirname "$f")")" && exit 0
done
echo "NOT READ YET: no tech lead of $target is running, the message waits in its inbox until one starts. If it cannot wait, tell the user."
