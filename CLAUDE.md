# CLAUDE.md

Personal side project: Vibe GitTree, a git history explorer (read-only unless the user allows commits
and stashes), as a native macOS app. It was
called GitTree until 1.2.0: the code, Xcode project, bundle id, data folder, `gittree` command and
`gittree://` links keep that name; what people see (app name, menus, text, DMG) says Vibe GitTree. Read
`README.md` first (it describes what's shipped), and `TODO.md` for what's still open or was dropped.

## Native app (`GitTree/`, `GitTree.xcodeproj`)

- SwiftUI for the window, sidebar, toolbar, inspector and sheets; AppKit `NSTableView` for the
  commit list (`Views/Graph/`). Keep big lists in AppKit; SwiftUI lists get slow with tens of
  thousands of custom rows.
- The Xcode project uses a synchronized folder: any file added under `GitTree/` is compiled
  automatically. Don't add files to `project.pbxproj` by hand.
- Swift 5 language mode, macOS 15 deployment target. Models are `@MainActor @Observable`; heavy work
  (parsing, lane layout, search, containment walks) runs in `Task.detached`.
- Use native components and system colors (`NSColor.system*`, `.secondary`, materials) so light,
  dark and increased-contrast modes work without extra code. Colored text uses `NSColor.readable`
  (system colors are made for symbols and fills; green or orange text on a light background is
  under 2:1), and colors in sidebar rows go through `foregroundStyle(_:selected:)`, which turns
  them white on a selected row's accent color. Check selected rows in both appearances.
- SwiftUI ignores the inspector's ideal width and resets it to its narrowest when the window's
  content changes; `InspectorWidthKeeper` (`Views/WindowSupport.swift`) keeps the width the user
  drags to, through AppKit.
- In split-view columns (the sidebar, the details, the diff window's list), whatever is pinned
  outside a scrolling list (a `safeAreaInset`) must keep a height that doesn't depend on the width:
  no wrapping text with `.fixedSize(horizontal: false, vertical: true)` there (use `lineLimit`, with
  `reservesSpace`). Otherwise zooming the window (a double-click on its title bar) loops AppKit's
  constraint passes until it stops the app. `-GTZoom <seconds>` zooms every window in and out, to check.
- Read-only unless the user allows changes: never run git commands that change a user's repository,
  except `fetch` (on an explicit user action, or for clones Vibe GitTree manages itself) and, with
  Settings › General › Allow commits and stashes on (off by default), staging, unstaging, committing
  and stashing through `Git/WorkingTreeActions.swift`, each on an explicit click (dropping a stash
  after a confirmation). Nothing may discard uncommitted work (no `checkout --`, `reset --hard`,
  `clean`). Looking stays read-only: `git status` runs with `GIT_OPTIONAL_LOCKS=0` (in
  `Git.environment`), so it never rewrites the index. Paths passed to those commands are marked
  `:(literal)` (`Git.pathspecInput`); `--literal-pathspecs` would also break the `:/` that `git stash`
  uses inside, leaving new files behind.
- Build: `xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Debug -derivedDataPath build/DerivedData build`.
  Keep the build free of warnings.
- Check UI changes visually with `scripts/snapshot.sh <out.png> <seconds> [debug launch args]`; it
  uses a throwaway library and captures only Vibe GitTree's window. Use test repositories outside
  ~/Documents (for example a `git clone --mirror` in a temp folder) so macOS doesn't show a folder
  permission prompt nobody can answer. Other windows: `swift scripts/window-id.swift "Vibe GitTree" <title>`.
  `scripts/snapshot-rows.sh` captures the window once per sidebar row `-GTSelect` names (selected
  rows in light and dark mode). The debug launch arguments are listed above `DebugLaunch` in
  `Views/RepositoryWindow.swift`.
- Test runs share the installed app's preferences (same bundle id), so keep test state in the
  `-GTDataDirectory` folder: the library, Jira profiles and (in Debug test runs) Jira tokens live
  there. Don't `defaults write` settings, and don't pass `-sidebar.*Expanded`-style arguments: they
  override what the user clicks for that run and make the UI look broken.
- Screenshots only work while Vibe GitTree is frontmost; with Stage Manager, a window behind the user's
  current app captures as a thumbnail. `snapshot.sh` quits every running Vibe GitTree, the user's
  installed copy too; when that one is running, launch the Debug build yourself with `open -n`. When
  the shell can't capture the screen at all (`screencapture` says it could not create an image),
  `-GTSnapshot <folder>` has the app capture its own windows, coming to the front for a moment (so
  not over and over while the user works).
- Try staging, committing and stashing only in throwaway clones (`git clone` into a temp folder),
  with `-GTAllowChanges YES`, `-GTPerform "<step>;<step>"` and `-GTDescribeChanges <file>`, and
  compare the result with the same steps as plain git commands. If the user is working in another app, don't keep stealing
  focus: verify with logs (`mock-jira.py`) or debug output files instead (`-GTDescribeJira`,
  `-GTDescribeCompare`, with the app launched by `open -g -n` so it stays in the background).
- Install for daily use with `scripts/install.sh` (Release build into ~/Applications, or the folder
  passed to it, plus the `gittree` command into ~/.local/bin).
- **"Prepare a release"** is the user's shorthand for: commit and push any pending work first (so
  the build isn't marked with `+`), then run `scripts/install.sh /Applications`, which builds
  Release, replaces /Applications/Vibe GitTree.app (and a GitTree.app from before the rename, quitting the running copy) and opens it. Report the
  version, build number and commit it was built from (Settings › General shows them too). It's
  only about Vibe GitTree; it doesn't mean tagging or publishing anything.
- **Publishing a release** (a signed, notarized `VibeGitTree.dmg` on GitHub) is the `release-vibe-gittree`
  skill in `skills/` (linked from `.claude/skills`): version (`scripts/version.sh`), Developer ID
  build and notarization (`scripts/release.sh`), tag and `gh release create` with
  `scripts/release-notes.sh`. Only when asked to release or publish; "prepare a release" never does.
- Installed copies check GitHub for the newest release (`App/AppUpdater.swift`): at launch (at most
  hourly), daily, and from Vibe GitTree › Check for Updates… and Settings › General, which shows the same
  About and Updates rows as the user's other apps. `App/UpdateCheck.swift` is the same file in Vibe
  Notepad and Vibe Clean: keep them identical. Debug builds check only when asked
  (`-GTCheckForUpdates YES`, or `-GTUpdateRepository owner/name` to try another repository's releases).
- Network integrations must stay gentle (the user asked for this explicitly): one request at a
  time per service, caching, minimum intervals, timeouts and backoff, and never trigger a request
  from a redraw. GitHub goes through `gh` in `Integrations/GitHub.swift` (rate-limited in
  `RepositoryModel.refreshPullRequests`; pull request timelines on selection, and the default
  branch that picks the graph's main line at most daily in `refreshDefaultBranch`, through the same
  gate); Jira goes through `JiraStore` (every request through its gate and per-minute budget:
  visible rows first, then recent tickets the Epics section hasn't seen, batched bulk fetch; fix
  versions and ticket lists cached; the progress of epics and of fix versions with a Definition of
  Done comes from one paged query each, at most hourly; on-disk cache per profile). Each repository picks a Jira
  profile (a site and account, token in the keychain) or none. Test Jira with
  `scripts/mock-jira.py`, which logs every request; `-GTJiraSite http://127.0.0.1:<port>` points
  every repository at it.
- Apple's on-device model (Foundation Models) is used only to sort commits into features, in the
  Features section, which is off by default (Settings › General) since the Epics and Releases
  sections group the same work by Jira; the user will say where else the model could help. The user
  decided against generated text (summaries, release notes); don't add it back. Keep it behind
  `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`, with a plain fallback; commit
  messages never leave the Mac.
- The user's global `~/.claude/CLAUDE.md` tells every Claude session to use `gittree <file>:<line>`;
  keep the command's arguments and link format backward compatible.

## Translations

- The app is in English plus 20 languages (the most spoken ones macOS runs in, listed in
  `scripts/localization.py`), all in the String Catalog `GitTree/Localizable.xcstrings`. Any
  change that adds or changes text the app shows ships with its translations in the same commit:
  follow the `localize-vibe-gittree` skill in `skills/` (sync, export, translate with subagents on a
  lighter model, `haiku` for a few strings or `sonnet` per language for many, import, then
  `scripts/localization.py check`, which must pass). Don't translate with the main model.
- SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`, a `LocalizedStringKey` parameter) are
  localized as they are. Text that becomes a `String` first (models' messages, enum titles, a view's
  `title: String`, tooltips built in code, AppKit menus, alerts and column titles) goes through
  `String(localized:)`. Data (names, paths, commit messages, git's output) stays as it is.
- Whole sentences with interpolations, never English pieces joined together. Counts are `Int`
  interpolations (`"\(count) commits"`) with the English singular added by
  `scripts/localization.py plural`; one count per string. Pull request numbers, years and line
  numbers go in as `String(number)`, or they're grouped (`#8,161`). A word used in two senses gets
  its own key (`String(localized: "Commit.button", defaultValue: "Commit", comment: …)`), and a
  `comment:` explains anything a translator could misread. The skill has the details.
- Check the UI in another language with `-AppleLanguages "(de)"` among the debug launch arguments
  (`ar` for right-to-left, `de` for long words).

## Git

- This repository's remote is `github.com/fredy-mederos/vibe_gittree`, public (or about to be).
  Commits use the repo-local identity `Fredy Mederos <fmfredd@gmail.com>`; don't change it to the
  work address.
- Nothing about the user's employer goes into the repository: not its name, GitHub org, Jira site,
  ticket keys, feature codenames or real ticket and fix version names, in files, samples, mock data
  or commit messages. Use neutral samples (Acme, `PROJ-123`, `[Search]`, `example.atlassian.net`).
- Issues are welcome; pull requests aren't accepted (see `CONTRIBUTING.md`).
- The web snapshot generator (`scripts/build.py`, `src/template.html`) was removed; it's still in
  the history. `dist/` may hold pages it built, with real commit history: it stays git-ignored,
  never commit it.
