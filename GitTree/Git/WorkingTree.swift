import Foundation

/// A file with uncommitted changes: what's staged (in the index) and what isn't yet.
struct WorkingChange: Identifiable, Hashable, Sendable {
    /// git's letters for each side, as in `git status --short`: M modified, A added, D deleted,
    /// R renamed, C copied, T type changed; nil when that side has no change. An untracked file's
    /// unstaged change is `?`.
    let staged: String?
    let unstaged: String?
    let path: String
    /// The path before a rename staged in the index.
    let oldPath: String?
    /// Changed on both sides of a merge (or a rebase, cherry-pick or revert) and not resolved yet.
    let isConflicted: Bool

    var id: String { path }
    var isUntracked: Bool { unstaged == "?" }
}

/// What `git status` says about the working tree: the uncommitted changes, the checked-out
/// branch and how far it is from its upstream, and any merge or rebase under way.
struct WorkingTreeStatus: Equatable, Sendable {
    enum Operation: String, Sendable {
        case merge = "A merge", rebase = "A rebase", cherryPick = "A cherry-pick", revert = "A revert"

        /// For the uncommitted changes' details.
        var finishOrStop: String {
            switch self {
            case .merge: String(localized: "A merge is under way: finish or stop it in Terminal.")
            case .rebase: String(localized: "A rebase is under way: finish or stop it in Terminal.")
            case .cherryPick: String(localized: "A cherry-pick is under way: finish or stop it in Terminal.")
            case .revert: String(localized: "A revert is under way: finish or stop it in Terminal.")
            }
        }

        /// Why nothing can be committed here meanwhile (a merge's commit can).
        var finish: String {
            switch self {
            case .merge: String(localized: "A merge is under way: finish it in Terminal.")
            case .rebase: String(localized: "A rebase is under way: finish it in Terminal.")
            case .cherryPick: String(localized: "A cherry-pick is under way: finish it in Terminal.")
            case .revert: String(localized: "A revert is under way: finish it in Terminal.")
            }
        }
    }

    /// Every changed file, up to `WorkingTreeLoader.fileLimit`.
    let changes: [WorkingChange]
    /// How many files changed in all.
    let total: Int
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let conflictedCount: Int
    /// The checked-out branch; nil when HEAD is detached.
    let branch: String?
    /// The checked-out commit; nil before the first commit.
    let head: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let operation: Operation?

    var isClean: Bool { total == 0 }

    var staged: [WorkingChange] { changes.filter { $0.staged != nil && !$0.isConflicted } }
    var unstaged: [WorkingChange] { changes.filter { $0.unstaged != nil && !$0.isUntracked && !$0.isConflicted } }
    var untracked: [WorkingChange] { changes.filter(\.isUntracked) }
    var conflicted: [WorkingChange] { changes.filter(\.isConflicted) }

    /// "2 staged · 3 changed · 1 new", for the graph's row.
    var summary: String {
        var parts: [String] = []
        if conflictedCount > 0 { parts.append(String(localized: "\(conflictedCount) conflicts")) }
        if stagedCount > 0 { parts.append(String(localized: "\(stagedCount) staged", comment: "Files: 2 staged · 3 changed · 1 new")) }
        if unstagedCount > 0 { parts.append(String(localized: "\(unstagedCount) changed", comment: "Files: 2 staged · 3 changed · 1 new")) }
        if untrackedCount > 0 { parts.append(String(localized: "\(untrackedCount) new", comment: "Files: 2 staged · 3 changed · 1 new")) }
        return parts.joined(separator: " · ")
    }

    /// `git status --porcelain=v2 -z --branch` output.
    static func parse(_ data: Data, limit: Int, operation: Operation?) -> WorkingTreeStatus {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var changes: [WorkingChange] = []
        var total = 0, staged = 0, unstaged = 0, untracked = 0, conflicted = 0
        var branch: String?
        var head: String?
        var upstream: String?
        var ahead = 0, behind = 0

        func add(_ change: WorkingChange) {
            total += 1
            if change.isConflicted {
                conflicted += 1
            } else if change.isUntracked {
                untracked += 1
            } else {
                if change.staged != nil { staged += 1 }
                if change.unstaged != nil { unstaged += 1 }
            }
            if changes.count < limit { changes.append(change) }
        }
        func side(_ letter: Character) -> String? {
            letter == "." ? nil : String(letter)
        }

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            if token.hasPrefix("# ") {
                let header = token.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard header.count == 2 else { continue }
                switch header[0] {
                case "branch.oid": head = header[1] == "(initial)" ? nil : header[1]
                case "branch.head": branch = header[1] == "(detached)" ? nil : header[1]
                case "branch.upstream": upstream = header[1]
                case "branch.ab":
                    for part in header[1].split(separator: " ") {
                        if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                        if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            guard let kind = token.first else { continue }
            switch kind {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                add(WorkingChange(staged: side(xy[0]), unstaged: side(xy[1]), path: String(fields[8]), oldPath: nil, isConflicted: false))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, then the original path as the next token
                let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                let original = i < tokens.count ? tokens[i] : nil
                i += 1
                add(WorkingChange(staged: side(xy[0]), unstaged: side(xy[1]), path: String(fields[9]), oldPath: original, isConflicted: false))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                add(WorkingChange(staged: nil, unstaged: String(fields[1]), path: String(fields[10]), oldPath: nil, isConflicted: true))
            case "?":
                add(WorkingChange(staged: nil, unstaged: "?", path: String(token.dropFirst(2)), oldPath: nil, isConflicted: false))
            default:
                continue
            }
        }
        // Files stay in the order git lists them, which is by path.
        return WorkingTreeStatus(changes: changes, total: total, stagedCount: staged, unstagedCount: unstaged, untrackedCount: untracked,
                                 conflictedCount: conflicted, branch: branch, head: head, upstream: upstream, ahead: ahead,
                                 behind: behind, operation: operation)
    }
}

/// Folders and files git ignores (`build/`, `node_modules/`…), so the working tree's watcher can
/// leave out changes there: a build writing thousands of files doesn't make Vibe GitTree ask git
/// for the status over and over.
struct IgnoredPaths: Sendable {
    /// Relative paths; folders end with a slash.
    let paths: Set<String>

    /// Whether a path relative to the working tree is ignored, itself or by a folder it's in.
    func contains(_ path: String) -> Bool {
        if paths.contains(path) || paths.contains(path + "/") { return true }
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            if paths.contains(String(path[...slash])) { return true }
            index = path.index(after: slash)
        }
        return false
    }
}

enum WorkingTreeLoader {
    /// The inspector lists at most this many files; the counts cover them all.
    static let fileLimit = 5_000

