# CLAUDE.md

Personal side project: GitTree, a read-only git history explorer. The main part is a native macOS
app; a smaller web-snapshot generator lives alongside it. Read `README.md` first (it describes
what's shipped), and `TODO.md` for what's still open or was dropped.

## Native app (`GitTree/`, `GitTree.xcodeproj`)

- SwiftUI for the window, sidebar, toolbar, inspector and sheets; AppKit `NSTableView` for the
  commit list (`Views/Graph/`). Keep big lists in AppKit; SwiftUI lists get slow with tens of
  thousands of custom rows.
- The Xcode project uses a synchronized folder: any file added under `GitTree/` is compiled
  automatically. Don't add files to `project.pbxproj` by hand.
- Swift 5 language mode, macOS 15 deployment target. Models are `@MainActor @Observable`; heavy work
  (parsing, lane layout, search, containment walks) runs in `Task.detached`.
- Use native components and system colors (`NSColor.system*`, `.secondary`, materials) so light,
  dark and increased-contrast modes work without extra code.
- Read-only by design: never run git commands that change a user's repository. `fetch` is the only
  exception, and only on an explicit user action or for clones GitTree manages itself.
- Build: `xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Debug -derivedDataPath build/DerivedData build`.
  Keep the build free of warnings.
- Check UI changes visually with `scripts/snapshot.sh <out.png> <seconds> [debug launch args]`; it
  uses a throwaway library and captures only GitTree's window. Use test repositories outside
  ~/Documents (for example a `git clone --mirror` in a temp folder) so macOS doesn't show a folder
  permission prompt nobody can answer. Other windows: `swift scripts/window-id.swift GitTree <title>`.
  The debug launch arguments are listed above `DebugLaunch` in `Views/RepositoryWindow.swift`.
- Test runs share the installed app's preferences (same bundle id), so keep test state in the
  `-GTDataDirectory` folder: the library, Jira profiles and (in Debug test runs) Jira tokens live
  there. Don't `defaults write` settings, and don't pass `-sidebar.*Expanded`-style arguments: they
  override what the user clicks for that run and make the UI look broken.
- Screenshots only work while GitTree is frontmost; with Stage Manager, a window behind the user's
  current app captures as a thumbnail. If the user is working in another app, don't keep stealing
  focus: verify with logs (`mock-jira.py`) or debug output files instead.
- Install for daily use with `scripts/install.sh` (Release build into ~/Applications, plus the
  `gittree` command into ~/.local/bin).
- Network integrations must stay gentle (the user asked for this explicitly): one request at a
  time per service, caching, minimum intervals, timeouts and backoff, and never trigger a request
  from a redraw. GitHub goes through `gh` in `Integrations/GitHub.swift` (rate-limited in
  `RepositoryModel.refreshPullRequests`); Jira goes through `JiraStore` (visible rows only, batched
  bulk fetch, on-disk cache per site, queued per profile). Each repository picks a Jira profile (a
  site and account, token in the keychain) or none. Test Jira with `scripts/mock-jira.py`, which
  logs every request; `-GTJiraSite http://127.0.0.1:<port>` points every repository at it.
- Apple's on-device model (Foundation Models) is used only to sort commits into features. The user
  decided against generated text (summaries, release notes); don't add it back. Keep it behind
  `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`, with a plain fallback; commit
  messages never leave the Mac.
- The user's global `~/.claude/CLAUDE.md` tells every Claude session to use `gittree <file>:<line>`;
  keep the command's arguments and link format backward compatible.

## Web snapshot (`src/template.html`, `scripts/build.py`)

- Keep it dependency-free: Python 3 standard library for the script, plain JS/CSS in the page.
- `src/template.html` must keep the `/*__TITLE__*/` and `/*__DATA__*/` markers exactly once each.
- Nothing repo-specific goes in the template; per-repo settings are build options that reach the
  page through the data object `D`.
- After changing the page, check its script parses with `node --check` and rebuild a real repo.
- `dist/` holds built pages with real commit history and is git-ignored. Don't commit it.
- The snapshot is published as a private claude.ai artifact. Republish to
  that URL rather than creating a new artifact.

## Git

- This repository's remote is `github.com/fredy-mederos/vibe_gittree` (private). Commits use the
  repo-local identity `Fredy Mederos <fmfredd@gmail.com>`; don't change it to the work address.
