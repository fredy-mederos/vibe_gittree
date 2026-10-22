import Foundation

struct GitRef: Identifiable, Hashable, Sendable {
    enum Kind: Int, Sendable {
        case local, remote, tag
    }

    let kind: Kind
    /// `refs/heads/feature/login`
    let fullName: String
    /// `feature/login`, `origin/feature/login` or `v1.2.0`
    let name: String
    let commit: Int32
    /// The checked-out branch.
    let isHead: Bool

    var id: String { fullName }

    /// For a remote branch, the remote ("origin") and the branch name without it.
    var remoteParts: (remote: String, branch: String)? {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return nil }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }

    static func shortName(fullName: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }
}

/// The whole history of a repository, newest first, stored as parallel arrays indexed by commit.
/// Immutable once built, so it can be shared freely between threads.
final class CommitGraph: @unchecked Sendable {
    let ids: [ObjectID]
    let parentStart: [Int32]
    /// Parent indexes; -1 when the parent is not part of the loaded history (shallow clones).
    let parentList: [Int32]
    let childStart: [Int32]
    let childList: [Int32]
    let authorOf: [Int32]
    let authors: [String]
    let authorEmails: [String]
    let times: [Int64]
    let subjects: [String]
    let refs: [GitRef]
    let refsByCommit: [Int32: [Int32]]
    let indexByID: [ObjectID: Int32]
    let headCommit: Int32
    let headBranch: String?
    /// The branch each remote's HEAD names (`origin` → `develop`): the remote's default branch, as
    /// git noted it when cloning.
    let remoteHeads: [String: String]
    /// Issue-tracker prefixes that show up often in subjects, like `PROJ` in `PROJ-1234`.
    let ticketPrefixes: [String]
    let ticketRegex: NSRegularExpression?
    let mergeCount: Int

    init(
        ids: [ObjectID],
        parentStart: [Int32],
        parentList: [Int32],
        authorOf: [Int32],
        authors: [String],
        authorEmails: [String],
        times: [Int64],
        subjects: [String],
        refs: [GitRef],
        indexByID: [ObjectID: Int32],
        headCommit: Int32,
        remoteHeads: [String: String] = [:],
        ticketPrefixes: [String]
    ) {
        self.ids = ids
        self.parentStart = parentStart
        self.parentList = parentList
        self.authorOf = authorOf
        self.authors = authors
        self.authorEmails = authorEmails
        self.times = times
        self.subjects = subjects
        self.refs = refs
        self.indexByID = indexByID
        self.headCommit = headCommit
        self.headBranch = refs.first { $0.isHead && $0.kind == .local }?.name
        self.remoteHeads = remoteHeads
        self.ticketPrefixes = ticketPrefixes

        let count = ids.count
        var childStart = [Int32](repeating: 0, count: count + 1)
        var merges = 0
        for commit in 0..<count {
            let start = Int(parentStart[commit])
            let end = Int(parentStart[commit + 1])
            if end - start > 1 { merges += 1 }
            for k in start..<end where parentList[k] >= 0 {
                childStart[Int(parentList[k]) + 1] += 1
            }
        }
        for i in 0..<count { childStart[i + 1] += childStart[i] }
        var cursor = childStart
        var childList = [Int32](repeating: 0, count: Int(childStart[count]))
        for commit in 0..<count {
            for k in Int(parentStart[commit])..<Int(parentStart[commit + 1]) {
                let parent = Int(parentList[k])
                guard parent >= 0 else { continue }
                childList[Int(cursor[parent])] = Int32(commit)
                cursor[parent] += 1
            }
        }
        self.childStart = childStart
        self.childList = childList
        self.mergeCount = merges

        var byCommit: [Int32: [Int32]] = [:]
        for (index, ref) in refs.enumerated() {
            byCommit[ref.commit, default: []].append(Int32(index))
        }
        self.refsByCommit = byCommit

        if ticketPrefixes.isEmpty {
            self.ticketRegex = nil
        } else {
            let alternatives = ticketPrefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            self.ticketRegex = try? NSRegularExpression(pattern: "\\b(?:\(alternatives))-\\d{1,6}\\b")
        }
    }

    var count: Int { ids.count }

    func parents(_ commit: Int32) -> ArraySlice<Int32> {
        let i = Int(commit)
        return parentList[Int(parentStart[i])..<Int(parentStart[i + 1])]
    }

    func children(_ commit: Int32) -> ArraySlice<Int32> {
        let i = Int(commit)
        return childList[Int(childStart[i])..<Int(childStart[i + 1])]
    }

    func isMerge(_ commit: Int32) -> Bool {
        let i = Int(commit)
        return parentStart[i + 1] - parentStart[i] > 1
    }

    /// Refs pointing at a commit: checked-out branch first, then branches, remote branches and tags.
    func refs(at commit: Int32) -> [GitRef] {
        guard let indexes = refsByCommit[commit] else { return [] }
        return indexes.map { refs[Int($0)] }.sorted { a, b in
            if a.isHead != b.isHead { return a.isHead }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// A commit by full hash or by an unambiguous-enough prefix (at least 4 characters).
    func index(matching hash: String) -> Int32? {
        let needle = hash.lowercased()
        if needle.count >= 40, let id = ObjectID(hex: needle) { return indexByID[id] }
        guard needle.count >= 4, needle.allSatisfy(\.isHexDigit) else { return nil }
        return ids.firstIndex { $0.hex.hasPrefix(needle) }.map(Int32.init)
    }

    func date(of commit: Int32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(times[Int(commit)]))
    }

    /// The first ticket key in a subject: the ticket a commit is filed under.
    func ticketKey(in subject: String) -> String? {
        guard let ticketRegex,
              let match = ticketRegex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range, in: subject) else { return nil }
        return String(subject[range])
    }

    func ticketKeys(in subject: String) -> [String] {
        guard let ticketRegex else { return [] }
        let range = NSRange(subject.startIndex..., in: subject)
        var keys: [String] = []
        for match in ticketRegex.matches(in: subject, range: range) {
            if let r = Range(match.range, in: subject) {
                let key = String(subject[r])
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }
}
