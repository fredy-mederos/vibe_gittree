# Contributing

Vibe GitTree is a personal project. It's public so you can read it, clone it, build it and fork it,
and contributions are welcome.

- **Issues are welcome**: bug reports, questions and ideas. For a bug, say what you did, what you
  expected and what happened, with your macOS version and how you built or installed Vibe GitTree.
- **Pull requests are welcome**, with the prompt you used and screenshots of the change (below).
- **Forks are welcome**: change anything you like in yours, under the [MIT license](LICENSE).

## Pull requests

So it's clear what was done, a pull request's description has two things
([the template](.github/pull_request_template.md) asks for them):

- **The prompt you used**: what you asked your coding agent, word for word. If it took more than
  one, include them all, in order, follow-ups and corrections too.
- **Screenshots** of the change in the app: before and after when it changes something that was
  already there. A change with nothing to see in the app (a script, the build) shows it working
  instead, in a screenshot or its output.

A pull request without both isn't reviewed until it has them.

Before you open one:

- Have your agent follow [CLAUDE.md](CLAUDE.md), the project's rules (Claude Code reads it on its
  own; point other agents at it). Among them: Vibe GitTree stays read-only unless the user allows
  changes, the build has no warnings, and text the app shows ships with its translations into all
  20 languages (the `localize-vibe-gittree` skill).
- With Claude Code or Codex, ask your agent to open the pull request: the
  [`pull-request-vibe-gittree` skill](skills/pull-request-vibe-gittree/SKILL.md) walks it through
  all of this, from the checks to the screenshots and the description. It works as a checklist by
  hand too.
- Pull requests are public. Take the screenshots with a public or throwaway repository open, never
  private work (`scripts/mock-jira.py` stands in for a Jira site), and keep anything private out
  of the prompt.

What you contribute is under the [MIT license](LICENSE), like the rest of Vibe GitTree.
