# Sourced by the scripts that write to GitHub. Every write that has a REST endpoint (a comment, an issue, a
# label, an assignee) goes through it, not through `gh issue comment`, `gh issue create` or `gh issue edit`:
# those go through GitHub's GraphQL API, which fails on a long body that the REST API takes. GraphQL stays only
# where REST has no endpoint (an issue's status, a project's fields).
# shellcheck shell=sh

# rest <gh api arguments...>: `gh api` with those arguments, tried up to 3 times, 5 and 15 seconds apart
# (REST_WAITS, for the tests), while GitHub answers with a 5xx status or cannot be reached. Prints what the
# last try printed; on a failure only its error, on stderr, with its exit status. A body goes in a file
# (rest_body), never on stdin, which a second try could not read again.
rest() {
	_rest_out=$(mktemp)
	_rest_err=$(mktemp)
	_rest_waits=${REST_WAITS:-5 15}
	while :; do
		_rest_status=0
		gh api "$@" >"$_rest_out" 2>"$_rest_err" || _rest_status=$?
		[ "$_rest_status" -ne 0 ] && [ -n "$_rest_waits" ] && rest_transient "$_rest_err" || break
		sleep "${_rest_waits%% *}"
		case "$_rest_waits" in *" "*) _rest_waits=${_rest_waits#* } ;; *) _rest_waits="" ;; esac
	done
	[ "$_rest_status" -ne 0 ] || cat "$_rest_out"
	cat "$_rest_err" >&2
	rm -f "$_rest_out" "$_rest_err"
	return "$_rest_status"
}

# rest_body <gh api arguments...>: rest, with the body read from stdin and sent from a file (-F body=@<file>).
rest_body() {
	_rest_body=$(mktemp)
	cat >"$_rest_body"
	_rest_body_status=0
	rest "$@" -F "body=@$_rest_body" || _rest_body_status=$?
	rm -f "$_rest_body"
	return "$_rest_body_status"
}

# rest_transient <file with gh's error>: true when GitHub answered with a 5xx status ("gh: <message> (HTTP 502)")
# or could not be reached: a failed name lookup ("error connecting to api.github.com") or a connection that
# failed or broke ('Post "https://api.github.com/...": dial tcp ...: connection refused').
rest_transient() {
	grep -Eq 'HTTP 5[0-9]{2}|^error connecting to |^[A-Z][a-z]+ "https?://' "$1"
}
