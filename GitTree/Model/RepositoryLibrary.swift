import Foundation
import Observation

enum RepositorySort: String, CaseIterable, Identifiable {
    case manual, name, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual Order"
        case .name: "Name"
        case .recent: "Recently Opened"
        }
    }
}

enum RepositoryGrouping: String, CaseIterable, Identifiable {
    case none, folder, host

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .folder: "Folder"
        case .host: "Host"
        }
    }
}

/// The repositories the user added, saved as JSON in Application Support.
@MainActor @Observable final class RepositoryLibrary {
    static let shared = RepositoryLibrary()

    private(set) var repositories: [Repository] = []

    var sort: RepositorySort = RepositorySort(rawValue: UserDefaults.standard.string(forKey: "repositorySort") ?? "") ?? .manual {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "repositorySort") }
    }

    var grouping: RepositoryGrouping = RepositoryGrouping(rawValue: UserDefaults.standard.string(forKey: "repositoryGrouping") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: "repositoryGrouping") }
    }

    /// Unpinned repositories in the chosen order (pinned ones are listed separately, on top).
    var sortedRepositories: [Repository] {
        let unpinned = repositories.filter { $0.pinnedAt == nil }
        switch sort {
        case .manual: return unpinned
        case .name: return unpinned.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .recent: return unpinned.sorted { $0.recency > $1.recency }
        }
    }

    var pinnedRepositories: [Repository] {
        repositories.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[index].pinnedAt = pinned ? Date() : nil
        save()
    }

    var byRecency: [Repository] {
        repositories.sorted { $0.recency > $1.recency }
    }

    enum AddError: LocalizedError {
        case notARepository(String)

        var errorDescription: String? {
            switch self {
            case .notARepository(let name): "“\(name)” isn't a git repository. Choose the folder that contains the .git folder."
            }
        }
    }

    private init() {
        load()
        assignMigratedJiraProfile()
    }

    /// Repositories that used the single Jira connection of earlier versions keep using it, now as a
    /// profile: those without an issue link, or with one on the same site.
    private func assignMigratedJiraProfile() {
        let profiles = JiraProfiles.load().profiles  // migrates the old settings, once
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: JiraProfiles.pendingAssignmentKey) else { return }
        defaults.removeObject(forKey: JiraProfiles.pendingAssignmentKey)
        guard let id = UUID(uuidString: pending), let host = profiles.first(where: { $0.id == id })?.host else { return }
        for index in repositories.indices where repositories[index].jiraProfileID == nil {
            let template = repositories[index].issueURLTemplate?.trimmingCharacters(in: .whitespaces) ?? ""
            let templateHost = URL(string: template.replacingOccurrences(of: "{key}", with: "KEY-1"))?.host
            if template.isEmpty || templateHost == host {
                repositories[index].jiraProfileID = id
            }
        }
        save()
    }

    /// New repositories start with the default Jira profile from Settings (or none).
    private var defaultJiraProfileID: UUID? {
        let id = JiraStore.shared.defaultProfileID
        return JiraStore.shared.profile(id: id) == nil ? nil : id
    }

    func setJiraProfile(_ profileID: UUID?, for id: UUID) {
        guard var repository = repository(id: id) else { return }
        repository.jiraProfileID = profileID
        update(repository)
    }

    func repository(id: UUID?) -> Repository? {
        guard let id else { return nil }
        return repositories.first { $0.id == id }
    }

    var lastOpenedID: UUID? {
        get { UserDefaults.standard.string(forKey: "lastOpenedRepository").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastOpenedRepository") }
    }

    /// Adds a working copy or bare repository. Picking a subfolder adds the repository it belongs to.
    func addLocal(at url: URL) async throws -> Repository {
        let root: String
        if let top = try? await Git.string(["rev-parse", "--show-toplevel"], in: url), !top.isEmpty {
            root = top
        } else {
            let isBare = try? await Git.string(["rev-parse", "--is-bare-repository"], in: url)
            guard isBare == "true", let gitDirectory = try? await Git.string(["rev-parse", "--absolute-git-dir"], in: url) else {
                throw AddError.notARepository(url.lastPathComponent)
            }
            root = gitDirectory
        }
        let path = URL(fileURLWithPath: root).standardizedFileURL.path
        if let existing = repositories.first(where: { $0.kind == .local && $0.path == path }) {
            return existing
        }
        var name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasSuffix(".git"), name.count > 4 { name.removeLast(4) }
        let origin = try? await Git.string(["remote", "get-url", "origin"], in: URL(fileURLWithPath: path))
        var repository = Repository(id: UUID(), name: name, kind: .local, path: path, remoteURL: nil, addedAt: Date())
        repository.originURL = origin?.isEmpty == false ? origin : nil
        repository.jiraProfileID = defaultJiraProfileID
        repositories.append(repository)
        save()
        return repository
    }

    /// Adds every git repository found in a folder (up to four levels deep).
    func addRepositories(in folder: URL) async -> [Repository] {
        let candidates = await Task.detached(priority: .userInitiated) {
            RepositoryScanner.repositories(in: folder)
        }.value
        var added: [Repository] = []
        for candidate in candidates {
            if let repository = try? await addLocal(at: candidate), !added.contains(where: { $0.id == repository.id }) {
                added.append(repository)
            }
        }
        return added
    }

    func markOpened(_ id: UUID) {
        lastOpenedID = id
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories[index].lastOpenedAt = Date()
        save()
    }

    /// Remembers a local repository's origin once the model has read it, for links that name the remote.
    func recordOrigin(_ url: String, for id: UUID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }), repositories[index].originURL != url else { return }
        repositories[index].originURL = url
        save()
    }

    func existingRemote(url: String) -> Repository? {
        let key = HostingService.normalizedKey(url)
        return repositories.first { $0.kind == .remote && $0.remoteURL.map(HostingService.normalizedKey) == key }
    }

    func addRemote(url: String, clonedTo directory: URL) -> Repository {
        if let existing = existingRemote(url: url) { return existing }
        let name = HostingService.repositoryName(from: url) ?? directory.deletingPathExtension().lastPathComponent
        var repository = Repository(
            id: UUID(), name: name, kind: .remote, path: directory.standardizedFileURL.path,
            remoteURL: url, addedAt: Date(), lastFetchedAt: Date()
        )
        repository.jiraProfileID = defaultJiraProfileID
        repositories.append(repository)
        save()
        return repository
    }

    /// `Clones/<host>/<owner>/<name>.git`
    func cloneDestination(for url: String) -> URL {
        var components: [String]
        if let parts = HostingService.split(url) {
            components = [parts.host] + parts.path.split(separator: "/").map(String.init)
        } else {
            components = [URL(fileURLWithPath: url).lastPathComponent]
        }
        components = components.map(Self.sanitized).filter { !$0.isEmpty }
        if var last = components.popLast() {
            if !last.hasSuffix(".git") { last += ".git" }
            components.append(last)
        }
        var destination = AppPaths.clonesDirectory
        for component in components { destination.appendPathComponent(component, isDirectory: true) }
        return destination
    }

    func update(_ repository: Repository) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        repositories[index] = repository
        save()
        RepositoryModelStore.shared.existingModel(id: repository.id)?.update(repository: repository)
    }

    /// Remembers a comparison for Repository › Recent Comparisons: newest first, ten at most.
    func recordComparison(base: String, head: String, for id: UUID) {
        guard var repository = repository(id: id) else { return }
        let comparison = RecentComparison(base: base, head: head)
        var recent = repository.recentComparisons ?? []
        guard recent.first != comparison else { return }
        recent.removeAll { $0 == comparison }
        recent.insert(comparison, at: 0)
        repository.recentComparisons = Array(recent.prefix(10))
        update(repository)
    }

    func clearRecentComparisons(for id: UUID) {
        guard var repository = repository(id: id) else { return }
        repository.recentComparisons = nil
        update(repository)
    }

    func markFetched(_ id: UUID) {
        guard var repository = self.repository(id: id) else { return }
        repository.lastFetchedAt = Date()
        update(repository)
    }

    /// Removes a repository from the library. For remote ones this also deletes GitTree's clone;
    /// local folders are never touched.
    func remove(_ repository: Repository) {
        repositories.removeAll { $0.id == repository.id }
        save()
        RepositoryModelStore.shared.discard(id: repository.id)
        if lastOpenedID == repository.id { lastOpenedID = nil }
        guard repository.kind == .remote else { return }
        let clones = AppPaths.clonesDirectory.standardizedFileURL.path + "/"
        let path = URL(fileURLWithPath: repository.path).standardizedFileURL.path
        if path.hasPrefix(clones) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Reorders the unpinned repositories (the manual order the sidebar shows).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var unpinned = repositories.filter { $0.pinnedAt == nil }
        unpinned.move(fromOffsets: source, toOffset: destination)
        repositories = repositories.filter { $0.pinnedAt != nil } + unpinned
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        repositories = (try? decoder.decode([Repository].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: AppPaths.dataDirectory, withIntermediateDirectories: true)
            try encoder.encode(repositories).write(to: AppPaths.libraryFile, options: .atomic)
        } catch {
            NSLog("GitTree: couldn't save the repository library: \(error.localizedDescription)")
        }
    }

    private static func sanitized(_ component: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var result = String(component.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        while result.hasPrefix(".") { result.removeFirst() }
        return result
    }
}
