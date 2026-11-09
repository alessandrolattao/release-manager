---
name: plan
description: Prepares work for the release-manager while the user and you talk it through - creating issues, reviewing the backlog, designing a new project, and the technical analysis of an issue when the user asks for it. Use when the user wants to create, review, split, prioritise or analyse issues for /release-manager:run.
---

# Preparing work for the release manager

The user talks with you and together you decide what to build and, when they want, how; the release manager (`/release-manager:run`) then builds it on its own. There is no fixed flow here: follow the conversation, whether it is a backlog review, the design of a new project, a batch of new issues or the technical analysis of one.

**Creating issues and analysing them are two separate moments, and the second is the user's call.** An issue can be created with no technical analysis at all: it goes to the backlog, and that is normal. The technical analysis of an issue happens only when the user asks for it, issue by issue; never start it, propose it or slip technical decisions into an issue on your own because you are creating it.

**GitHub Issues is the center of development.** What you decide together ends up in issues and their comments, never only in this conversation.

**This skill prepares work, it never does it.** You write issues, comments, labels, fields and relationships; you do not edit the repository's files, create branches, commit, push, open or merge pull requests, or start developer agents. "Follow the flow" here means the repository's conventions for issues. Building is the release manager's job, from the issues you prepared.

**Only the repository you are in.** Prepare issues of this repository alone; what concerns another one belongs to that repository's own session or planner.

## Before you create or change anything on GitHub

1. **Read the release manager's own rules**: `${CLAUDE_PLUGIN_ROOT}/skills/run/SKILL.md`. It says what makes an issue workable (assigned to the user, the label `ready for development`, nothing open blocking it, no `question` label, technical decisions clear in its comments), how it treats the backlog, and what its developer agents are told (`${CLAUDE_PLUGIN_ROOT}/skills/run/agent-brief.md`). Prepare every issue against those rules, as they are written today.
2. **Load the repository's own way of working** with the Skill tool, the same skills the release manager loads: the development flow, the issue conventions (how an issue is written, sized, labelled, split), testing (so the acceptance criteria can be tried), and who does what (owners, guarded areas). Read its CLAUDE.md files too. They decide how an issue is written; this skill only decides that it is complete.

## The rules of the conversation

- **The user decides, you propose.** For every technical choice, give the options you see, with what each costs, and a recommendation; the user picks. One decision at a time.
- **Only what the user decided becomes a technical decision** in an issue. A proposal they did not answer is not a decision: leave it as an open question on the issue, with the `question` label.
- **Show before you publish.** Before creating an issue, writing a decisions comment or changing fields or relationships, show the user the full text or the change and wait for their yes.
- **One topic, one issue.** Split what is too big the way the repository's issue rules say, and link the pieces with relationships.

## Creating an issue

- Written with the repository's conventions (title, body, acceptance criteria that can be tried, language): what must become true, not how.
- Assigned: to the user when the release manager should build it; to whoever the repository's `.md` files name when it is someone else's area (then it is not the release manager's).
- **Priority and Effort**, when the repository has those fields: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/set-fields.sh" <n> <Urgent|High|Medium|Low> <High|Medium|Low>`. They only order the queue.
- **Relationships**: an issue that needs another one first is blocked by it: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/block.sh" <n> <blocking>` (`--remove` to undo).

That is all an issue needs to exist. Without technical decisions and the label it stays in the backlog until the user asks for its analysis.

## The technical analysis, when the user asks for it

For the issue the user names, go through the technical choices with them, one at a time, as the rules of the conversation say. The research behind an analysis or an opinion the user asks for (code to read, documentation, options to compare) is done by read-only consultant sessions this session starts with `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/consult.sh"`, as the planner skill (`${CLAUDE_PLUGIN_ROOT}/skills/planner/SKILL.md`, "Technical analysis and opinions") says: never by the release manager, never through an issue or a message. What comes out:

- **Technical decisions in a comment that starts with `## Technical decisions`**, one decision per line, everything the developer agent needs so that it never has to decide: what to build, where, with which data, what not to touch. The heading is fixed in every language: it is how the release manager and its agents tell what is decided from what was only discussed. When a decision changes later, write a new `## Technical decisions` comment with the whole updated list and what it replaces: the latest one wins.
- **The label `ready for development`, last of all**: only after the `## Technical decisions` comment is posted, with everything above in place, and the user says yes: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/ready.sh" <n>` (`--remove` sends it back to the backlog). The label is what lets the release manager take the issue, so it never goes on before the decisions; the script refuses it while the issue has no `## Technical decisions` comment.

## Before you finish

Read back each issue you created or touched (`gh issue view <n> --comments`, and `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/queue.sh"` for how the release manager sees it). Tell the user, one line per issue, where it stands: ready for the release manager, or in the backlog and why (its technical analysis not done yet, a decision still open, blocked by #x, assigned to someone else). An issue just created without analysis is simply in the backlog: say so, do not offer to analyse it.
