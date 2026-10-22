import AppKit
import Observation

enum SidebarItem: Hashable {
    case repository(UUID)
    /// A branch or tag of the window's repository, by full ref name.
    case ref(UUID, String)
    /// A group from the Features section.
    case feature(UUID, String)
    /// A pull request by number: selecting it goes to its merge commit (merged) or its branch.
    case pullRequest(UUID, Int)
    /// An epic from the Epics section, by key; empty for the tickets without an epic.
    case epic(UUID, String)
    /// An unreleased fix version from the Releases section, by its Jira id.
    case release(UUID, String)
    /// A ticket listed under an epic or a fix version: its key, and the row it's listed under
    /// (`epic:<key>` or `release:<id>`), so the same ticket in two places is two rows.
    case ticket(UUID, String, under: String)
    /// The uncommitted changes of the window's repository.
    case workingTree(UUID)
    /// A stash, by its commit's hash (its `stash@{n}` changes as others come and go).
    case stash(UUID, String)
    /// Another worktree of the window's repository, by its folder.
    case worktree(UUID, String)
}

/// Per-window state: which repository it shows, what's selected in the sidebar, and the window's sheets.
@MainActor @Observable final class WindowState {
    private(set) var repositoryID: UUID?
    private(set) var graph: GraphViewModel?

    var sidebarSelection: SidebarItem? {
        didSet { if sidebarSelection != oldValue { sidebarSelectionChanged() } }
    }

    var showInspector = true
    var isCloneSheetPresented = false
    var isSwitcherPresented = false
    var isFixVersionPromptPresented = false
    /// Shows every repository in the sidebar instead of the first few.
    var showsAllRepositories = false
    /// A short confirmation shown at the bottom of the sidebar, like "Added 12 repositories".
    var notice: String?
    /// A URL the clone sheet should start with (used by "Clone…" with a prefilled address).
    var pendingCloneURL: String?
    var editingRepository: Repository?
    var repositoryPendingRemoval: Repository?
    var errorTitle = String(localized: "Couldn't Add Repository")
    var errorMessage: String?
    /// A diff the window should open in its own window (set by deep links).
    var diffRequest: DiffTarget?
    /// A link waiting for its repository to finish cloning.
    @ObservationIgnored private var pendingDeepLink: DeepLink?
    var refFilter = ""
    private(set) var searchFocusRequest = 0

    @ObservationIgnored private let library = RepositoryLibrary.shared
    /// The window this state belongs to, for adding tabs to it.
    @ObservationIgnored weak var window: NSWindow?

    /// Every window's state, to tell which repositories are on screen.
    private static var windows: [WeakWindowState] = []

    init() {
        Self.windows.removeAll { $0.state == nil }
        Self.windows.append(WeakWindowState(state: self))
    }

    /// Whether some window shows this repository. Only those load pull requests on their own.
    static func isShowing(_ id: UUID) -> Bool {
        windows.contains { $0.state?.repositoryID == id }
    }
    /// Each repository's selection, scope and search in this window, kept while switching between them.
    @ObservationIgnored private var graphs: [UUID: GraphViewModel] = [:]

    var currentRepository: Repository? { library.repository(id: repositoryID) }

    var title: String { currentRepository?.name ?? "Vibe GitTree" }

    var subtitle: String {
        guard let repository = currentRepository else { return "" }
        if let branch = graph?.commitGraph?.headBranch, repository.kind == .local { return branch }
        if repository.kind == .remote { return repository.remoteURL ?? "" }
        return ""
    }

    /// Picks what a new or restored window shows.
    func restore(requested: UUID?) {
        guard repositoryID == nil else { return }
        if let requested, library.repository(id: requested) != nil {
            open(requested)
        } else if let last = library.lastOpenedID, library.repository(id: last) != nil {
            open(last)
        } else if let first = library.repositories.first {
            open(first.id)
        }
    }

