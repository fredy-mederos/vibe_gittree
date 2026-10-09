import Foundation
import Observation

/// The repositories the user added, saved as JSON in Application Support.
@MainActor @Observable final class RepositoryLibrary {
    static let shared = RepositoryLibrary()

    private(set) var repositories: [Repository] = []

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
        let repository = Repository(id: UUID(), name: name, kind: .local, path: path, remoteURL: nil, addedAt: Date())
        repositories.append(repository)
        save()
        return repository
    }

    func existingRemote(url: String) -> Repository? {
        let key = HostingService.normalizedKey(url)
        return repositories.first { $0.kind == .remote && $0.remoteURL.map(HostingService.normalizedKey) == key }
    }

    func addRemote(url: String, clonedTo directory: URL) -> Repository {
        if let existing = existingRemote(url: url) { return existing }
        let name = HostingService.repositoryName(from: url) ?? directory.deletingPathExtension().lastPathComponent
        let repository = Repository(
            id: UUID(), name: name, kind: .remote, path: directory.standardizedFileURL.path,
            remoteURL: url, addedAt: Date(), lastFetchedAt: Date()
        )
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

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        repositories.move(fromOffsets: source, toOffset: destination)
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
