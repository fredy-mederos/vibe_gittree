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
        .task {
            state.restore(requested: target?.repositoryID)
            #if DEBUG
            DebugLaunch.runOnce(state: state)
            if UserDefaults.standard.bool(forKey: "GTShowActivity") {
                try? await Task.sleep(for: .seconds(2))
                if let id = state.repositoryID { openWindow(id: "activity", value: id) }
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
/// the settings. Elsewhere: `-GTDataDirectory <folder>` (throwaway library, Jira profiles and test
/// tokens) and `-GTJiraSite <url>` (every repository uses that Jira, e.g. `scripts/mock-jira.py`).
@MainActor enum DebugLaunch {
    private static var didRun = false
    private static var didOpenTab = false

    /// `-GTOpenInNewTab <file>`: the first window opens its repository in a new tab, like the
    /// sidebar's Open in New Tab, then writes the windows and their tabs to the file.
    static func claimNewTab() -> Bool {
        defer { didOpenTab = true }
        return !didOpenTab
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
