import AppKit
import Observation

enum SidebarItem: Hashable {
    case repository(UUID)
    /// A branch or tag of the window's repository, by full ref name.
    case ref(UUID, String)
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
    /// A URL the clone sheet should start with (used by "Clone…" with a prefilled address).
    var pendingCloneURL: String?
    var editingRepository: Repository?
    var repositoryPendingRemoval: Repository?
    var errorMessage: String?
    var refFilter = ""
    private(set) var searchFocusRequest = 0

    @ObservationIgnored private let library = RepositoryLibrary.shared
    /// Each repository's selection, scope and search in this window, kept while switching between them.
    @ObservationIgnored private var graphs: [UUID: GraphViewModel] = [:]

    var currentRepository: Repository? { library.repository(id: repositoryID) }

    var title: String { currentRepository?.name ?? "GitTree" }

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
            library.lastOpenedID = id
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
            graph?.reveal(refNamed: fullName)
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
        panel.prompt = "Add"
        panel.message = "Choose folders that contain git repositories."
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
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
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
        NSWorkspace.shared.activateFileViewerSelecting([repository.directory])
    }

    func openInTerminal(_ repository: Repository) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([repository.directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
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
