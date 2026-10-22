import SwiftUI

/// A window: the repository library and refs in the sidebar, the graph in the detail area, and the
/// selected commit in the inspector.
struct RepositoryWindow: View {
    @Binding var target: WindowTarget?
    @State private var state = WindowState()
    @Environment(\.openWindow) private var openWindow
    private let library = RepositoryLibrary.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .darkerPanelInDarkMode()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 440)
        } detail: {
            detail
        }
        #if DEBUG
        // Test runs fold and unfold the sidebar in their own preferences, never the user's.
        .defaultAppStorage(DebugLaunch.appStorage)
        #endif
        .navigationTitle(state.title)
        .navigationSubtitle(state.subtitle)
        .focusedSceneValue(\.windowState, state)
        .sheet(isPresented: $state.isCloneSheetPresented) {
            CloneSheet(state: state)
        }
        .sheet(isPresented: $state.isSwitcherPresented) {
            RepositorySwitcher(state: state)
        }
        .background(WindowAccessor { window in
            state.window = window
            WindowTabbing.windowAppeared(window)
        })
        .sheet(item: $state.editingRepository) { repository in
            RepositorySettingsSheet(repository: repository)
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { state.repositoryPendingRemoval != nil },
                set: { if !$0 { state.repositoryPendingRemoval = nil } }
            ),
            presenting: state.repositoryPendingRemoval
        ) { repository in
            Button("Remove", role: .destructive) { state.remove(repository) }
        } message: { repository in
            Text(repository.kind == .remote
                 ? "Vibe GitTree's downloaded copy is deleted. The remote repository isn't affected."
                 : "The folder on your Mac isn't changed.")
        }
        .alert(
            state.errorTitle,
            isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        // gittree:// links go to an existing window instead of opening a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { state.handle($0) }
        .onChange(of: state.diffRequest) { _, request in
            guard let request else { return }
            openWindow(id: "diff", value: request)
            state.diffRequest = nil
        }
        // A commit clicked in the activity calendar.
        .onReceive(NotificationCenter.default.publisher(for: .gitTreeRevealCommit)) { notification in
            guard let id = notification.userInfo?["repository"] as? UUID, id == state.repositoryID,
                  let hex = notification.userInfo?["commit"] as? String,
                  let graph = state.graph, let index = graph.commitGraph?.index(matching: hex) else { return }
            graph.select(index)
            state.showInspector = true
        }
        // One side of a branch comparison.
        .onReceive(NotificationCenter.default.publisher(for: .gitTreeHighlightCommits)) { notification in
            guard let id = notification.userInfo?["repository"] as? UUID, id == state.repositoryID,
                  let commits = notification.userInfo?["commits"] as? [String], let graph = state.graph else { return }
            graph.highlightCommits(Set(commits.compactMap { ObjectID(hex: $0) }),
                                   title: notification.userInfo?["title"] as? String ?? "Compared commits",
                                   systemImage: "arrow.left.arrow.right")
        }
        .task {
            state.restore(requested: target?.repositoryID)
            #if DEBUG
            DebugLaunch.runOnce(state: state)
            if UserDefaults.standard.bool(forKey: "GTShowActivity") {
                try? await Task.sleep(for: .seconds(2))
                if let id = state.repositoryID { openWindow(id: "activity", value: id) }
            }
            if let spec = UserDefaults.standard.string(forKey: "GTCompare"), DebugLaunch.claimCompare() {
                // `base...head`, by branch or tag name, once the history is read.
                for _ in 0..<60 where state.graph?.commitGraph == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if let id = state.repositoryID, let graph = state.graph?.commitGraph {
                    let names = spec.components(separatedBy: "...")
                    func fullName(_ name: String?) -> String? { graph.refs.first { $0.name == name }?.fullName }
                    openWindow(id: "compare", value: CompareTarget(repositoryID: id, base: fullName(names.first),
                                                                   head: fullName(names.count > 1 ? names[1] : nil)))
                }
            }
            if DebugLaunch.claimChangeWindows() {
                await DebugLaunch.openChangeWindows(state: state) { openWindow(id: "diff", value: $0) }
            }
            if let output = UserDefaults.standard.string(forKey: "GTOpenInNewTab"), DebugLaunch.claimNewTab() {
                try? await Task.sleep(for: .seconds(3))
                if let id = state.repositoryID {
                    WindowTabbing.openNextWindowAsTab(in: state.window)
                    openWindow(id: "repository", value: WindowTarget.opening(id))
                }
                try? await Task.sleep(for: .seconds(3))
                DebugLaunch.describeWindows(to: output)
            }
            #endif
        }
        // The window remembers what it shows (for state restoration), keeping its own identity.
        .onChange(of: state.repositoryID) { _, id in
            if target?.repositoryID != id {
                target = WindowTarget(repositoryID: id, window: target?.window ?? UUID())
            }
        }
        .onChange(of: target?.repositoryID) { _, id in
            if let id, id != state.repositoryID { state.open(id) }
        }
    }

    @ViewBuilder private var detail: some View {
        if let graph = state.graph {
            GraphDetailView(graph: graph, state: state)
        } else if library.repositories.isEmpty {
            ContentUnavailableView {
                Label("No Repositories", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Add a repository from your Mac, or clone one from a URL to explore its history.")
            } actions: {
                Button("Add Local Repository…") { state.addLocalRepository() }
                Button("Clone Remote Repository…") { state.cloneRemoteRepository() }
            }
        } else {
            ContentUnavailableView("Select a Repository", systemImage: "sidebar.left",
                                   description: Text("Choose a repository in the sidebar."))
        }
    }

    private var removalTitle: String {
        "Remove “\(state.repositoryPendingRemoval?.name ?? "")” from Vibe GitTree?"
    }
}

