# Developing the team plugin

Instructions for the developers of this repository.

## Before opening a pull request

Run these from the checkout's root, and report their results in the pull request:

- `sh tests/e2e.sh`: the scripts, the dispatcher, `/team:update` and the hooks end to end, with `gh`, `claude` and `clessidra` stubbed, a local git repository and every state folder in a temporary folder it removes when it ends;
- `sh tests/guard.sh`: the guard hook (`hooks/guard.py`) on the commands it must let through and the ones it must refuse;
- `claude plugin test .`: the hooks module's tests, `hooks/*.test.tsx`;
- `claude plugin validate .`;
- the hooks module's type-check, as the plugin-authoring skill says: `tsc -p .` once the engine has laid its types in `.claude-plugin/types/`; otherwise with the `tsconfig.json` the skill's `claude-code.d.ts` gives in its header, kept outside the checkout, its `include` naming that file, `hooks` and `types`.

`tests/e2e.sh` and `tests/guard.sh` print their failures and end with `passed=<n> failed=<n>`, exiting non-zero when any fails. There is no CI workflow: the checks run on the developer's machine.

## Tests go with the change

- A change to the scripts or the hooks gets its checks in `tests/`.
- A change to the hooks module gets its tests in `hooks/*.test.tsx`.

## Versioning

Every pull request bumps `version` in `.claude-plugin/plugin.json` to the next patch version over the default branch's, and is titled `<version>: <what it changes>`. When the default branch moved, merge it into the branch (as `merge.sh` says: no rebase, no force push) and take the next free number; check the default branch's version again right before `merge.sh`.

## The repository is public

No project, company or person name, and no path of a user's machine, in code, tests, docs, issues or pull requests.
