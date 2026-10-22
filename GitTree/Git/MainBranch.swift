import Foundation

/// The branch the graph draws as its trunk: a straight line in the first lane, in a color no other
/// lane takes (`LaneLayoutEngine.mainColor`), from its newest commit down to the first one. Only
/// its first parents are on it; what came in through merges keeps lanes and colors of its own, even
/// once the branches are deleted.
enum MainBranch {
    /// Tried in this order when the repository doesn't say which branch is its default.
    static let usualNames = ["main", "master", "develop", "trunk"]

    /// The one picked in Repository Settings (`chosen`), else the repository's default branch:
    /// GitHub's (`hostDefault`), else the one a remote's HEAD names (what git noted when cloning), or
    /// a bare clone's own HEAD; else the first of `usualNames` there is. Only branches the repository
    /// has count; nil when it has none of them.
    static func name(in graph: CommitGraph, chosen: String?, hostDefault: String?, headIsDefault: Bool) -> String? {
        var candidates: [String] = []
        if let chosen = chosen?.trimmingCharacters(in: .whitespaces), !chosen.isEmpty { candidates.append(chosen) }
        if let hostDefault { candidates.append(hostDefault) }
        if let origin = graph.remoteHeads["origin"] { candidates.append(origin) }
        candidates += graph.remoteHeads.sorted { $0.key < $1.key }.map(\.value)
        if headIsDefault, let head = graph.headBranch { candidates.append(head) }
        candidates += usualNames
        return candidates.first { exists($0, in: graph) }
    }

    /// Whether there's a local branch by that name, or one on a remote.
    static func exists(_ name: String, in graph: CommitGraph) -> Bool {
        graph.refs.contains { ref in
            switch ref.kind {
            case .local: ref.name == name
            case .remote: ref.remoteParts?.branch == name
            case .tag: false
            }
        }
    }

    /// The commit the main line starts from: the local branch's tip, unless the remote branch (on
    /// `origin` first) isn't among its first parents — it has commits the local one hasn't pulled —
    /// or there's no local branch.
    static func tip(of name: String, in graph: CommitGraph) -> Int32 {
        let local = graph.refs.first { $0.kind == .local && $0.name == name }?.commit
        let remotes = graph.refs.filter { $0.kind == .remote && $0.remoteParts?.branch == name }
        let remote = (remotes.first { $0.remoteParts?.remote == "origin" } ?? remotes.min { $0.name < $1.name })?.commit
        guard let local else { return remote ?? -1 }
        guard let remote, remote != local else { return local }
        // Parents come after their children in the history, so the walk can stop once it's past.
        var commit = local
        while commit >= 0 && commit < remote {
            commit = graph.parents(commit).first ?? -1
        }
        return commit == remote ? local : remote
    }
}
