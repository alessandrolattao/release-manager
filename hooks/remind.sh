#!/bin/sh
# Run every few minutes in the planner's session by the hooks module (hooks/sessions.tsx): what has been
# waiting for the user for 30 minutes is said out loud through TitTieS, once, in one short sentence.
# What waits:
#   - the planner's own question in the chat, with no user prompt since (planner-asks.sh records it);
#   - a question of the release manager on an issue, while the label `question` is on (ask.sh records it;
#     a labelled issue it did not record counts from when it is first seen here);
#   - the release manager stopped on a permission prompt (manager-blocked.sh records it).
# Silent without TitTieS or when the session has it off.
#   remind.sh <session-id>   (from the repository's main checkout)
set -eu

sid=${1:?session id}
case "$sid" in
"" | *[!A-Za-z0-9-]*) exit 0 ;;
esac
delay=1800
here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../skills/run/scripts"
# Without GitHub the open questions cannot be told from the answered ones: try again next time.
gh api user --jq .login >/dev/null 2>&1 || exit 0
# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"
state_dir="${TMPDIR:-/tmp}/release-manager-$(id -u)"
waiting="$counters_dir/waiting"
mkdir -p "$waiting"
now=$(date +%s)
said=""
more=0

# due <record>: true when the record ("<epoch>\n<sentence>") is 30 minutes old and not said yet.
due() {
	[ -f "$1" ] && [ ! -f "$1.called" ] || return 1
	at=$(sed -n 1p "$1")
	case "$at" in "" | *[!0-9]*) return 1 ;; esac
	[ $((now - at)) -ge "$delay" ]
}
# take <record> [sentence]: queues what the record says (or the sentence given) and marks it said.
take() {
	if [ -z "$said" ]; then said=${2:-$(sed -n 2p "$1")}; else more=$((more + 1)); fi
	touch "$1.called"
}

# The planner's question, unless the user wrote to it after asking.
asked="$state_dir/$sid.asked"
if due "$asked" && [ "$(cat "$state_dir/$sid.last-prompt" 2>/dev/null || echo 0)" -lt "$(sed -n 1p "$asked")" ]; then
	take "$asked" "Il planner di $repo_short aspetta una tua risposta: $(sed -n 2p "$asked")"
fi

# The release manager's questions: one record per issue that still carries the label.
open=" $(questions_list | tr '\n' ' ') "
for record in "$waiting"/question-*; do
	[ -f "$record" ] || continue
	case "$record" in *.called) continue ;; esac
	case "$open" in *" ${record##*question-} "*) ;; *) rm -f "$record" "$record.called" ;; esac
done
for n in $open; do
	record="$waiting/question-$n"
	[ -f "$record" ] || printf '%s\nIl release manager di %s aspetta una tua risposta sulla issue %s.\n' "$now" "$repo_short" "$n" >"$record"
	if due "$record"; then take "$record"; fi
done

# The release manager stopped on a permission prompt.
manager=$(session_of "$manager_prefix" | cut -f1)
if [ -n "$manager" ] && due "$sessions_dir/$manager/blocked"; then
	take "$sessions_dir/$manager/blocked"
fi

[ -n "$said" ] || exit 0
said=$(printf '%s' "$said" | cut -c1-180)
if [ "$more" -gt 0 ]; then
	said="$said E altre $more cose ti aspettano."
fi
printf '%s\n' "$said" | sh "$scripts/titties.sh" call "$sid"
