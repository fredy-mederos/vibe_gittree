import Foundation

/// `gittree://open?repo=<path, remote URL or name>&commit=<sha>&path=<file>&line=<n>`
///
/// Every parameter but `repo` is optional. `line` is a line number in the file as of that commit
/// (what `git blame --porcelain` reports as the original line).
struct DeepLink: Equatable {
    var repository: String
    var commit: String?
    var path: String?
    var line: Int?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "gittree",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let repository = value("repo") else { return nil }
        self.repository = repository
        commit = value("commit")
        path = value("path")
        line = value("line").flatMap(Int.init)
    }

    /// Builds a link, for example to copy from the inspector.
    static func url(repository: String, commit: String? = nil, path: String? = nil, line: Int? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "gittree"
        components.host = "open"
        var items = [URLQueryItem(name: "repo", value: repository)]
        if let commit { items.append(URLQueryItem(name: "commit", value: commit)) }
        if let path { items.append(URLQueryItem(name: "path", value: path)) }
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        components.queryItems = items
        return components.url
    }
}

extension RepositoryLibrary {
    enum Resolution {
        case found(Repository)
        /// A remote that isn't cloned yet; the user confirms the clone.
        case needsClone(String)
        case notFound(String)
    }

    /// Finds the repository a link names: a path (or any folder inside a working copy), a remote
    /// URL matched against clones and local repositories' origins, or a name. A path in a worktree
    /// finds the repository the worktree belongs to, whose history it shares, unless the worktree
    /// was added on its own.
    func resolve(_ spec: String) async -> Resolution {
        let expanded = (spec as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
            // The innermost: a worktree added on its own over the repository it's kept in.
            let containing = repositories.filter { path == $0.path || path.hasPrefix($0.path + "/") }
            if let known = containing.max(by: { $0.path.count < $1.path.count }) {
                return .found(known)
            }
            // A worktree kept elsewhere (`~/.codex/worktrees/…`): the repository it belongs to, or
            // another of its worktrees that was added; the main one is added when none was.
            let worktrees = await worktreeFolders(at: path)
            for folder in worktrees {
                if let known = repositories.first(where: { $0.path == folder }) { return .found(known) }
            }
            if let main = worktrees.first, let added = try? await addLocal(at: URL(fileURLWithPath: main)) {
                return .found(added)
            }
            if let added = try? await addLocal(at: URL(fileURLWithPath: path)) {
                return .found(added)
            }
            return .notFound("No git repository at \(spec).")
        }
        if HostingService.split(spec) != nil {
            let key = HostingService.normalizedKey(spec)
            let matches = repositories.filter {
                $0.remoteURL.map(HostingService.normalizedKey) == key || $0.originURL.map(HostingService.normalizedKey) == key
            }
            // Prefer a working copy on this Mac over GitTree's own clone.
            if let match = matches.first(where: { $0.kind == .local }) ?? matches.first {
                return .found(match)
            }
            return .needsClone(spec)
        }
        let byName = repositories.filter { $0.name.caseInsensitiveCompare(spec) == .orderedSame }
        if let match = byName.max(by: { $0.recency < $1.recency }) {
            return .found(match)
        }
        return .notFound("No repository named “\(spec)” in Vibe GitTree.")
    }

    /// The folders of every worktree of the repository at a path, the main one (or the bare
    /// repository) first; none when there's no repository there.
    private func worktreeFolders(at path: String) async -> [String] {
        guard let data = try? await Git.run(["worktree", "list", "--porcelain", "-z"], in: URL(fileURLWithPath: path), allowFailure: true)
        else { return [] }
        return Worktree.listings(data).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
    }
}
