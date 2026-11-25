# Developing the team plugin

Instructions for the developers of this repository.

This plugin does process and coordination, not security: protection is Claude Code's job (its permission modes, auto mode), so the plugin adds no hook or check meant to protect.

## Before opening a pull request

Run these from the checkout's root, and report their results in the pull request:

- `sh tests/e2e.sh`: the scripts, the dispatcher, `/team:update` and the hooks end to end, with `gh`, `claude` and `clessidra` stubbed, a local git repository and every state folder in a temporary folder it removes when it ends;
- `claude plugin test .`: the hooks module's tests, `hooks/*.test.tsx`;
- `claude plugin validate .`;
- the hooks module's type-check, as the plugin-authoring skill says: `tsc -p .` once the engine has laid its types in `.claude-plugin/types/`; otherwise with the `tsconfig.json` the skill's `claude-code.d.ts` gives in its header, kept outside the checkout, its `include` naming that file, `hooks` and `types`.

`tests/e2e.sh` prints its failures and ends with `passed=<n> failed=<n>`, exiting non-zero when any fails. There is no CI workflow: the checks run on the developer's machine.

## Tests go with the change

- A change to the scripts or the hooks gets its checks in `tests/`.
- A change to the hooks module gets its tests in `hooks/*.test.tsx`.

## Versioning

Except the pull request a release rides on (see Releases), a pull request never changes `version` in `.claude-plugin/plugin.json`, nor `.claude-plugin/marketplace.json`, and its title carries no version. When the default branch moved, merge it into the branch (this repository merges: no rebase, no force push).

## Releases

For the tech lead and the developers of this repository.

- The user decides when to release, with the tech lead. The tech lead proposes the number (patch for fixes only, minor when something new is in) with the list of pull requests merged since the last `v*` tag.
- A release has no issue of its own: on the user's yes, it rides on the pull request of the last issue of the batch. The tech lead writes it, the version and that list as its notes, in that issue's `## Technical decisions`.
- That issue's developer, in its pull request, sets `version` in `.claude-plugin/plugin.json` to `<version>`, and the marketplace's plugin entry in `.claude-plugin/marketplace.json` to `"source": { "source": "github", "repo": "alessandrolattao/team", "ref": "v<version>" }`.
- After the decision review passes, and before `merge.sh`, the developer tags the pull request's head `v<version>` and pushes the tag, so the tag exists before the marketplace on the default branch names it. Then it merges, and creates the GitHub release (`gh release create v<version>`) with the list of merged pull requests as its notes.
- Until the first release the marketplace keeps `"source": "./"`; the first release switches it to the tag.
- The board's update check reads `version` on the default branch, which changes only with a release.

## The repository is public

No project, company or person name, and no path of a user's machine, in code, tests, docs, issues or pull requests.
