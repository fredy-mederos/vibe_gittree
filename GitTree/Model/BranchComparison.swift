import Foundation

/// What a comparison window compares: branches or tags by full ref name, or commits by hash; nil
/// until picked.
struct CompareTarget: Codable, Hashable {
    var repositoryID: UUID
    var base: String?
    var head: String?
}

/// A comparison opened before, for Repository › Recent Comparisons: its ends as `CompareTarget` has them.
struct RecentComparison: Codable, Hashable, Sendable {
    var base: String
    var head: String

    /// "feature/login ↔ develop", "1a2b3c4d ↔ main".
    var title: String {
        "\(ComparePoint.shortName(head)) ↔ \(ComparePoint.shortName(base))"
    }
}

/// One end of a comparison: a branch or tag, or any commit.
struct ComparePoint: Hashable, Sendable {
    /// `refs/heads/feature/login`, or a commit's hash.
    let spec: String
    /// `feature/login`, or the commit's short hash.
    let name: String
    let commit: Int32
    /// Nil for a commit.
    let kind: GitRef.Kind?

    static func resolve(_ spec: String?, in graph: CommitGraph) -> ComparePoint? {
        guard let spec else { return nil }
        if spec.hasPrefix("refs/") {
            return graph.refs.first { $0.fullName == spec }.map { ComparePoint(spec: spec, name: $0.name, commit: $0.commit, kind: $0.kind) }
        }
        return graph.index(matching: spec).map { ComparePoint(spec: spec, name: graph.ids[Int($0)].short, commit: $0, kind: nil) }
    }

    /// A ref's short name, or a commit's short hash.
    static func shortName(_ spec: String) -> String {
        spec.hasPrefix("refs/") ? GitRef.shortName(fullName: spec) : String(spec.prefix(8))
    }

    var systemImage: String {
        switch kind {
        case .local: "arrow.triangle.branch"
        case .remote: "cloud"
        case .tag: "tag"
        case nil: "smallcircle.filled.circle"
        }
    }
}

/// Two branches (or tags, or commits) side by side: where they diverged and what each has that
/// the other doesn't.
struct BranchComparison: Sendable {
    /// What one side has that the other doesn't.
    struct Side: Sendable {
        let point: ComparePoint
        /// Newest first, merges included.
        let commits: [Int32]
        let nonMergeCount: Int
        /// Tickets its commits mention, newest first.
        let tickets: [RecentTicket]
        /// Authors by number of commits.
        let authors: [(name: String, commits: Int)]
        let newest: Date?
        let oldest: Date?

        init(point: ComparePoint, commits: [Int32], graph: CommitGraph) {
            self.point = point
            self.commits = commits
            var nonMerges = 0
            var order: [String] = []
            var tickets: [String: RecentTicket] = [:]
            var authorCounts: [Int32: Int] = [:]
            for commit in commits where !graph.isMerge(commit) {
                nonMerges += 1
                authorCounts[graph.authorOf[Int(commit)], default: 0] += 1
                guard let key = graph.ticketKey(in: graph.subjects[Int(commit)]) else { continue }
                if tickets[key] == nil {
                    order.append(key)
                    tickets[key] = RecentTicket(key: key, commits: 0, latest: graph.date(of: commit))
                }
                tickets[key]?.commits += 1
            }
            nonMergeCount = nonMerges
            self.tickets = order.compactMap { tickets[$0] }
            authors = authorCounts
                .map { (name: graph.authors[Int($0.key)], commits: $0.value) }
                .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
            newest = commits.first.map { graph.date(of: $0) }
            oldest = commits.last.map { graph.date(of: $0) }
        }
    }

    let graph: CommitGraph
    let base: Side
    let head: Side
    /// The newest commit both have (where they diverged); nil when they share no history.
    let mergeBase: Int32?

    /// Walks back from both tips once. The history is in date order with every commit before its
    /// parents, so the first commit both reach is a merge base.
    static func compute(graph: CommitGraph, base: ComparePoint, head: ComparePoint) -> BranchComparison {
        let inBase = reachable(from: base.commit, in: graph)
        let inHead = reachable(from: head.commit, in: graph)
        var onlyBase: [Int32] = []
        var onlyHead: [Int32] = []
        var mergeBase: Int32?
        for index in 0..<graph.count {
            switch (inBase[index], inHead[index]) {
            case (true, false): onlyBase.append(Int32(index))
            case (false, true): onlyHead.append(Int32(index))
            case (true, true): if mergeBase == nil { mergeBase = Int32(index) }
            case (false, false): break
            }
        }
        return BranchComparison(graph: graph, base: Side(point: base, commits: onlyBase, graph: graph),
                                head: Side(point: head, commits: onlyHead, graph: graph), mergeBase: mergeBase)
    }

    private static func reachable(from commit: Int32, in graph: CommitGraph) -> [Bool] {
        var seen = [Bool](repeating: false, count: graph.count)
        var stack = [commit]
        while let current = stack.popLast() {
            guard current >= 0, !seen[Int(current)] else { continue }
            seen[Int(current)] = true
            stack.append(contentsOf: graph.parents(current))
        }
        return seen
    }

    /// The branch to compare against when none was picked: develop, main or master (local, else
    /// on a remote), else the checked-out branch; never `other`.
    static func defaultBase(in graph: CommitGraph, other: String?) -> GitRef? {
        for name in ["develop", "main", "master", "trunk"] {
            if let ref = graph.refs.first(where: { $0.kind == .local && $0.name == name && $0.fullName != other }) { return ref }
            if let ref = graph.refs.first(where: { $0.kind == .remote && $0.remoteParts?.branch == name && $0.fullName != other }) {
                return ref
            }
        }
        return graph.refs.first { $0.isHead && $0.fullName != other }
    }

    /// The branch to compare when none was picked: the checked-out one, else the newest local branch.
    static func defaultHead(in graph: CommitGraph, other: String?) -> GitRef? {
        graph.refs.first { $0.isHead && $0.kind == .local && $0.fullName != other }
            ?? graph.refs.filter { $0.kind == .local && $0.fullName != other }.max { graph.times[Int($0.commit)] < graph.times[Int($1.commit)] }
    }
}

extension Notification.Name {
    /// Asks the windows showing a repository to highlight commits. userInfo: repository (UUID),
    /// commits (hex strings), title (String).
    static let gitTreeHighlightCommits = Notification.Name("GitTreeHighlightCommits")
}
