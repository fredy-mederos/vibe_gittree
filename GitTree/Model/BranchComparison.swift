import Foundation

/// Which branches (or tags) a comparison window compares, by full ref name; nil until picked.
struct CompareTarget: Codable, Hashable {
    var repositoryID: UUID
    var base: String?
    var head: String?
}

/// Two branches side by side: where they diverged and what each has that the other doesn't.
struct BranchComparison: Sendable {
    /// What one branch has that the other doesn't.
    struct Side: Sendable {
        let ref: GitRef
        /// Newest first, merges included.
        let commits: [Int32]
        let nonMergeCount: Int
        /// Tickets its commits mention, newest first.
        let tickets: [RecentTicket]
        /// Authors by number of commits.
        let authors: [(name: String, commits: Int)]
        let newest: Date?
        let oldest: Date?

        init(ref: GitRef, commits: [Int32], graph: CommitGraph) {
            self.ref = ref
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
    static func compute(graph: CommitGraph, base: GitRef, head: GitRef) -> BranchComparison {
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
        return BranchComparison(graph: graph, base: Side(ref: base, commits: onlyBase, graph: graph),
                                head: Side(ref: head, commits: onlyHead, graph: graph), mergeBase: mergeBase)
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

enum BranchDiffLoader {
    /// The files that changed between two commits (from where two branches diverged to one tip),
    /// at most 1,000 listed. Partial clones skip rename detection, which would download contents.
    static func files(from base: ObjectID, to tip: ObjectID, in directory: URL, detectRenames: Bool) async throws
        -> (files: [ChangedFile], total: Int) {
        let output = try await Git.run(
            ["diff-tree", "-r", "-z", "--name-status", "--no-commit-id", detectRenames ? "-M" : "--no-renames", base.hex, tip.hex],
            in: directory
        )
        return await Task.detached(priority: .userInitiated) {
            CommitDetailsLoader.parseNameStatus(output, limit: 1_000)
        }.value
    }
}

extension Notification.Name {
    /// Asks the windows showing a repository to highlight commits. userInfo: repository (UUID),
    /// commits (hex strings), title (String).
    static let gitTreeHighlightCommits = Notification.Name("GitTreeHighlightCommits")
}
