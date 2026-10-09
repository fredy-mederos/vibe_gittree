# vibe_gittree

A fast, read-only explorer for git history. Two parts:

- **GitTree**, a native macOS app (SwiftUI + AppKit) for browsing any number of repositories, local
  or remote. This is the main project.
- **Web snapshot**, a script that turns one repository's history into a single shareable HTML page.

Ideas queued for later are in [TODO.md](TODO.md).

## GitTree for macOS

### Install and run

Requires macOS 15 or later and Xcode (built with Xcode 27).

```bash
scripts/install.sh
```

This builds an optimized copy and installs it into `~/Applications`, where Launchpad and Spotlight
find it, and installs the `gittree` command into `~/.local/bin`. Pass another folder to install the
app elsewhere, for example `scripts/install.sh /Applications`. To work on the app, open
`GitTree.xcodeproj` and press Run.

The first time GitTree reads a repository inside Documents, Desktop or Downloads, macOS asks for
permission to access that folder.

### What it does

- **Library of repositories** in the sidebar, each with its location underneath
  (`~/Documents/projects/acme`, or `github.com/owner` for cloned ones). Add folders from your Mac
  (File › Add Local Repository, ⌘O, or drag them in), every repository inside a folder (File › Add
  Repositories in Folder…, which looks four levels deep and skips `node_modules`, build folders and
  the like), or clone remote ones by URL (File › Clone Remote Repository, ⇧⌘O). The list shows the
  first eight with "Show All"; the filter at the bottom matches repositories too; the + menu sorts
  them by your own order (drag), name, or recently opened, and can group them by folder or host.
  Right-click › Pin to Top keeps favorites above the rest.
- **Switch quickly** with ⌘K: type part of a name or path, press Return. Without typing, it lists
  repositories most recently opened first. Right-click a repository for Open in New Tab or Open in
  New Window to see several at once.
- **Remote repositories** are cloned into GitTree's own storage as bare, blobless clones: commits
  and folder structure only, no file contents. They fetch automatically when opened (if the last
  fetch was over 10 minutes ago) and on Fetch (⇧⌘F).
- **Commit graph** of every branch, remote branch and tag, newest first, with colored lanes, branch
  and tag labels (a cloud marks a local branch in sync with its remote), and the checked-out commit
  ringed. Narrow it to local branches (⌘2), the current branch (⌘3) or a single branch (right-click
  › Show Only).
- **Live updates**: local repositories reload by themselves when you commit, check out or fetch in
  the terminal, keeping your scroll position and selection.
- **Search** (⌘F) across subjects, authors, hashes and branch names; Return or ⌘G for the next match,
  ⇧⌘G for the previous one.
- **Commit details** (the inspector on the right): full message, author and committer, links to the
  commit and its pull request on GitHub, GitLab or Bitbucket, ticket links, the first release tag
  that contains the commit, parents and children, the branches that contain it, and changed files.
- **Branches, remotes and tags** in the sidebar, grouped by folder (`feature/`, `release/`…) and by
  version for tags, newest first with their age. Click one to jump to it; double-click (or Return)
  to show only its history.
- **Changes**: click a file in the inspector to open its diff in its own window, with syntax colors
  (Swift, Kotlin, Java, JavaScript/TypeScript, Python, Go, Rust, C/Objective-C, Ruby, shell, JSON,
  YAML, XML/HTML, Markdown and more), a Side by Side toggle that puts the old and new file next to
  each other, a Whole File toggle, a link to the file on GitHub, and Copy Link.
