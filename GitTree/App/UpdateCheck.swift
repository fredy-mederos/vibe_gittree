import Foundation

// The same file in GitTree, Vibe Notepad and KeepMyMacClean: when it changes in one, copy it to the others.

/// The newest release of an app on GitHub, as far as checking for updates needs it.
nonisolated struct Release: Codable, Equatable, Sendable {
    /// "1.2.0", from the tag "v1.2.0".
    var version: String
    /// The release's page on GitHub, with its notes and files.
    var pageURL: URL
    /// The disk image attached to the release; nil when GitHub's API wasn't asked (see `ReleaseFeed`).
    var downloadURL: URL?
    var publishedAt: Date?
}

/// Asks GitHub for the newest release of a repository, in one request to GitHub's API. GitHub allows 60 of those
/// an hour per network, shared by everyone behind it; when they're used up, the website's "latest release" link
/// still says which version is the newest.
nonisolated struct ReleaseFeed: Sendable {
    /// "owner/name".
    var repository: String
    /// The disk image releases attach, like "GitTree.dmg".
    var diskImageName: String
    var session: URLSession = .shared

    var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }

    /// The newest release that isn't a draft or a pre-release; nil when the repository has none yet.
    func latestRelease() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try release(fromAPI: data)
        case 404: return nil
        case 403, 429: return try await latestReleaseFromWebsite()
        case let status: throw UpdateCheckError.unexpectedResponse(status)
        }
    }

    /// github.com/owner/name/releases/latest redirects to the newest release's page (…/releases/tag/v1.2.0), or to
    /// the list of releases when there are none.
    func latestReleaseFromWebsite() async throws -> Release? {
        let url = repositoryURL.appendingPathComponent("releases/latest")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let page = response.url else { throw UpdateCheckError.unexpectedResponse(status) }
        return release(fromPage: page)
    }

    func release(fromAPI data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(GitHubRelease.self, from: data)
        let images = payload.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let image = images.first { $0.name == diskImageName } ?? images.first
        return Release(version: VersionNumber.fromTag(payload.tagName), pageURL: payload.htmlURL,
                       downloadURL: image?.browserDownloadURL, publishedAt: payload.publishedAt)
    }

    /// Nil when the page isn't a release's (…/releases/tag/<tag>).
    func release(fromPage page: URL) -> Release? {
        let parts = page.pathComponents
        guard parts.count >= 3, parts[parts.count - 2] == "tag" else { return nil }
        return Release(version: VersionNumber.fromTag(parts[parts.count - 1]), pageURL: page)
    }
}

nonisolated enum UpdateCheckError: LocalizedError, Equatable {
    case unexpectedResponse(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let status) where status == 403 || status == 429:
            "GitHub is limiting requests from this network. Try again in an hour."
        case .unexpectedResponse(let status):
            "GitHub answered with an error (HTTP \(status))."
        }
    }
}

/// Version numbers like 1.2.0, compared number by number.
nonisolated enum VersionNumber {
    /// "v1.2.0" → "1.2.0".
    static func fromTag(_ tag: String) -> String {
        tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
    }

    /// Whether `version` comes before `other`: 0.9.2 before 0.10.0. 1.0 and 1.0.0 are the same, and anything after
    /// the numbers (1.2.0-beta) is ignored.
    static func isVersion(_ version: String, olderThan other: String) -> Bool {
        let lhs = numbers(version), rhs = numbers(other)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// False for builds without a version number, like "–".
    static func isValid(_ version: String) -> Bool {
        !numbers(version).isEmpty
    }

    private static func numbers(_ version: String) -> [Int] {
        fromTag(version).prefix { $0 == "." || ("0"..."9").contains($0) }.split(separator: ".").compactMap { Int($0) }
    }
}

/// The parts of GitHub's release JSON used here.
private nonisolated struct GitHubRelease: Decodable {
    nonisolated struct Asset: Decodable {
        var name: String
        var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var htmlURL: URL
    var publishedAt: Date?
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}