#if DEBUG
/// Launch arguments for testing without clicking through the UI:
/// `-GTOpenRepository <path>` adds and opens a local repository, `-GTCloneURL <url>` clones one,
/// `-GTAddFolder <path>` adds every repository in a folder, `-GTShowSwitcher YES` opens the ⌘K switcher,
/// `-GTSearch <text>` searches once a repository is open, `-GTScope local|head|<full ref name>`
/// narrows the graph, `-GTAppearance dark|light` forces an appearance, `-GTGroupFeatures YES` shows
/// the Features section and groups features, `-GTHighlightFixVersion <version>` highlights one,
/// `-GTShowActivity YES` opens the calendar, `-GTRepositorySettings YES` and `-GTShowSettings YES`
/// (with `-settingsTab jira`) open the settings, `-GTSelect epic:<key>|release:<name>|pr:<number>|ticket:<key>|ref:<name>`
/// selects that row in the sidebar once it's there (`first` for the first one, `open` for the newest
/// open pull request; several, comma-separated, one after another, with `-GTSelectMarkers <folder>`
/// for a script to capture each), `-GTRefresh releases|release|epics` refreshes those sections or the
/// selected fix version after `-GTRefreshAfter` seconds (10 by default), and
/// `-GTCompare <base>...<head>` opens the branch comparison, `-GTAllowChanges YES` turns on staging,
/// committing and stashing for the run, `-GTSelect changes|stash:<n>` selects the uncommitted changes
/// or a stash, and `-GTDescribeChanges <file>` (after `-GTDescribeAfter` seconds) writes the working
/// tree's status, the stashes and what the details show, `-GTPerform <steps>` runs changes one
/// after another (`stage:<path>`, `unstage:<path>`, `stageAll`, `unstageAll`, `commit:<message>`,
/// `stash:<message>`, `stashStaged:<message>`, `apply:<n>`, `pop:<n>`, `drop:<n>`, separated by
/// `;`, with `-GTAllowChanges YES`), `-GTZoom <seconds>` zooms every window in and out a few times
/// (as double-clicking a title bar does), and `-GTSnapshot <folder>` (after
/// `-GTSnapshotAfter` seconds, 10 by default) has every window draw itself into a PNG there, for
/// checks where `screencapture` isn't allowed. Elsewhere:
/// `-GTDataDirectory <folder>` (throwaway library, Jira profiles, test tokens and sidebar folds),
/// `-GTJiraSite <url>` (every repository uses that Jira, e.g. `scripts/mock-jira.py`), and
/// `-GTCheckForUpdates YES` or `-GTUpdateRepository <owner/name>` (`AppUpdater`).
@MainActor enum DebugLaunch {
    private static var didRun = false
    private static var didOpenTab = false

