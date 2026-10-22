# Vibe GitTree to-do

Ideas still open. Shipped work is described in the README.

## Shipped from the earlier list

Deep links and the `gittree` command, the file diff window, Jira ticket statuses with fix versions
and an on-disk cache, GitHub pull requests with stacks, the scalable repository list (locations,
⌘K switcher, sort options, folder scan, Open in New Tab), AI feature grouping with Apple's on-device
model, the Light/Dark/System appearance setting, syntax colors with a side-by-side mode in the
diff window, Jira profiles per repository, highlighting a pull request's or a stack's commits in
the graph, Jira epics in the sidebar (tickets grouped by epic, an epic's commits highlighted),
unreleased fix versions in the sidebar (Releases, with their tickets), a pull request's timeline
(opened, commits, reviews, merged), the branch comparison overview (commits, tickets, files and
authors on each side, and where the branches diverged), a file's diff since the branches diverged
and all of one side's changes in one window, comparing any two commits and recent comparisons per
repository, recently released fix versions and a per-repository fix version pattern in Releases,
and moving between a commit's files in the diff window (the biggest changes stand out).

Not on the list, but shipped with those: uncommitted changes and stashes (a row above the history,
Local Changes in the sidebar), staging, committing and stashing behind Settings › General › Allow
commits and stashes, and Help › Report an Issue or Idea.

Dropped: AI summaries and release notes. Apple's on-device model is only used to sort commits into
features.

## Still open

- **A worktree's uncommitted changes**: selecting a worktree in the sidebar shows its changes in the
  details, as Local Changes does for the repository's own folder (`git status` only on selection,
  one at a time). For now, Open as Repository adds the worktree to the list on its own.
