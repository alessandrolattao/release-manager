---
name: plan
description: Prepares work for the release-manager while the user and you talk it through - creating issues, reviewing the backlog, designing a new project, a technical analysis, anything that ends in GitHub issues. Use when the user wants to create, review, split, prioritise or analyse issues, so that each one comes out ready for /release-manager:run.
---

# Preparing work for the release manager

The user talks with you and together you decide what to build and how; the release manager (`/release-manager:run`) then builds it on its own. There is no fixed flow here: follow the conversation, whether it is a backlog review, the design of a new project, a technical analysis of one issue or a batch of new ones. What is fixed is the result: issues the release manager can work on without asking.

**GitHub Issues is the center of development.** What you decide together ends up in issues and their comments, never only in this conversation.

## Before you create or change anything on GitHub

1. **Read the release manager's own rules**: `${CLAUDE_PLUGIN_ROOT}/skills/run/SKILL.md`. It says what makes an issue workable (assigned to the user, the label `ready for development`, nothing open blocking it, no `question` label, technical decisions clear in its comments), how it treats the backlog, and what its developer agents are told (`${CLAUDE_PLUGIN_ROOT}/skills/run/agent-brief.md`). Prepare every issue against those rules, as they are written today.
2. **Load the repository's own way of working** with the Skill tool, the same skills the release manager loads: the development flow, the issue conventions (how an issue is written, sized, labelled, split), testing (so the acceptance criteria can be tried), and who does what (owners, guarded areas). Read its CLAUDE.md files too. They decide how an issue is written; this skill only decides that it is complete.

## The rules of the conversation

- **The user decides, you propose.** For every technical choice, give the options you see, with what each costs, and a recommendation; the user picks. One decision at a time.
- **Only what the user decided becomes a technical decision** in an issue. A proposal they did not answer is not a decision: leave it as an open question on the issue, with the `question` label.
- **Show before you publish.** Before creating an issue, writing a decisions comment or changing fields or relationships, show the user the full text or the change and wait for their yes.
- **One topic, one issue.** Split what is too big the way the repository's issue rules say, and link the pieces with relationships.

## What a ready issue has

- Written with the repository's conventions (title, body, acceptance criteria that can be tried, language).
- Assigned: to the user when the release manager should build it; to whoever the repository's `.md` files name when it is someone else's area (then it is not the release manager's).
- **Priority and Effort**, when the repository has those fields: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/set-fields.sh" <n> <Urgent|High|Medium|Low> <High|Medium|Low>`. They only order the queue.
- **Relationships**: an issue that needs another one first is blocked by it: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/block.sh" <n> <blocking>` (`--remove` to undo).
- **Technical decisions in a comment that starts with `## Technical decisions`**, one decision per line, everything the developer agent needs so that it never has to decide: what to build, where, with which data, what not to touch. The heading is fixed in every language: it is how the release manager and its agents tell what is decided from what was only discussed. When a decision changes later, write a new `## Technical decisions` comment with the whole updated list and what it replaces: the latest one wins.
- **The label `ready for development`, last of all**: only after the `## Technical decisions` comment is posted, with everything above in place, and the user says yes: `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/ready.sh" <n>` (`--remove` sends it back to the backlog). The label is what lets the release manager take the issue, so it never goes on before the decisions; the script refuses it while the issue has no `## Technical decisions` comment.

## Before you finish

Check each issue you prepared or touched against the release manager's rules, with `sh "${CLAUDE_PLUGIN_ROOT}/skills/run/scripts/queue.sh"` and by reading it back (`gh issue view <n> --comments`). Tell the user, one line per issue, which are ready for the release manager and which are not, and why (no `ready for development` label, blocked by #x, a decision still open, assigned to someone else).