    /// Where the sidebar keeps what's folded and the details their width: the user's preferences,
    /// or for test runs a suite of their own that starts empty every launch (with the Features
    /// section when -GTGroupFeatures asks).
    static let appStorage: UserDefaults = {
        guard UserDefaults.standard.string(forKey: "GTDataDirectory") != nil else { return .standard }
        let suite = "GitTree.test"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.set(UserDefaults.standard.bool(forKey: "GTGroupFeatures"), forKey: AppSettings.groupsFeaturesKey)
        defaults.set(UserDefaults.standard.bool(forKey: "GTAllowChanges"), forKey: AppSettings.allowsChangesKey)
        return defaults
    }()

    /// `-GTDescribeChanges <file>`: the working tree's status, the stashes, the graph's row for
    /// uncommitted changes and what the details show, as text.
    static func describeChanges(_ state: WindowState, to path: String) {
        guard let graph = state.graph else { return }
        let model = graph.model
        var lines = ["Selection: \(state.sidebarSelection.map { String(describing: $0) } ?? "none")"]
        lines.append("Details: " + (graph.selectedStash.map { "stash \($0.short)" }
            ?? (graph.selectsWorkingTree ? "uncommitted changes" : graph.selectedCommit.map { "commit \($0)" } ?? "nothing")))
        lines.append("Allows changes: \(model.allowsChanges)")
        if let status = model.workingTree {
            lines.append("Branch: \(status.branch ?? "detached") at \(status.head?.prefix(8) ?? "-"), upstream \(status.upstream ?? "-") +\(status.ahead) -\(status.behind)")
            lines.append("Changes: \(status.total) (\(status.summary.isEmpty ? "clean" : status.summary))\(status.operation.map { ", \($0.rawValue) under way" } ?? "")")
            for change in status.changes.prefix(30) {
                lines.append("  [\(change.staged ?? ".")\(change.unstaged ?? ".")] \(change.path)\(change.oldPath.map { " ← \($0)" } ?? "")")
            }
        } else {
            lines.append("Changes: \(model.hasWorkingTree ? "not looked at yet" : "no working tree")")
        }
        if let layout = graph.layout {
            lines.append("Graph: \(layout.rowCount) rows, uncommitted row: \(layout.workingRow.map { "lane \($0.column)" } ?? "none")")
        }
        lines.append("Stashes: \(model.stashes.count)")
        for stash in model.stashes {
            lines.append("  \(stash.name) \(stash.title) [\(stash.branch ?? "-")] untracked: \(stash.untracked != nil)")
        }
        if let progress = model.changeInProgress { lines.append("In progress: \(progress)") }
        if let error = model.changeError { lines.append("Error: \(error)") }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `-GTDescribeJira <file>` (after `-GTDescribeAfter` seconds, 20 by default): what the Epics and
    /// Releases sections list, the highlight, and the selected pull request's timeline, as text.
    static func describeJira(_ state: WindowState, to path: String) {
        guard let graph = state.graph else { return }
        var lines = ["Selection: \(state.sidebarSelection.map { String(describing: $0) } ?? "none")"]
        if let epics = graph.epics {
            lines.append("Epics: \(epics.groups.count) groups, \(epics.ticketCount) tickets, \(epics.pending) pending, \(epics.notInJira) not in Jira, \(epics.liveEpics) live epics left out")
            for group in epics.groups {
                let tickets = group.tickets.prefix(8).map { "\($0.key)×\($0.commits)" }.joined(separator: ", ")
                let progress = group.progress.map { " (\($0.done) of \($0.total) done, \($0.inProgress) in progress)" } ?? ""
                lines.append("  \(group.id.isEmpty ? "(no epic)" : group.id) \(group.epic?.summary ?? "") [\(group.epic?.status ?? "")]\(progress): \(group.tickets.count) tickets, \(group.commits) commits: \(tickets)")
            }
        }
        if let progress = graph.epicProgress { lines.append("Epic progress: \(progress)") }
        if let releases = graph.releases {
            lines.append("Releases used: " + releases.used.map { "\($0.name) (\($0.releaseDate ?? "-"), \($0.progressSummary ?? "-"))" }.joined(separator: " | "))
            lines.append("Releases other: " + releases.other.map(\.name).joined(separator: " | "))
            lines.append("Releases recent: " + releases.recent.map { "\($0.name) (\($0.releaseDate ?? "-"))" }.joined(separator: " | "))
        }
        for (id, tickets) in graph.releaseTickets.sorted(by: { $0.key < $1.key }) {
            lines.append("Release \(id) tickets: " + tickets.map { "\($0.key)×\($0.commits)" }.joined(separator: ", "))
        }
        if let highlight = graph.highlight {
            lines.append("Highlight: \(highlight.title) [\(highlight.systemImage)] \(graph.matchRows.count) rows, current \(graph.currentMatch.map(String.init) ?? "-")")
        }
        if let pullRequests = graph.model.pullRequests {
            let numbers = pullRequests.all.map(\.number).sorted(by: >)
            lines.append("Pull requests: \(numbers.count), open \(pullRequests.all.filter { $0.state == .open }.count), "
                + "newest \(numbers.prefix(3).map(String.init).joined(separator: ", "))")
        }
        if let progress = graph.highlightProgress { lines.append("Highlight progress: \(progress)") }
        if let note = graph.highlightNote { lines.append("Highlight note: \(note)") }
        if case .pullRequest(_, let number)? = state.sidebarSelection {
            if let timeline = graph.model.timelines[number] {
                lines.append("Timeline #\(number): \(timeline.summary)")
                for event in timeline.events {
                    lines.append("  \(event.date.formatted(.iso8601)) \(event.title)")
                }
            } else {
                lines.append("Timeline #\(number): \(graph.model.timelineProblems[number] ?? "not loaded")")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The sidebar row `-GTSelect` names, once the repository has loaded it.
    static func selection(_ text: String, in state: WindowState) -> SidebarItem? {
        guard let id = state.repositoryID, let graph = state.graph else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return nil }
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "epic":
            guard graph.epicProgress == nil, let groups = graph.epics?.groups, !groups.isEmpty else { return nil }
            let key = value == "first" ? groups.first { !$0.id.isEmpty }?.id : groups.first { $0.id == value }?.id
            return key.map { .epic(id, $0) }
        case "release":
            let version = graph.releases?.all.first { value == "first" || $0.name == value }
            return version.map { .release(id, $0.id) }
        case "ticket":
            // The row of an opened fix version or an epic that lists it, when there's one.
            if let release = graph.releaseTickets.first(where: { $0.value.contains { $0.key == value } })?.key {
                return .ticket(id, value, under: "release:\(release)")
            }
            if let epic = graph.epics?.groups.first(where: { $0.tickets.contains { $0.key == value } })?.id {
                return .ticket(id, value, under: "epic:\(epic)")
            }
            return .ticket(id, value, under: "")
        case "ref":
            return graph.commitGraph?.refs.first { $0.name == value }.map { .ref(id, $0.fullName) }
        case "changes":
            return graph.model.workingTree?.isClean == false ? .workingTree(id) : nil
        case "stash":
            guard let index = Int(value), index < graph.model.stashes.count else { return nil }
            return .stash(id, graph.model.stashes[index].id.hex)
        case "pr":
            guard let pullRequests = graph.model.pullRequests else { return nil }
            let stacked = Set(pullRequests.stacks.flatMap { $0.map(\.number) })
            let number = value == "open"
                ? pullRequests.all.filter { $0.state == .open && !$0.isDraft && !stacked.contains($0.number) }.map(\.number).max()
                : Int(value)
            return number.map { .pullRequest(id, $0) }
        default:
            return nil
        }
    }

    /// `-GTOpenInNewTab <file>`: the first window opens its repository in a new tab, like the
    /// sidebar's Open in New Tab, then writes the windows and their tabs to the file.
    static func claimNewTab() -> Bool {
        defer { didOpenTab = true }
        return !didOpenTab
    }

    private static var didOpenCompare = false
    private static var didOpenChangeWindows = false

    static func claimChangeWindows() -> Bool {
        defer { didOpenChangeWindows = true }
        return !didOpenChangeWindows
    }

    /// `-GTCompareTab commits|tickets|files|authors`: the tab a comparison opens on.
    static var compareTab: String? { UserDefaults.standard.string(forKey: "GTCompareTab") }

    /// `-GTOpenChanges uncommitted|<commit>|<base>...<head>` opens every file of those changes,
    /// one after another; `-GTOpenDiff <staged|unstaged|untracked|commit>:<path>` opens a file's
    /// uncommitted changes, or its changes in a commit (a hash or a branch or tag name).
    static func openChanges(_ spec: String, repositoryID: UUID, graph: CommitGraph) -> DiffTarget? {
        if spec == "uncommitted" {
            return DiffTarget(repositoryID: repositoryID, commit: "", path: "", uncommitted: .unstaged, allFiles: true, title: "Uncommitted Changes")
        }
        let names = spec.components(separatedBy: "...")
        func hash(_ name: String) -> String? {
            (graph.refs.first { $0.name == name }?.commit ?? graph.index(matching: name)).map { graph.ids[Int($0)].hex }
        }
        if names.count == 1, let commit = hash(spec) {
            return DiffTarget(repositoryID: repositoryID, commit: commit, path: "", allFiles: true, title: spec)
        }
        guard names.count == 2, let base = hash(names[0]), let head = hash(names[1]) else { return nil }
        return DiffTarget(repositoryID: repositoryID, commit: head, path: "", base: base, allFiles: true,
                          title: "\(names[1]) since \(names[0])")
    }

    static func openChangeWindows(state: WindowState, diff: (DiffTarget) -> Void) async {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "GTOpenChanges") != nil || defaults.string(forKey: "GTOpenDiff") != nil else { return }
        for _ in 0..<60 where state.graph?.commitGraph == nil || state.graph?.model.workingTree == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let id = state.repositoryID, let graph = state.graph?.commitGraph else { return }
        if let spec = defaults.string(forKey: "GTOpenChanges"), let target = openChanges(spec, repositoryID: id, graph: graph) {
            diff(target)
        }
        if let spec = defaults.string(forKey: "GTOpenDiff"), let colon = spec.firstIndex(of: ":") {
            let kind = String(spec[..<colon])
            let path = String(spec[spec.index(after: colon)...])
            if let side = UncommittedSide(rawValue: kind) {
                diff(DiffTarget(repositoryID: id, commit: "", path: path, uncommitted: side))
            } else if let commit = graph.refs.first(where: { $0.name == kind })?.commit ?? graph.index(matching: kind) {
                diff(DiffTarget(repositoryID: id, commit: graph.ids[Int(commit)].hex, path: path))
            }
        }
    }

    /// `-GTCompare` opens one comparison, from the first window.
    static func claimCompare() -> Bool {
        defer { didOpenCompare = true }
        return !didOpenCompare
    }

    /// `-GTDescribeCompare <file>`: what a comparison found, as text.
    static func describeComparison(_ comparison: BranchComparison) {
        guard let path = UserDefaults.standard.string(forKey: "GTDescribeCompare") else { return }
        let graph = comparison.graph
        var lines = ["Base \(comparison.base.point.name), head \(comparison.head.point.name)"]
        if let mergeBase = comparison.mergeBase {
            lines.append("Merge base \(graph.ids[Int(mergeBase)].short) \(graph.subjects[Int(mergeBase)])")
        }
        for side in [comparison.base, comparison.head] {
            lines.append("Only on \(side.point.name): \(side.commits.count) commits (\(side.nonMergeCount) not merges), "
                + "\(side.tickets.count) tickets, authors \(side.authors.prefix(3).map { "\($0.name)×\($0.commits)" }.joined(separator: ", "))")
            lines.append("  tickets: " + side.tickets.prefix(10).map { "\($0.key)×\($0.commits)" }.joined(separator: ", "))
            lines.append("  newest: " + side.commits.prefix(3).map { graph.subjects[Int($0)] }.joined(separator: " | "))
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Every visible window captured into `<folder>/<title>.png` by the app itself: an app may
    /// capture its own windows without the screen recording permission `screencapture` needs. The
    /// window server's call for it is looked up at run time; the SDK no longer offers it.
    static func snapshotWindows(to folder: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (number, window) in NSApp.windows.filter(\.isVisible).enumerated() {
            // Just this window (option 8), without its shadow (image option 1).
            guard let image = createImage(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { continue }
            let name = window.title.isEmpty ? "window-\(number)" : window.title.replacingOccurrences(of: "/", with: "-")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "\(name).png"))
        }
    }

    /// `-GTPerform`: changes as the details' buttons make them, one after another, each once the
    /// working tree has been looked at again. Failures land in the model's `changeError`.
    static func perform(_ steps: String, state: WindowState) async {
        for _ in 0..<60 where state.graph?.model.workingTree == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        for step in steps.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let model = state.graph?.model, let status = model.workingTree else { return }
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            let stash = Int(value).flatMap { $0 < model.stashes.count ? model.stashes[$0] : nil }
            NSLog("GitTree: performing %@", step)
            switch parts.first {
            case "stage": await model.stage(status.changes.filter { $0.path == value })
            case "unstage": await model.unstage(status.changes.filter { $0.path == value })
            case "stageAll": await model.stageAll()
            case "unstageAll": await model.unstageAll()
            case "commit": _ = await model.commit(message: value)
            case "stash": _ = await model.stash(nil, message: value)
            case "stashStaged": _ = await model.stash(status.staged, message: value)
            case "apply": if let stash { _ = await model.applyStash(stash) }
            case "pop": if let stash { _ = await model.popStash(stash) }
            case "drop": if let stash { _ = await model.dropStash(stash) }
            default: NSLog("GitTree: unknown step %@", step)
            }
            if let error = model.changeError { NSLog("GitTree: %@ failed: %@", step, error) }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    static func describeWindows(to path: String) {
        let lines = NSApp.windows.filter { $0.isVisible || $0.tabbedWindows != nil }.map { window in
            "\(window.title) | tabs: \(window.tabbedWindows?.map(\.title) ?? [])"
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func runOnce(state: WindowState) {
        guard !didRun else { return }
        didRun = true
        let defaults = UserDefaults.standard
        // -GTAppearance is applied at launch, with the appearance setting it stands in for.
        if let path = defaults.string(forKey: "GTOpenRepository") {
            state.addLocal(urls: [URL(fileURLWithPath: path)])
        }
        if let url = defaults.string(forKey: "GTCloneURL") {
            state.cloneRemoteRepository(prefilledURL: url)
        }
        if let folder = defaults.string(forKey: "GTAddFolder") {
            Task {
                let added = await RepositoryLibrary.shared.addRepositories(in: URL(fileURLWithPath: folder))
                if state.repositoryID == nil, let first = added.first { state.open(first.id) }
            }
        }
        if defaults.bool(forKey: "GTRepositorySettings") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                state.editingRepository = state.currentRepository
            }
        }
        if defaults.bool(forKey: "GTShowSettings") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        if defaults.bool(forKey: "GTShowSwitcher") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                state.isSwitcherPresented = true
            }
        }
        let query = defaults.string(forKey: "GTSearch")
        let scope = defaults.string(forKey: "GTScope")
        if let fixVersion = defaults.string(forKey: "GTHighlightFixVersion") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                state.graph?.highlightFixVersion(fixVersion)
            }
        }
        if defaults.bool(forKey: "GTGroupFeatures") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                state.graph?.analyzeFeatures()
            }
        }
        if let what = defaults.string(forKey: "GTRefresh") {
            Task {
                let after = defaults.integer(forKey: "GTRefreshAfter")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 10))
                guard let graph = state.graph else { return }
                let release: String? = if case .release(_, let id)? = state.sidebarSelection { id } else { nil }
                switch what {
                case "releases": graph.refreshReleases(open: Set([release].compactMap { $0 }))
                case "release": if let release { graph.refreshRelease(release) }
                case "epics": graph.refreshJiraOverview()
                default: break
                }
            }
        }
        if let output = defaults.string(forKey: "GTDescribeJira") {
            Task {
                let after = defaults.integer(forKey: "GTDescribeAfter")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 20))
                describeJira(state, to: output)
            }
        }
        if let folder = defaults.string(forKey: "GTSnapshot") {
            Task {
                let after = defaults.integer(forKey: "GTSnapshotAfter")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 10))
                // In front only for the capture: with Stage Manager a window behind captures as a thumbnail.
                NSApp.activate()
                for window in NSApp.windows where window.isVisible { window.orderFrontRegardless() }
                try? await Task.sleep(for: .seconds(1.5))
                snapshotWindows(to: folder)
            }
        }
        if defaults.object(forKey: "GTZoom") != nil {
            Task {
                let after = defaults.integer(forKey: "GTZoom")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 10))
                // Every window zoomed in and out a few times, as a double-click on its title bar does.
                for round in 0..<4 {
                    for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                        NSLog("GitTree: zooming %@ (round %d)", window.title, round)
                        window.zoom(nil)
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                NSLog("GitTree: zoomed every window")
            }
        }
        if let steps = defaults.string(forKey: "GTPerform") {
            Task { await perform(steps, state: state) }
        }
        if let output = defaults.string(forKey: "GTDescribeChanges") {
            Task {
                let after = defaults.integer(forKey: "GTDescribeAfter")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 20))
                describeChanges(state, to: output)
            }
        }
        if let text = defaults.string(forKey: "GTSelect") {
            Task {
                let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let markers = defaults.string(forKey: "GTSelectMarkers").map { URL(fileURLWithPath: $0) }
                for (number, text) in items.enumerated() {
                    // Up to half a minute for Jira or GitHub to fill the sidebar.
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if let item = selection(text, in: state) {
                            state.sidebarSelection = item
                            break
                        }
                    }
                    guard number < items.count - 1 else { break }
                    try? await Task.sleep(for: .seconds(2))
                    guard let markers else { continue }
                    // `<n>.selected` once the row is drawn; the next row waits for `<n>.captured`.
                    try? Data().write(to: markers.appending(path: "\(number + 1).selected"))
                    for _ in 0..<40 where !FileManager.default.fileExists(atPath: markers.appending(path: "\(number + 1).captured").path) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                if let markers {
                    try? await Task.sleep(for: .seconds(2))
                    try? Data().write(to: markers.appending(path: "\(items.count).selected"))
                }
            }
        }
        guard query != nil || scope != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            switch scope {
            case "local": state.graph?.scope = .local
            case "head": state.graph?.scope = .head
            case let name? where name.hasPrefix("refs/"): state.graph?.scope = .ref(name)
            default: break
            }
            if let query { state.graph?.searchText = query }
        }
    }
}
#endif
