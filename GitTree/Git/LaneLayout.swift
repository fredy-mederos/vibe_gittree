import Foundation

/// Which part of the history the graph shows.
enum GraphScope: Hashable, Sendable {
    case all
    case local
    case head
    /// Only commits reachable from one ref (full name, e.g. `refs/heads/develop`).
    case ref(String)

    var refName: String? {
        if case .ref(let name) = self { return name }
        return nil
    }

    var title: String {
        switch self {
        case .all: String(localized: "All Branches")
        case .local: String(localized: "Local Branches")
        case .head: String(localized: "Current Branch")
        case .ref(let name): String(localized: "Only \(GitRef.shortName(fullName: name))", comment: "Only one branch's history is shown")
        }
    }
}

/// A piece of a lane line inside one row.
struct LaneSegment: Sendable {
    enum Kind: UInt8, Sendable {
        /// Straight line through the row, top to bottom.
        case through
        /// From a lane at the top edge into this row's commit.
        case incoming
        /// From this row's commit to a lane at the bottom edge.
        case outgoing
    }

    let from: UInt16
    let to: UInt16
    let kind: Kind
    let color: UInt8

    /// The color of the line from uncommitted changes down to HEAD's commit, drawn dashed.
    static let uncommittedColor: UInt8 = .max
}

/// The row above the history for uncommitted changes: its lane, and the line from it toward
/// HEAD's commit (none before the first commit, or when the scope leaves HEAD out).
struct WorkingRow: Sendable {
    let column: UInt16
    let segments: [LaneSegment]
}

/// Everything needed to draw the graph column: which commit sits in each row, in which lane, and the
/// line segments crossing the row. Built in one top-to-bottom pass.
final class GraphLayout: @unchecked Sendable {
    let graph: CommitGraph
    let scope: GraphScope
    let rows: [Int32]
    /// Row of each commit, or -1 when the commit is outside the scope.
    let rowOfCommit: [Int32]
    let column: [UInt16]
    let color: [UInt8]
    let segmentStart: [Int32]
    let segments: [LaneSegment]
    /// Lanes a row touches, used to size the graph column.
    let laneCount: [UInt16]
    let suggestedLaneCount: Int
    /// Whether it was laid out with a row for uncommitted changes, and that row when it has one.
    let includesWorkingTree: Bool
    let workingRow: WorkingRow?
    /// The branch it drew as the trunk (see `MainBranch`).
    let mainBranch: String?

    init(graph: CommitGraph, scope: GraphScope, rows: [Int32], rowOfCommit: [Int32], column: [UInt16], color: [UInt8],
         segmentStart: [Int32], segments: [LaneSegment], laneCount: [UInt16], includesWorkingTree: Bool = false,
         workingRow: WorkingRow? = nil, mainBranch: String? = nil) {
        self.graph = graph
        self.scope = scope
        self.includesWorkingTree = includesWorkingTree
        self.workingRow = workingRow
        self.mainBranch = mainBranch
        self.rows = rows
        self.rowOfCommit = rowOfCommit
        self.column = column
        self.color = color
        self.segmentStart = segmentStart
        self.segments = segments
        self.laneCount = laneCount

        // Size for the 95th percentile so a few very busy rows don't make the column huge.
        var histogram = [Int](repeating: 0, count: 257)
        for lanes in laneCount { histogram[min(Int(lanes), 256)] += 1 }
        let target = Int(Double(laneCount.count) * 0.95)
        var seen = 0
        var p95 = 1
        for (lanes, rowsWithLanes) in histogram.enumerated() {
            seen += rowsWithLanes
            if seen >= target { p95 = lanes; break }
        }
        self.suggestedLaneCount = max(1, p95)
    }

    var rowCount: Int { rows.count }

    func segments(inRow row: Int) -> ArraySlice<LaneSegment> {
        segments[Int(segmentStart[row])..<Int(segmentStart[row + 1])]
    }
}

enum LaneLayoutEngine {
    /// Number of lane colors; matches `LanePalette`.
    static let colorCount = 8
    /// The main line's color, which no other lane takes.
    static let mainColor: UInt8 = 0