- **Pull requests** (GitHub, through the `gh` command): an open pull request's number next to its
  branch in the graph and sidebar, with its checks (✓ passed, ✗ failed, clock running). Stacked pull
  requests (based on another open PR's branch) show their position, like `#8161 · 5/5`. The sidebar
  lists every stack in order, plus open, draft, recently merged and recently closed pull requests; the inspector shows the pull request
  that merged a commit, its review and checks, and the whole stack.
- **Jira** (Settings › Jira): profiles, each a Jira Cloud site and the account to use there. Every
  repository picks its profile or none, in Settings › Jira or in its Repository Settings, and new
  repositories start with the default profile. Repositories with a profile get a Ticket column with
  each commit's ticket status and fix version, and a Ticket section in the inspector with summary,
  type, assignee and fix version.
- **Highlight** (toolbar, with Jira connected): tint the commits of tickets that aren't Done, are in
  progress or to do (among the latest 500 commits), or of every ticket in a fix version (asked of
  Jira directly, so it covers tickets beyond what's on screen). The status bar steps through them.
- **Features**: the sidebar's Features section groups the latest commits (100 to 1,000) under the
  terms your team writes in commit messages: bracket tags like `[Search]` or `[Tech Debt]` and scope
  prefixes like `github-pr:`. A ticket takes its commits' most common term, so untagged commits of a
  tagged ticket follow it. Terms and assignments are remembered per repository; only work without a
  term goes to Apple's on-device model, which picks an existing term or suggests a new one (commit
  messages never leave the Mac). Each ticket is a feature named after its most descriptive commit.
  Select one to highlight its commits in the graph.
- **Activity** (toolbar calendar button or ⇧⌘A): a contribution grid with one square per day, shaded
  by commits, for the last 12 months or any year, filtered by branches and author. Hover a day to
  see its tickets (with their terms) and commits; click to keep it; click a commit to select it in
  the graph.
- **Deep links**: `gittree://open?repo=<path|remote URL|name>&commit=<sha>&path=<file>&line=<n>`
  opens the repository (adding it if needed), selects the commit and opens the file's diff scrolled
  to the line. The `gittree` command builds these links: `gittree <file>:<line>` finds the commit
  that last changed that line with `git blame`; `gittree <file>`, `gittree <commit>` and plain
  `gittree` work too; `--print` prints the link without opening the app.
- **Per-repository settings** (right-click › Repository Settings): display name, the Jira profile,
  the ticket keys to look for (`PROJ`, or several separated by commas; empty detects them from commit
  messages), an issue link such as `https://example.atlassian.net/browse/{key}` for ticket keys when
  tickets live somewhere else, and the regular expression that marks release tags (for example
  `^android-v[\d.]+$`).
- **Appearance**: Settings › General › Appearance picks Light, Dark or System.

GitTree never changes your repositories. The only git command that writes anything is `fetch`,
and only when you ask for it (or when a remote repository GitTree cloned itself is opened).

### How GitTree talks to GitHub and Jira

Both integrations are deliberately gentle, so scrolling or reloading can never turn into a storm of
requests:

- **GitHub**: two `gh pr list` calls per repository (recent pull requests, then reviews and checks
  of the open ones). At most one at a time, at most every five minutes (30 seconds when you press
  Fetch), each with a 30-second timeout; after a failure it waits 5 minutes, then longer.
- **Jira**: only tickets on screen, only once scrolling pauses, only ones not already cached; up to
  50 per request with bulk fetch (one request per screen), one request at a time across all
  profiles, at most 20 a minute. Statuses are cached on disk per site (`jira-cache.json`) and asked
  for again only after an hour, when they're on screen. Unknown tickets aren't asked about again for
  a day. A fix version's tickets are asked for once and reused for ten minutes. A rejected token
  stops that profile's requests until its settings change; timeouts and rate limits back off.
  Repository › Refresh Ticket Statuses asks again for what's on screen.

### Shortcuts

| Action | Keys |
| --- | --- |
| Switch to repository | ⌘K |
| Add local repository | ⌘O |
| Clone remote repository | ⇧⌘O |
| Find commits / next / previous | ⌘F / ⌘G / ⇧⌘G |
| All branches / local / current | ⌘1 / ⌘2 / ⌘3 |
| Go to HEAD | ⇧⌘H |
| Show activity calendar | ⇧⌘A |
| Fetch / reload | ⇧⌘F / ⌘R |
| Commit details for the selected row | Return or double-click |
| Repository settings | ⌥⌘, |

### Where things are stored

`~/Library/Application Support/GitTree/`: `library.json` (the repository list and per-repository
settings), `jira-profiles.json` (Jira sites and accounts, without tokens), `jira-cache.json` (ticket
statuses per site) and `Clones/<host>/<owner>/<name>.git` (remote repositories). Jira API tokens
are in the login keychain. Removing a remote repository from
GitTree deletes its clone; removing a local one never touches the folder.

### How it's built

```
GitTree/
  App/           app entry point and menu commands
  Git/           running git, parsing history, lane layout, diffs, clone, file watching, hosting links
  Integrations/  GitHub (gh), Jira (REST + keychain), feature grouping (Foundation Models)
  Model/         repository library, per-repository model, per-window state, sidebar tree, deep links
  Views/         window, sidebar, switcher, toolbar and status bar, inspector, diff window, sheets
  Views/Graph    the commit table (NSTableView) and its Core Graphics cells
Support/Info.plist   the gittree:// URL scheme (merged with Xcode's generated keys)
scripts/gittree      the deep-link command
```

- History comes from one `git log --branches --remotes --tags --date-order` plus `git for-each-ref`,
  parsed byte by byte into parallel arrays. On a 15,858-commit Android repository, loading,
  parsing and laying out the graph takes about half a second in a debug build.
- The lane layout is one top-to-bottom pass (the same algorithm as the web snapshot): a commit takes
  the longest-lived lane waiting for it, so mainlines like `develop` keep their column and color.
- The table is an `NSTableView`, which only creates views for visible rows, so very large histories
  scroll as smoothly as small ones. Graph cells draw their segments with Core Graphics.
- Layouts, search and "contained in" walks run off the main thread.

### Checking the UI from the command line

Debug builds accept launch arguments, and `scripts/snapshot.sh` launches the app with a throwaway
library and captures only its window:

```bash
scripts/snapshot.sh /tmp/gittree.png 6 -GTOpenRepository ~/code/some-repo -GTSearch "fix"
```

Arguments: `-GTOpenRepository <path>`, `-GTCloneURL <url>`, `-GTAddFolder <path>`, `-GTSearch <text>`,
`-GTScope local|head|refs/heads/<branch>`, `-GTAppearance dark|light`, `-GTShowSwitcher YES`,
`-GTGroupFeatures YES`, and `-GTJiraSite <url>` (with optional `-GTJiraEmail`/`-GTJiraToken`) to use
a Jira site without touching the keychain.

To try the Jira integration without real credentials, run the mock server and point a debug build
at it; it logs every request, which makes it easy to check that scrolling doesn't flood Jira:

```bash
python3 scripts/mock-jira.py 8899
scripts/snapshot.sh /tmp/gittree.png 8 -GTOpenRepository ~/code/some-repo -GTJiraSite http://127.0.0.1:8899
```

## Web snapshot

Builds a self-contained HTML commit graph (the original prototype), useful for sharing a snapshot.

```bash
python3 scripts/build.py ~/path/to/repo
```

This writes `dist/<repo-name>.html` (git-ignored, since it contains the repository's history).

| Option | What it does |
| --- | --- |
| `-o FILE` | Output path (default `dist/<repo-name>.html`) |
| `--title TEXT` | Page title (default `<repo-name> Commit Graph`) |
| `--jira URL` | Jira browse URL, e.g. `https://example.atlassian.net/browse/` |
| `--jira-prefixes A,B` | Ticket prefixes that get Jira links |
| `--tickets A,B` | Ticket prefixes to highlight (default: auto-detected from commit subjects) |
| `--release-tag REGEX` | Which tags count as production releases for "Shipped in" (default: plain version tags like `v2.4.1`) |

For example:

```bash
python3 scripts/build.py ~/code/acme-android -o dist/acme-android.html --title "Acme Android Commit Graph" --jira https://example.atlassian.net/browse/ --jira-prefixes PROJ --release-tag '^android-v[\d.]+$'
```

It's also published as a private claude.ai artifact.
The page's source is `src/template.html`, with `/*__TITLE__*/` and `/*__DATA__*/` placeholders.
