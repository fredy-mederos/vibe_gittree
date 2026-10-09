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
find it. Pass another folder to install elsewhere, for example `scripts/install.sh /Applications`.
To work on the app, open `GitTree.xcodeproj` and press Run.

The first time GitTree reads a repository inside Documents, Desktop or Downloads, macOS asks for
permission to access that folder.

### What it does

- **Library of repositories** in the sidebar: add folders from your Mac (File › Add Local Repository,
  ⌘O, or drag them in) or clone remote ones by URL (File › Clone Remote Repository, ⇧⌘O). Click
  one to switch. Use "Open in New Window" to see several at once; windows can be merged into tabs.
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
  version for tags, newest first with their age. Filter them at the bottom of the sidebar.
- **Per-repository settings** (right-click › Repository Settings): display name, an issue link such
  as `https://example.atlassian.net/browse/{key}` for ticket keys found in commit messages, and the
  regular expression that marks release tags.

GitTree never changes your repositories. The only git command that writes anything is `fetch`,
and only when you ask for it (or when a remote repository GitTree cloned itself is opened).

### Shortcuts

| Action | Keys |
| --- | --- |
| Add local repository | ⌘O |
| Clone remote repository | ⇧⌘O |
| Find commits / next / previous | ⌘F / ⌘G / ⇧⌘G |
| All branches / local / current | ⌘1 / ⌘2 / ⌘3 |
| Go to HEAD | ⇧⌘H |
| Fetch / reload | ⇧⌘F / ⌘R |
| Commit details for the selected row | Return or double-click |
| Repository settings | ⌥⌘, |

### Where things are stored

`~/Library/Application Support/GitTree/`: `library.json` (the repository list and per-repository
settings) and `Clones/<host>/<owner>/<name>.git` (remote repositories). Removing a remote repository
from GitTree deletes its clone; removing a local one never touches the folder.

### How it's built

```
GitTree/
  App/        app entry point and menu commands
  Git/        running git, parsing history, lane layout, clone, file watching, hosting links
  Model/      repository library, per-repository model, per-window state, sidebar tree
  Views/      window, sidebar, toolbar and status bar, inspector, sheets
  Views/Graph the commit table (NSTableView) and its Core Graphics cells
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

Arguments: `-GTOpenRepository <path>`, `-GTCloneURL <url>`, `-GTSearch <text>`,
`-GTScope local|head|refs/heads/<branch>`, `-GTAppearance dark|light`.

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