    /// `workingTree`: a row above the history for uncommitted changes, with a dashed line down to
    /// HEAD's commit. When HEAD is the newest commit (the usual case) the rest of the graph is laid
    /// out as without it; branches newer than HEAD that lead to it join the line.
    /// `mainBranch`: the branch drawn as the trunk (see `MainBranch`). Its tip and first parents keep
    /// the first lane and `mainColor` all the way down, whatever else leads to them; above its tip
    /// that lane stays empty, so the line never moves.
    static func layout(graph: CommitGraph, scope: GraphScope, workingTree: Bool = false, mainBranch: String? = nil) -> GraphLayout {
        let rows = visibleCommits(graph: graph, scope: scope)
        let rowCount = rows.count
        var rowOfCommit = [Int32](repeating: -1, count: graph.count)
        for (row, commit) in rows.enumerated() { rowOfCommit[Int(commit)] = Int32(row) }

        // The main line, from the newest of its commits the scope shows.
        var onMain = [Bool](repeating: false, count: graph.count)
        var mainStart: Int32 = -1
        var mainCommit = mainBranch.map { MainBranch.tip(of: $0, in: graph) } ?? -1
        while mainCommit >= 0 {
            if rowOfCommit[Int(mainCommit)] >= 0 {
                onMain[Int(mainCommit)] = true
                if mainStart < 0 { mainStart = mainCommit }
            }
            mainCommit = graph.parents(mainCommit).first ?? -1
        }

        var column = [UInt16](repeating: 0, count: rowCount)
        var color = [UInt8](repeating: 0, count: rowCount)
        var laneCount = [UInt16](repeating: 0, count: rowCount)
        var segmentStart = [Int32](repeating: 0, count: rowCount + 1)
        var segments: [LaneSegment] = []
        segments.reserveCapacity(rowCount * 5)

        // Each lane waits for the next commit it should reach (-1 = free slot). The first is the
        // main line's, held empty (`reserved`) above its newest commit.
        let reserved: Int32 = -2
        var lanes: [Int32] = []
        var laneColor: [UInt8] = []
        var laneBirth: [Int32] = []
        var nextColor = 0
        var parents: [Int32] = []

        /// The other colors, in turn.
        func branchColor() -> UInt8 {
            defer { nextColor += 1 }
            return UInt8(1 + nextColor % (colorCount - 1))
        }

        func allocate(_ row: Int) -> Int {
            let lane: Int
            if let free = lanes.firstIndex(of: -1) {
                lane = free
            } else {
                lanes.append(-1)
                laneColor.append(0)
                laneBirth.append(0)
                lane = lanes.count - 1
            }
            laneColor[lane] = branchColor()
            laneBirth[lane] = Int32(row)
            return lane
        }

        if mainStart >= 0 {
            lanes.append(reserved)
            laneColor.append(mainColor)
            laneBirth.append(.min)
        }

        // The line from uncommitted changes: the main line's lane when HEAD is its newest commit,
        // else a lane of its own, waiting for HEAD's commit. Born last, it never keeps HEAD's column
        // from a branch that already leads there.
        var workingRow: WorkingRow?
        var workingLane = -1
        let head = graph.headCommit
        if workingTree {
            if head >= 0 && rowOfCommit[Int(head)] >= 0 {
                if head == mainStart {
                    workingLane = 0
                    lanes[0] = head
                } else {
                    workingLane = lanes.count
                    lanes.append(head)
                    laneColor.append(0)
                    laneBirth.append(.max)
                }
                let lane = UInt16(workingLane)
                workingRow = WorkingRow(column: lane, segments: [LaneSegment(from: lane, to: lane, kind: .outgoing, color: LaneSegment.uncommittedColor)])
            } else if head < 0 {
                // Before the first commit there's nothing to lead to.
                workingRow = WorkingRow(column: 0, segments: [])
            }
        }

        for row in 0..<rowCount {
            segmentStart[row] = Int32(segments.count)
            let commit = rows[row]
            let isMain = onMain[Int(commit)]

            // The main line keeps its lane. Elsewhere the longest-lived lane waiting for the commit
            // keeps it.
            var mine = isMain ? 0 : -1
            if !isMain {
                for lane in 0..<lanes.count where lanes[lane] == commit {
                    if mine < 0 || laneBirth[lane] < laneBirth[mine] { mine = lane }
                }
            }
            if mine < 0 {
                mine = allocate(row)
            } else if mine == workingLane && !isMain {
                // Only the line from uncommitted changes leads here: HEAD's lane starts now, with a
                // color of its own.
                laneColor[mine] = branchColor()
                laneBirth[mine] = Int32(row)
            }
            let dotColor = laneColor[mine]

            for lane in 0..<lanes.count {
                let color = lane == workingLane ? LaneSegment.uncommittedColor : laneColor[lane]
                if lanes[lane] == commit {
                    segments.append(LaneSegment(from: UInt16(lane), to: UInt16(mine), kind: .incoming, color: color))
                    lanes[lane] = -1
                    if lane == workingLane { workingLane = -1 }
                } else if lanes[lane] >= 0 {
                    segments.append(LaneSegment(from: UInt16(lane), to: UInt16(lane), kind: .through, color: color))
                }
            }
            lanes[mine] = -1

            parents.removeAll(keepingCapacity: true)
            for parent in graph.parents(commit) where parent >= 0 && rowOfCommit[Int(parent)] >= 0 {
                parents.append(parent)
            }
            if let first = parents.first {
                if isMain {
                    // Down to the first commit, even when a branch started from the parent already
                    // leads there: that branch joins the main line at the parent instead.
                    lanes[mine] = first
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(mine), kind: .outgoing, color: dotColor))
                } else if let existing = lanes.firstIndex(of: first) {
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(existing), kind: .outgoing, color: dotColor))
                } else {
                    lanes[mine] = first
                    laneColor[mine] = dotColor
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(mine), kind: .outgoing, color: dotColor))
                }
                for parent in parents.dropFirst() {
                    // A lane already leading there, but not the line from uncommitted changes: it
                    // has no color of its own yet.
                    var lane = lanes.indices.first { lanes[$0] == parent && $0 != workingLane } ?? -1
                    if lane < 0 {
                        lane = allocate(row)
                        lanes[lane] = parent
                    }
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(lane), kind: .outgoing, color: laneColor[lane]))
                }
            }

            while let last = lanes.last, last == -1 {
                lanes.removeLast()
                laneColor.removeLast()
                laneBirth.removeLast()
            }

            var width = max(lanes.count, mine + 1)
            for k in Int(segmentStart[row])..<segments.count {
                width = max(width, Int(segments[k].from) + 1, Int(segments[k].to) + 1)
            }
            column[row] = UInt16(mine)
            color[row] = dotColor
            laneCount[row] = UInt16(min(width, Int(UInt16.max)))
        }
        segmentStart[rowCount] = Int32(segments.count)

        return GraphLayout(graph: graph, scope: scope, rows: rows, rowOfCommit: rowOfCommit, column: column, color: color,
                           segmentStart: segmentStart, segments: segments, laneCount: laneCount, includesWorkingTree: workingTree,
                           workingRow: workingRow, mainBranch: mainBranch)
    }

    /// Commits reachable from the scope's refs, in history order.
    static func visibleCommits(graph: CommitGraph, scope: GraphScope) -> [Int32] {
        let count = graph.count
        let heads: [Int32]
        switch scope {
        case .all:
            return Array(0..<Int32(count))
        case .local:
            // Local branches, and what each worktree has checked out (a detached HEAD too).
            heads = graph.refs.filter { $0.kind == .local }.map(\.commit) + graph.worktrees.map(\.commit).filter { $0 >= 0 }
        case .head:
            heads = graph.headCommit >= 0 ? [graph.headCommit] : []
        case .ref(let fullName):
            heads = graph.refs.filter { $0.fullName == fullName }.map(\.commit)
        }
        var reachable = [Bool](repeating: false, count: count)
        var stack = heads
        while let commit = stack.popLast() {
            let i = Int(commit)
            if reachable[i] { continue }
            reachable[i] = true
            for parent in graph.parents(commit) where parent >= 0 && !reachable[Int(parent)] {
                stack.append(parent)
            }
        }
        var rows: [Int32] = []
        rows.reserveCapacity(count)
        for i in 0..<count where reachable[i] { rows.append(Int32(i)) }
        return rows
    }
}
