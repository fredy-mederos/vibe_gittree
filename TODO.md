# GitTree to-do

Ideas still open. Shipped work is described in the README.

## Shipped from the earlier list

Deep links and the `gittree` command, the file diff window, Jira ticket statuses with fix versions
and an on-disk cache, GitHub pull requests with stacks, the scalable repository list (locations,
⌘K switcher, sort options, folder scan, Open in New Tab), AI feature grouping with Apple's on-device
model, and the Light/Dark/System appearance setting.

## Still open

- **Repository list**: pin favorites to the top; optional grouping by parent folder or host/owner
  (`acme/…`, `github.com/apple/…`).
- **Jira**: filter or highlight commits by ticket status ("commits whose ticket isn't Done"), and by
  fix version ("everything in 2.12").
- **GitHub**: highlight a stack's lanes in the graph; keep pull requests cached on disk like ticket
  statuses so they show instantly after a relaunch; draft/merged/closed PRs in the sidebar besides
  the open ones.
- **Features**: a short AI summary per feature (what changed, from the commit messages), and turning
  a feature or a fix version into release notes.
- **Diff window**: syntax highlighting and a side-by-side mode.
- **Activity calendar**: a contribution grid like GitHub's (one square per day, shaded by number of
  commits) for the current repository and scope, optionally filtered by author. Hovering a day shows
  that day's commits and the features and tickets they belong to; clicking it jumps the graph to that
  day (or highlights its commits). Could live in its own window or as a strip above the graph.
