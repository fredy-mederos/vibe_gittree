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
        case .all: "All Branches"
        case .local: "Local Branches"
        case .head: "Current Branch"
        case .ref(let name): "Only \(GitRef.shortName(fullName: name))"
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

    init(graph: CommitGraph, scope: GraphScope, rows: [Int32], rowOfCommit: [Int32], column: [UInt16], color: [UInt8],
         segmentStart: [Int32], segments: [LaneSegment], laneCount: [UInt16]) {
        self.graph = graph
        self.scope = scope
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

    static func layout(graph: CommitGraph, scope: GraphScope) -> GraphLayout {
        let rows = visibleCommits(graph: graph, scope: scope)
        let rowCount = rows.count
        var rowOfCommit = [Int32](repeating: -1, count: graph.count)
        for (row, commit) in rows.enumerated() { rowOfCommit[Int(commit)] = Int32(row) }

        var column = [UInt16](repeating: 0, count: rowCount)
        var color = [UInt8](repeating: 0, count: rowCount)
        var laneCount = [UInt16](repeating: 0, count: rowCount)
        var segmentStart = [Int32](repeating: 0, count: rowCount + 1)
        var segments: [LaneSegment] = []
        segments.reserveCapacity(rowCount * 5)

        // Each lane waits for the next commit it should reach (-1 = free slot).
        var lanes: [Int32] = []
        var laneColor: [UInt8] = []
        var laneBirth: [Int32] = []
        var nextColor = 0
        var parents: [Int32] = []

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
            laneColor[lane] = UInt8(nextColor % colorCount)
            laneBirth[lane] = Int32(row)
            nextColor += 1
            return lane
        }

        for row in 0..<rowCount {
            segmentStart[row] = Int32(segments.count)
            let commit = rows[row]

            // The longest-lived lane waiting for this commit keeps it, so mainlines like develop
            // hold their column and color.
            var mine = -1
            for lane in 0..<lanes.count where lanes[lane] == commit {
                if mine < 0 || laneBirth[lane] < laneBirth[mine] { mine = lane }
            }
            if mine < 0 { mine = allocate(row) }
            let dotColor = laneColor[mine]

            for lane in 0..<lanes.count {
                if lanes[lane] == commit {
                    segments.append(LaneSegment(from: UInt16(lane), to: UInt16(mine), kind: .incoming, color: laneColor[lane]))
                    lanes[lane] = -1
                } else if lanes[lane] >= 0 {
                    segments.append(LaneSegment(from: UInt16(lane), to: UInt16(lane), kind: .through, color: laneColor[lane]))
                }
            }
            lanes[mine] = -1

            parents.removeAll(keepingCapacity: true)
            for parent in graph.parents(commit) where parent >= 0 && rowOfCommit[Int(parent)] >= 0 {
                parents.append(parent)
            }
            if let first = parents.first {
                if let existing = lanes.firstIndex(of: first) {
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(existing), kind: .outgoing, color: dotColor))
                } else {
                    lanes[mine] = first
                    laneColor[mine] = dotColor
                    segments.append(LaneSegment(from: UInt16(mine), to: UInt16(mine), kind: .outgoing, color: dotColor))
                }
                for parent in parents.dropFirst() {
                    var lane = lanes.firstIndex(of: parent) ?? -1
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
                           segmentStart: segmentStart, segments: segments, laneCount: laneCount)
    }

    /// Commits reachable from the scope's refs, in history order.
    static func visibleCommits(graph: CommitGraph, scope: GraphScope) -> [Int32] {
        let count = graph.count
        let heads: [Int32]
        switch scope {
        case .all:
            return Array(0..<Int32(count))
        case .local:
            heads = graph.refs.filter { $0.kind == .local }.map(\.commit)
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
