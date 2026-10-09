# GitTree to-do

Ideas queued for later. Move an item into the README once it ships.

## Deep links into the graph

Open GitTree at a repository, a commit and a line of that commit's changes from a URL, so a coding
session (Claude, an editor, a terminal script) can answer "when was this added?" with a link.

- URL scheme, for example:
  `gittree://open?repo=<path or remote URL or name>&commit=<sha>&path=<file>&line=<n>`
- Resolve `repo` against the library: local path first, then remote URL, then name. If it's not in
  the library yet, offer to add it (local) or clone it (remote).
- Select the commit in the graph (widening the scope if it's hidden), open the inspector, and scroll
  the changed-files list to `path`, highlighting `line` in that file's diff.
- Needs a file diff view in the inspector, which doesn't exist yet.
- Register the scheme with `CFBundleURLTypes` and handle it with `.onOpenURL`.
- Document how to build the link, so Claude can produce it: `git blame -L <line>,<line> --porcelain <file>`
  gives the commit that last touched a line; the link carries that commit, the file and the line.
- Optional `gittree` command-line helper that builds and opens the link for the current repository.

## Jira integration

Show each ticket's Jira status next to the commits that mention it. GitTree already finds ticket
keys in commit subjects by their prefix (PROJ-1234) and links them through the repository's issue link.

- Per-repository connection: Jira site URL, account email, and an API token kept in the Keychain.
- Fetch statuses in batches with JQL (`key in (PROJ-1, PROJ-2, …)`) for the visible rows, cache
  them per repository, refresh on fetch or on demand.
- Show the status as a small colored chip after the ticket key (To Do / In Progress / Done colors
  from Jira's status category); the inspector adds summary, assignee, type and fix version.
- Optional: filter or highlight commits by ticket status ("show commits whose ticket isn't Done").

## GitHub integration

- Pull requests through the GitHub CLI (`gh pr list --json …`) or the API: number, title, state
  (open, draft, merged, closed) next to branch labels and in the inspector.
- Merge commits and squash commits linked to their PR (already parsed from subjects; add title and
  state), plus reviewers and checks status for open PRs.
- "Pull requests for this branch" already opens the web search; show them in-app instead.
- Stacked pull requests: detect PRs whose base branch is another open PR's head branch (from
  `gh pr list --json number,headRefName,baseRefName,state`, or `gh stack` metadata when present) and
  show the stack: an ordered chain like `#101 → #102 → #103` next to the branch labels, the whole
  stack with each PR's state in the inspector, stacked branches grouped together in the sidebar,
  and optionally the stack's lanes highlighted in the graph.

## Other ideas mentioned so far

- Several repositories side by side in one window (multiple windows and tabs already work).
- AI grouping of commits into features based on their titles.