    func open(_ id: UUID?) {
        guard let id, let repository = library.repository(id: id) else {
            repositoryID = nil
            graph = nil
            return
        }
        if id != repositoryID || graph == nil {
            repositoryID = id
            let model = RepositoryModelStore.shared.model(for: repository)
            if let cached = graphs[id], cached.model === model {
                graph = cached
            } else {
                let fresh = GraphViewModel(model: model)
                graphs[id] = fresh
                graph = fresh
            }
            model.loadIfNeeded()
            model.refreshPullRequests()
            model.refreshDefaultBranch()
            // Files that changed while no window showed it are looked at now.
            model.refreshWorkingTreeIfStale()
            // Back to a repository shown before: its Epics and Releases may be due for a refresh.
            graph?.loadJiraOverview()
            library.markOpened(id)
        }
        if sidebarSelection != .repository(id) {
            sidebarSelection = .repository(id)
        }
    }

    private func sidebarSelectionChanged() {
        switch sidebarSelection {
        case .repository(let id):
            open(id)
        case .ref(let id, let fullName):
            if id != repositoryID { open(id) }
            graph?.clearSidebarHighlight()
            graph?.reveal(refNamed: fullName)
        case .feature(let id, let featureID):
            if id != repositoryID { open(id) }
            graph?.showFeature(id: featureID)
        case .epic(let id, let key):
            if id != repositoryID { open(id) }
            graph?.showEpic(key)
        case .release(let id, let versionID):
            if id != repositoryID { open(id) }
            graph?.showRelease(versionID)
        case .ticket(let id, let key, _):
            if id != repositoryID { open(id) }
            graph?.showTicket(key)
        case .workingTree(let id):
            if id != repositoryID { open(id) }
            graph?.clearSidebarHighlight()
            graph?.selectWorkingTree()
            showInspector = true
        case .stash(let id, let hash):
            if id != repositoryID { open(id) }
            graph?.clearSidebarHighlight()
            if let stash = ObjectID(hex: hash) { graph?.showStash(stash) }
            showInspector = true
        case .worktree(let id, let path):
            if id != repositoryID { open(id) }
            graph?.clearSidebarHighlight()
            graph?.reveal(worktreeAt: path)
        case .pullRequest(let id, let number):
            if id != repositoryID { open(id) }
            graph?.clearSidebarHighlight()
            guard let graph, let commitGraph = graph.commitGraph, let index = graph.model.pullRequests,
                  let pullRequest = index.byNumber[number] else { break }
            // Its timeline shows under it in the sidebar.
            graph.model.loadTimeline(for: pullRequest)
            if pullRequest.state == .merged, let merge = pullRequest.mergeCommit, let commit = commitGraph.indexByID[merge] {
                graph.select(commit)
            } else if let ref = pullRequest.ref(in: commitGraph) {
                graph.reveal(refNamed: ref.fullName)
                // An open pull request lights up its commits, and a stacked one the whole stack's.
                guard pullRequest.state == .open else { break }
                let stack = index.stack(containing: pullRequest)
                if stack.isEmpty {
                    graph.highlightPullRequests([pullRequest], title: "#\(pullRequest.number) \(pullRequest.title)",
                                                systemImage: "arrow.triangle.pull")
                } else {
                    let numbers = stack.map { "#\($0.number)" }.joined(separator: " → ")
                    graph.highlightPullRequests(stack, title: String(localized: "Stack on \(stack[0].base): \(numbers)", comment: "Stacked pull requests: the branch they're based on, then their numbers"),
                                                systemImage: "square.stack.3d.up")
                }
            }
        case nil:
            break
        }
    }

    // MARK: Adding and removing

