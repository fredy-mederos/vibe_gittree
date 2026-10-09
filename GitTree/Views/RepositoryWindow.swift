import SwiftUI

/// A window: the repository library and refs in the sidebar, the graph in the detail area, and the
/// selected commit in the inspector.
struct RepositoryWindow: View {
    @Binding var repositoryID: UUID?
    @State private var state = WindowState()
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
            "Couldn't Add Repository",
            isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .task {
            state.restore(requested: repositoryID)
            #if DEBUG
            DebugLaunch.runOnce(state: state)
            #endif
        }
        .onChange(of: state.repositoryID) { _, id in
            if repositoryID != id { repositoryID = id }
        }
        .onChange(of: repositoryID) { _, id in
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
/// `-GTSearch <text>` searches once a repository is open, `-GTScope local|head|<full ref name>`
/// narrows the graph, and `-GTAppearance dark|light` forces an appearance.
@MainActor enum DebugLaunch {
    private static var didRun = false

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
        let query = defaults.string(forKey: "GTSearch")
        let scope = defaults.string(forKey: "GTScope")
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
