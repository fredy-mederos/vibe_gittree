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
                 ? "GitTree's downloaded copy is deleted. The remote repository isn't affected."
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
        "Remove “\(state.repositoryPendingRemoval?.name ?? "")” from GitTree?"
    }
}

#if DEBUG
/// Launch arguments for testing without clicking through the UI:
/// `-GTOpenRepository <path>` adds and opens a local repository, `-GTCloneURL <url>` clones one,
/// `-GTAddFolder <path>` adds every repository in a folder, `-GTShowSwitcher YES` opens the ⌘K switcher,
/// `-GTSearch <text>` searches once a repository is open, `-GTScope local|head|<full ref name>`
/// narrows the graph, `-GTAppearance dark|light` forces an appearance, `-GTGroupFeatures YES` groups
/// features, `-GTHighlightFixVersion <version>` highlights one, `-GTShowActivity YES` opens the
/// calendar, `-GTRepositorySettings YES` and `-GTShowSettings YES` (with `-settingsTab jira`) open
/// the settings, `-GTSelect epic:<key>|release:<name>|pr:<number>|ticket:<key>` selects that row in
/// the sidebar once it's there (`first` for the first one, `open` for the newest open pull
/// request), and `-GTCompare <base>...<head>` opens the branch comparison. Elsewhere:
/// `-GTDataDirectory <folder>` (throwaway library, Jira profiles, test tokens and sidebar folds)
/// and `-GTJiraSite <url>` (every repository uses that Jira, e.g. `scripts/mock-jira.py`).
@MainActor enum DebugLaunch {
    private static var didRun = false
    private static var didOpenTab = false

    /// Where the sidebar keeps what's folded: the user's preferences, or for test runs a suite of
    /// their own that starts empty every launch.
    static let appStorage: UserDefaults = {
        guard UserDefaults.standard.string(forKey: "GTDataDirectory") != nil else { return .standard }
        let suite = "GitTree.test"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// `-GTDescribeJira <file>` (after `-GTDescribeAfter` seconds, 20 by default): what the Epics and
    /// Releases sections list, the highlight, and the selected pull request's timeline, as text.
    static func describeJira(_ state: WindowState, to path: String) {
        guard let graph = state.graph else { return }
        var lines = ["Selection: \(state.sidebarSelection.map { String(describing: $0) } ?? "none")"]
        if let epics = graph.epics {
            lines.append("Epics: \(epics.groups.count) groups, \(epics.ticketCount) tickets, \(epics.pending) pending, \(epics.notInJira) not in Jira")
            for group in epics.groups {
                let tickets = group.tickets.prefix(8).map { "\($0.key)×\($0.commits)" }.joined(separator: ", ")
                lines.append("  \(group.id.isEmpty ? "(no epic)" : group.id) \(group.epic?.summary ?? "") [\(group.epic?.status ?? "")]: \(group.tickets.count) tickets, \(group.commits) commits: \(tickets)")
            }
        }
        if let progress = graph.epicProgress { lines.append("Epic progress: \(progress)") }
        if let releases = graph.releases {
            lines.append("Releases used: " + releases.used.map { "\($0.name) (\($0.releaseDate ?? "-"), \($0.progressSummary ?? "-"))" }.joined(separator: " | "))
            lines.append("Releases other: " + releases.other.map(\.name).joined(separator: " | "))
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
        guard parts.count == 2 else { return nil }
        let value = parts[1]
        switch parts[0] {
        case "epic":
            guard graph.epicProgress == nil, let groups = graph.epics?.groups, !groups.isEmpty else { return nil }
            let key = value == "first" ? groups.first { !$0.id.isEmpty }?.id : groups.first { $0.id == value }?.id
            return key.map { .epic(id, $0) }
        case "release":
            let version = graph.releases?.all.first { value == "first" || $0.name == value }
            return version.map { .release(id, $0.id) }
        case "ticket":
            return .ticket(id, value, under: "")
        case "ref":
            return graph.commitGraph?.refs.first { $0.name == value }.map { .ref(id, $0.fullName) }
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

    /// `-GTCompare` opens one comparison, from the first window.
    static func claimCompare() -> Bool {
        defer { didOpenCompare = true }
        return !didOpenCompare
    }

    /// `-GTDescribeCompare <file>`: what a comparison found, as text.
    static func describeComparison(_ comparison: BranchComparison) {
        guard let path = UserDefaults.standard.string(forKey: "GTDescribeCompare") else { return }
        let graph = comparison.graph
        var lines = ["Base \(comparison.base.ref.name), head \(comparison.head.ref.name)"]
        if let mergeBase = comparison.mergeBase {
            lines.append("Merge base \(graph.ids[Int(mergeBase)].short) \(graph.subjects[Int(mergeBase)])")
        }
        for side in [comparison.base, comparison.head] {
            lines.append("Only on \(side.ref.name): \(side.commits.count) commits (\(side.nonMergeCount) not merges), "
                + "\(side.tickets.count) tickets, authors \(side.authors.prefix(3).map { "\($0.name)×\($0.commits)" }.joined(separator: ", "))")
            lines.append("  tickets: " + side.tickets.prefix(10).map { "\($0.key)×\($0.commits)" }.joined(separator: ", "))
            lines.append("  newest: " + side.commits.prefix(3).map { graph.subjects[Int($0)] }.joined(separator: " | "))
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
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
        switch defaults.string(forKey: "GTAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
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
        if let output = defaults.string(forKey: "GTDescribeJira") {
            Task {
                let after = defaults.integer(forKey: "GTDescribeAfter")
                try? await Task.sleep(for: .seconds(after > 0 ? after : 20))
                describeJira(state, to: output)
            }
        }
        if let text = defaults.string(forKey: "GTSelect") {
            Task {
                // Up to half a minute for Jira or GitHub to fill the sidebar.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let item = selection(text, in: state) {
                        state.sidebarSelection = item
                        break
                    }
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
