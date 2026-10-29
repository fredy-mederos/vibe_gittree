import Foundation

/// The newest commit of work nothing builds on (`GraphLayout.isUnmergedTip`): a branch, tag or
/// worktree whose work isn't merged anywhere, as the sidebar's Unmerged section lists it.
struct UnmergedTip: Sendable {
    let commit: Int32
    /// How many of its commits the main branch doesn't have, as `git rev-list --count main..<tip>`
    /// counts them; nil without a main branch.
    let count: Int?

    /// Every one in the history, newest first.
    static func all(in layout: GraphLayout) -> [UnmergedTip] {
        let graph = layout.graph
        // What the main branch has: everything its newest commit leads to.
        var onMain = [Bool](repeating: false, count: graph.count)
        var stack: [Int32] = layout.mainTip >= 0 ? [layout.mainTip] : []
        while let commit = stack.popLast() {
            guard !onMain[Int(commit)] else { continue }
            onMain[Int(commit)] = true
            for parent in graph.parents(commit) where parent >= 0 && !onMain[Int(parent)] {
                stack.append(parent)
            }
        }
        // Each walk marks the commits it counted with its tip, so the next one needs no fresh array.
        var countedFor = [Int32](repeating: -1, count: graph.count)
        var tips: [UnmergedTip] = []
        for tip in Int32(0)..<Int32(graph.count) where layout.isUnmergedTip(tip) {
            guard layout.mainTip >= 0 else {
                tips.append(UnmergedTip(commit: tip, count: nil))
                continue
            }
            var count = 0
            stack = [tip]
            while let commit = stack.popLast() {
                guard countedFor[Int(commit)] != tip, !onMain[Int(commit)] else { continue }
                countedFor[Int(commit)] = tip
                count += 1
                for parent in graph.parents(commit) where parent >= 0 {
                    stack.append(parent)
                }
            }
            tips.append(UnmergedTip(commit: tip, count: count))
        }
        return tips
    }
}
