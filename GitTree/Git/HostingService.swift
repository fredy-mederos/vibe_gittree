import Foundation

/// Where a repository is hosted, so commits, pull requests and branches can link to the web.
struct HostingService: Hashable, Sendable {
    enum Provider: Sendable {
        case github, gitlab, bitbucket
    }

    let provider: Provider
    /// `https://github.com/owner/repo`
    let webURL: URL
    let host: String
    let path: String

    var displayName: String {
        switch provider {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        }
    }

    init?(remoteURL: String) {
        guard let parts = Self.split(remoteURL) else { return nil }
        var host = parts.host.lowercased()
        if host == "ssh.github.com" { host = "github.com" }
        let provider: Provider
        if host.contains("github") {
            provider = .github
        } else if host.contains("gitlab") {
            provider = .gitlab
        } else if host.contains("bitbucket") {
            provider = .bitbucket
        } else {
            return nil
        }
        let path = Self.trimmedPath(parts.path)
        guard !path.isEmpty, let url = URL(string: "https://\(host)/\(path)") else { return nil }
        self.provider = provider
        self.webURL = url
        self.host = host
        self.path = path
    }

    func commitURL(_ hash: String) -> URL {
        switch provider {
        case .github: webURL.appending(path: "commit/\(hash)")
        case .gitlab: webURL.appending(path: "-/commit/\(hash)")
        case .bitbucket: webURL.appending(path: "commits/\(hash)")
        }
    }

    func pullRequestURL(_ number: Int) -> URL {
        switch provider {
        case .github: webURL.appending(path: "pull/\(number)")
        case .gitlab: webURL.appending(path: "-/merge_requests/\(number)")
        case .bitbucket: webURL.appending(path: "pull-requests/\(number)")
        }
    }

    func branchURL(_ branch: String) -> URL {
        switch provider {
        case .github: webURL.appending(path: "tree/\(branch)")
        case .gitlab: webURL.appending(path: "-/tree/\(branch)")
        case .bitbucket: webURL.appending(path: "branch/\(branch)")
        }
    }

    func tagURL(_ tag: String) -> URL {
        switch provider {
        case .github: webURL.appending(path: "releases/tag/\(tag)")
        case .gitlab: webURL.appending(path: "-/tags/\(tag)")
        case .bitbucket: webURL.appending(path: "src/\(tag)")
        }
    }

    /// Pull requests whose source is `branch`.
    func pullRequestsURL(forBranch branch: String) -> URL? {
        switch provider {
        case .github:
            var components = URLComponents(url: webURL.appending(path: "pulls"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "q", value: "is:pr head:\(branch)")]
            return components?.url
        case .gitlab:
            var components = URLComponents(url: webURL.appending(path: "-/merge_requests"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "source_branch", value: branch), URLQueryItem(name: "state", value: "all")]
            return components?.url
        case .bitbucket:
            return nil
        }
    }

    /// Splits `https://host/path`, `ssh://user@host:port/path` and scp-like `user@host:path` remotes.
    static func split(_ remote: String) -> (host: String, path: String)? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeEnd = text.range(of: "://") {
            let rest = text[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = rest[..<slash]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
            let path = String(rest[rest.index(after: slash)...])
            guard !authority.isEmpty, !trimmedPath(path).isEmpty else { return nil }
            return (String(authority), path)
        }
        guard !text.hasPrefix("/"), let colon = text.firstIndex(of: ":") else { return nil }
        var host = text[..<colon]
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        let path = String(text[text.index(after: colon)...])
        guard !host.isEmpty, !host.contains("/"), !trimmedPath(path).isEmpty else { return nil }
        return (String(host), path)
    }

    /// The repository's name as people say it: the last path component without `.git`.
    static func repositoryName(from remote: String) -> String? {
        let path = split(remote).map { trimmedPath($0.path) } ?? trimmedPath(remote)
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// `host/path` lowercased and without `.git`, to recognise the same repository behind different URLs.
    static func normalizedKey(_ remote: String) -> String {
        guard let parts = split(remote) else { return remote.lowercased() }
        return "\(parts.host.lowercased())/\(trimmedPath(parts.path).lowercased())"
    }

    private static func trimmedPath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if result.hasSuffix(".git") { result.removeLast(4) }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
