import Foundation

struct ChangedFile: Identifiable, Sendable {
    let id: Int
    /// git's status letter: A added, M modified, D deleted, R renamed, C copied, T type changed.
    let status: String
    let path: String
    let oldPath: String?
}

/// What the inspector shows beyond the subject line, loaded on demand for the selected commit.
struct CommitDetails: Sendable {
    let message: String
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let committerDate: Date
    let files: [ChangedFile]
    let totalFiles: Int

    /// The message without its subject line.
    var body: String {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "" }
        return lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommitDetailsLoader {
    static let fileLimit = 500

    /// - Parameter detectRenames: off for partial clones, where rename detection would download file contents.
    static func load(commit: ObjectID, firstParent: ObjectID?, in directory: URL, detectRenames: Bool) async throws -> CommitDetails {
        async let meta = Git.run(
            ["show", "-s", "--format=%B%x00%aN%x00%aE%x00%at%x00%cN%x00%cE%x00%ct", commit.hex],
            in: directory
        )
        let diff = ["diff-tree", "-r", "-z", "--name-status", "--no-commit-id", detectRenames ? "-M" : "--no-renames"]
            + (firstParent.map { [$0.hex, commit.hex] } ?? ["--root", commit.hex])
        async let changes = Git.run(diff, in: directory, allowFailure: true)

        let fields = String(decoding: try await meta, as: UTF8.self).components(separatedBy: "\u{0}")
        func field(_ i: Int) -> String {
            i < fields.count ? fields[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        func date(_ i: Int) -> Date {
            Date(timeIntervalSince1970: TimeInterval(field(i)) ?? 0)
        }

        let changed = try await changes
        let (files, total) = parseNameStatus(changed, limit: fileLimit)

        return CommitDetails(
            message: field(0),
            authorName: field(1),
            authorEmail: field(2),
            authorDate: date(3),
            committerName: field(4),
            committerEmail: field(5),
            committerDate: date(6),
            files: files,
            totalFiles: total
        )
    }

    /// `git diff-tree --name-status -z` output: the first `limit` files, and how many changed in all.
    static func parseNameStatus(_ data: Data, limit: Int) -> (files: [ChangedFile], total: Int) {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var files: [ChangedFile] = []
        var total = 0
        var i = 0
        while i < tokens.count {
            let status = tokens[i]
            guard !status.isEmpty else { i += 1; continue }
            let code = String(status.prefix(1))
            var path = ""
            var oldPath: String?
            if code == "R" || code == "C" {
                guard i + 2 < tokens.count else { break }
                oldPath = tokens[i + 1]
                path = tokens[i + 2]
                i += 3
            } else {
                guard i + 1 < tokens.count else { break }
                path = tokens[i + 1]
                i += 2
            }
            if files.count < limit {
                files.append(ChangedFile(id: total, status: code, path: path, oldPath: oldPath))
            }
            total += 1
        }
        return (files, total)
    }
}

/// Which branches and tags contain a commit, found by walking from the commit to its descendants.
struct Containment: Sendable {
    let branches: [GitRef]
    let tagCount: Int
    /// Earliest tag that matches the repository's release pattern.
    let release: GitRef?
    /// Earliest tag of any kind.
    let firstTag: GitRef?

    static func compute(commit: Int32, graph: CommitGraph, releasePattern: String) -> Containment {
        let release = try? NSRegularExpression(pattern: releasePattern)
        var seen = [Bool](repeating: false, count: graph.count)
        var stack: [Int32] = [commit]
        var locals: [GitRef] = []
        var remotes: [GitRef] = []
        var tags: [GitRef] = []
        while let current = stack.popLast() {
            let i = Int(current)
            if seen[i] { continue }
            seen[i] = true
            if let indexes = graph.refsByCommit[current] {
                for index in indexes {
                    let ref = graph.refs[Int(index)]
                    switch ref.kind {
                    case .local: locals.append(ref)
                    case .remote: remotes.append(ref)
                    case .tag: tags.append(ref)
                    }
                }
            }
            for child in graph.children(current) where !seen[Int(child)] {
                stack.append(child)
            }
        }
        let localNames = Set(locals.map(\.name))
        let branches = (locals + remotes.filter { !localNames.contains($0.remoteParts?.branch ?? $0.name) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func earliest(_ refs: [GitRef]) -> GitRef? {
            refs.min { graph.times[Int($0.commit)] < graph.times[Int($1.commit)] }
        }
        let releases = tags.filter { tag in
            guard let release else { return false }
            return release.firstMatch(in: tag.name, range: NSRange(tag.name.startIndex..., in: tag.name)) != nil
        }
        return Containment(branches: branches, tagCount: tags.count, release: earliest(releases), firstTag: earliest(tags))
    }
}

/// Pull request numbers mentioned in a commit subject, as GitHub and Bitbucket write them.
enum PullRequestReferences {
    private static let regex = try! NSRegularExpression(
        pattern: #"(?:Merge pull request #(\d+)|\(#(\d+)\)|pull request #(\d+))"#,
        options: [.caseInsensitive]
    )

    static func numbers(in text: String) -> [Int] {
        var numbers: [Int] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            for group in 1...3 {
                let r = match.range(at: group)
                guard r.location != NSNotFound, let swiftRange = Range(r, in: text), let number = Int(text[swiftRange]) else { continue }
                if !numbers.contains(number) { numbers.append(number) }
            }
        }
        return numbers
    }
}