    func addLocalRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Button that adds the chosen folders")
        panel.message = String(localized: "Choose folders that contain git repositories.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in self?.addLocal(urls: urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func addLocal(urls: [URL]) {
        Task {
            var added: Repository?
            var failures: [String] = []
            for url in urls {
                do {
                    added = try await library.addLocal(at: url)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if let added { open(added.id) }
            if !failures.isEmpty { showError(String(localized: "Couldn't Add Repository"), failures.joined(separator: "\n")) }
        }
    }

    func addRepositoriesInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add Repositories")
        panel.message = String(localized: "Choose a folder. Vibe GitTree adds every git repository inside it, up to four levels deep.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notice = String(localized: "Looking for repositories…")
                let before = Set(self.library.repositories.map(\.id))
                let found = await self.library.addRepositories(in: folder)
                let new = found.filter { !before.contains($0.id) }
                switch (found.count, new.count) {
                case (0, _): self.notice = String(localized: "No git repositories found in “\(folder.lastPathComponent)”.")
                case (_, 0): self.notice = String(localized: "All \(found.count) repositories were already in the list.")
                default: self.notice = String(localized: "Added \(new.count) repositories.")
                }
                if self.repositoryID == nil, let first = new.first { self.open(first.id) }
                try? await Task.sleep(for: .seconds(4))
                self.notice = nil
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func cloneRemoteRepository(prefilledURL: String? = nil) {
        pendingCloneURL = prefilledURL
        isCloneSheetPresented = true
    }

    func remove(_ repository: Repository) {
        library.remove(repository)
        graphs[repository.id] = nil
        guard repository.id == repositoryID else { return }
        repositoryID = nil
        graph = nil
        sidebarSelection = nil
        if let first = library.repositories.first { open(first.id) }
    }

    // MARK: Deep links

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            showError(String(localized: "Can't Open Link"),
                      String(localized: "Vibe GitTree doesn't understand \(url.absoluteString). Links look like gittree://open?repo=<path>&commit=<sha>."))
            return
        }
        Task { await handle(link) }
    }

    /// After a clone started by a link finishes, continue to the commit and file it named.
    func resumePendingDeepLink() {
        guard let link = pendingDeepLink else { return }
        pendingDeepLink = nil
        Task { await handle(link) }
    }

    private func handle(_ link: DeepLink) async {
        switch await library.resolve(link.repository) {
        case .notFound(let message):
            showError(String(localized: "Can't Open Link"), message)
        case .needsClone(let url):
            pendingDeepLink = link
            cloneRemoteRepository(prefilledURL: url)
        case .found(let repository):
            open(repository.id)
            guard let commit = link.commit else { return }
            guard let graph, await waitForHistory(of: graph), let commitGraph = graph.commitGraph else { return }
            guard let index = commitGraph.index(matching: commit) else {
                showError(String(localized: "Commit Not Found"),
                          String(localized: "\(String(commit.prefix(12))) isn't in \(repository.name)'s history. Fetch the repository and try the link again."))
                return
            }
            graph.select(index)
            showInspector = true
            if let path = link.path {
                diffRequest = DiffTarget(repositoryID: repository.id, commit: commitGraph.ids[Int(index)].hex, path: path, line: link.line)
            }
        }
    }

    /// Waits up to 20 seconds for the repository's history to load.
    private func waitForHistory(of graph: GraphViewModel) async -> Bool {
        for _ in 0..<200 {
            if graph.layout != nil { return true }
            if case .failed = graph.model.status { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func showError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    // MARK: Actions

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func fetch(_ repository: Repository? = nil) {
        guard let repository = repository ?? currentRepository else { return }
        let model = RepositoryModelStore.shared.model(for: repository)
        Task { await model.fetch() }
    }

    func showInFinder(_ repository: Repository) {
        showInFinder(folder: repository.directory)
    }

    func showInFinder(folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func openInTerminal(_ repository: Repository) {
        openInTerminal(folder: repository.directory)
    }

    func openInTerminal(folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func hosting(for repository: Repository) -> HostingService? {
        RepositoryModelStore.shared.existingModel(id: repository.id)?.hosting
            ?? repository.remoteURL.flatMap(HostingService.init(remoteURL:))
    }

    func openOnWeb(_ repository: Repository) {
        guard let url = hosting(for: repository)?.webURL else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct WeakWindowState {
    weak var state: WindowState?
}
