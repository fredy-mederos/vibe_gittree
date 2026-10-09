import Foundation

/// A repository in the library: a folder on this Mac, or a remote one GitTree cloned into its own storage.
struct Repository: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case local, remote
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// Working tree for local repositories; the bare clone for remote ones.
    var path: String
    /// Where a remote repository was cloned from.
    var remoteURL: String?
    var addedAt: Date
    var lastFetchedAt: Date?
    /// Link for ticket keys found in commit messages, with `{key}` standing for the key.
    var issueURLTemplate: String?
    /// Regular expression for tags that mark a production release.
    var releaseTagPattern: String?

    static let defaultReleaseTagPattern = #"^v?\d+(\.\d+)+$"#

    var directory: URL { URL(fileURLWithPath: path, isDirectory: true) }

    var effectiveReleaseTagPattern: String {
        guard let pattern = releaseTagPattern, !pattern.isEmpty else { return Self.defaultReleaseTagPattern }
        return pattern
    }

    func issueURL(for key: String) -> URL? {
        guard let template = issueURLTemplate?.trimmingCharacters(in: .whitespaces), !template.isEmpty else { return nil }
        let link = template.contains("{key}") ? template.replacingOccurrences(of: "{key}", with: key) : template + key
        return URL(string: link)
    }
}
