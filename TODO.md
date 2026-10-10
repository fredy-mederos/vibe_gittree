# GitTree to-do

Ideas still open. Shipped work is described in the README.

## Shipped from the earlier list

Deep links and the `gittree` command, the file diff window, Jira ticket statuses with fix versions
and an on-disk cache, GitHub pull requests with stacks, the scalable repository list (locations,
⌘K switcher, sort options, folder scan, Open in New Tab), AI feature grouping with Apple's on-device
model, the Light/Dark/System appearance setting, syntax colors with a side-by-side mode in the
diff window, Jira profiles per repository, highlighting a pull request's or a stack's commits in
the graph, Jira epics in the sidebar (tickets grouped by epic, an epic's commits highlighted),
unreleased fix versions in the sidebar (Releases, with their tickets), a pull request's timeline
(opened, commits, reviews, merged), and the branch comparison overview (commits, tickets, files and
authors on each side, and where the branches diverged).

Dropped: AI summaries and release notes. Apple's on-device model is only used to sort commits into
features.

## Still open

- **Branch comparison, in detail**: click a file in the Files tab to see its diff since the
  branches diverged (the diff window compares a commit to its first parent today; it would take a
  base commit too), and a combined diff of one side.
- **Branch comparison, more ways in**: compare any two commits picked in the graph, and remember
  recent comparisons per repository.
- **Releases**: recently released fix versions too (what went out last week), and a per-repository
  filter for projects whose fix versions don't follow their tickets closely enough for the "this
  repository's tickets are in it" split.