    /// The working tree's status. Throws for a repository without one (a bare repository).
    /// `GIT_OPTIONAL_LOCKS=0` (see `Git.environment`) keeps `git status` from rewriting the index,
    /// so looking changes nothing.
    static func status(in directory: URL, gitDirectory: URL?) async throws -> WorkingTreeStatus {
        let output = try await Git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: directory)
        let operation = gitDirectory.flatMap(Self.operation(in:))
        return await Task.detached(priority: .userInitiated) {
            WorkingTreeStatus.parse(output, limit: fileLimit, operation: operation)
        }.value
    }

    /// The repository's own git folder (`.git`, or the worktree's folder inside it), where a merge
    /// or rebase leaves its marks.
    static func gitDirectory(of directory: URL) async -> URL? {
        guard let path = try? await Git.string(["rev-parse", "--absolute-git-dir"], in: directory), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func operation(in gitDirectory: URL) -> WorkingTreeStatus.Operation? {
        let manager = FileManager.default
        func exists(_ name: String) -> Bool { manager.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    /// What git ignores in the working tree, a whole ignored folder as one entry (at most 20,000).
    static func ignoredPaths(in directory: URL) async -> IgnoredPaths {
        guard let output = try? await Git.run(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: directory)
        else { return IgnoredPaths(paths: []) }
        return await Task.detached(priority: .utility) {
            let paths = output.split(separator: 0).prefix(20_000).map { String(decoding: $0, as: UTF8.self) }
            return IgnoredPaths(paths: Set(paths))
        }.value
    }
}

/// A stash: changes put aside with `git stash`, newest first in `git stash list`.
struct StashEntry: Identifiable, Hashable, Sendable {
    /// Its place in the list: 0 for `stash@{0}`, the newest.
    let index: Int
    let id: ObjectID
    /// The commit it was made on.
    let base: ObjectID?
    /// The commit holding its untracked files, when it has any.
    let untracked: ObjectID?
    let date: Date
    /// What git wrote: `On main: message`, or `WIP on main: 1a2b3c4 subject` without one.
    let subject: String

    var name: String { "stash@{\(index)}" }

    /// The branch it was made on.
    var branch: String? {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            return rest.firstIndex(of: ":").map { String(rest[..<$0]) }
        }
        return nil
    }

    /// The message it was given, or "WIP on main" for one without.
    var title: String {
        if subject.hasPrefix("On "), let colon = subject.firstIndex(of: ":") {
            let message = subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return message }
        }
        if subject.hasPrefix("WIP on "), let colon = subject.firstIndex(of: ":") {
            return String(subject[..<colon])
        }
        return subject
    }
}

/// A stash's changes: the tracked files it changed, compared with the commit it was made on, and
/// the untracked files it took along.
struct StashDetails: Sendable {
    let files: [ChangedFile]
    let untrackedFiles: [ChangedFile]
    let totalFiles: Int
}

enum StashLoader {
    static func list(in directory: URL) async -> [StashEntry] {
        guard let output = try? await Git.run(["stash", "list", "--format=%H%x1f%P%x1f%ct%x1f%gs"], in: directory, allowFailure: true)
        else { return [] }
        var entries: [StashEntry] = []
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count >= 4, let id = ObjectID(hex: String(fields[0])) else { continue }
            let parents = fields[1].split(separator: " ").compactMap { ObjectID(hex: String($0)) }
            entries.append(StashEntry(index: entries.count, id: id, base: parents.first, untracked: parents.count > 2 ? parents[2] : nil,
                                      date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                                      subject: fields[3...].joined(separator: "\u{1F}")))
        }
        return entries
    }

    static func details(of stash: StashEntry, in directory: URL) async throws -> StashDetails {
        let limit = CommitDetailsLoader.fileLimit
        let tracked = ["diff-tree", "-r", "-z", "--name-status", "--no-commit-id", "-M"]
            + (stash.base.map { [$0.hex, stash.id.hex] } ?? ["--root", stash.id.hex])
        async let trackedOutput = Git.run(tracked, in: directory)
        async let untrackedOutput = untrackedFiles(of: stash, in: directory)
        let (files, total) = CommitDetailsLoader.parseNameStatus(try await trackedOutput, limit: limit)
        let (untracked, untrackedTotal) = try await untrackedOutput.map { CommitDetailsLoader.parseNameStatus($0, limit: limit) } ?? ([], 0)
        return StashDetails(files: files, untrackedFiles: untracked, totalFiles: total + untrackedTotal)
    }

    /// The untracked files a stash took along: everything in the commit that holds them.
    private static func untrackedFiles(of stash: StashEntry, in directory: URL) async throws -> Data? {
        guard let untracked = stash.untracked else { return nil }
        return try await Git.run(["diff-tree", "-r", "-z", "--name-status", "--no-commit-id", "--root", untracked.hex], in: directory)
    }
}
