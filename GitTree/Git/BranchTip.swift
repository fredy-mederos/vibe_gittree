import Foundation

/// The newest commit of work nothing builds on: no commit on any branch, remote branch or tag has it
/// as a parent. A branch, tag or worktree whose work is unmerged, or one a rebase or cherry-pick
/// copied into the main branch, as the graph and the sidebar's Unmerged section show it. The main
/// branch's newest commit, where work gets merged, isn't one.
struct BranchTip: Sendable {
    let commit: Int32
    /// How many of its commits the main branch has no copy of, merges left out: 0 when a rebase or
    /// cherry-pick put all its work there; nil without a main branch.
    let unmergedCount: Int?

    /// Whether its work isn't in the main branch yet.
    var isUnmerged: Bool { unmergedCount != 0 }

    /// Every one in the history, newest first.
    static func all(in graph: CommitGraph, mainTip: Int32) -> [BranchTip] {
        let leaves = (Int32(0)..<Int32(graph.count)).filter { $0 != mainTip && graph.children($0).isEmpty }
        guard mainTip >= 0 else { return leaves.map { BranchTip(commit: $0, unmergedCount: nil) } }
        guard !leaves.isEmpty else { return [] }
        // What the main branch has: everything its newest commit leads to, and what a rebase or
        // cherry-pick keeps of each of those commits.
        var onMain = [Bool](repeating: false, count: graph.count)
        var copies: Set<Copy> = []
        var stack = [mainTip]
        while let commit = stack.popLast() {
            guard !onMain[Int(commit)] else { continue }
            onMain[Int(commit)] = true
            copies.insert(Copy(commit, in: graph))
            for parent in graph.parents(commit) where parent >= 0 && !onMain[Int(parent)] {
                stack.append(parent)
            }
        }
        // Each walk marks the commits it looked at with its tip, so the next one needs no fresh array.
        var seenFrom = [Int32](repeating: -1, count: graph.count)
        return leaves.map { tip in
            var count = 0
            stack = [tip]
            while let commit = stack.popLast() {
                guard seenFrom[Int(commit)] != tip, !onMain[Int(commit)] else { continue }
                seenFrom[Int(commit)] = tip
                if !graph.isMerge(commit) && !copies.contains(Copy(commit, in: graph)) { count += 1 }
                for parent in graph.parents(commit) where parent >= 0 {
                    stack.append(parent)
                }
            }
            return BranchTip(commit: tip, unmergedCount: count)
        }
    }

    /// What a rebase or cherry-pick keeps of a commit: its subject, author and author time. A copy
    /// gets a new hash and commit time, and its changes may differ where it met conflicts.
    private struct Copy: Hashable {
        let subject: String
        let author: Int32
        let time: Int64

        init(_ commit: Int32, in graph: CommitGraph) {
            subject = graph.subjects[Int(commit)]
            author = graph.authorOf[Int(commit)]
            time = graph.times[Int(commit)]
        }
    }
}
