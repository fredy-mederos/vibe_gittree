import Foundation

/// Which year the activity calendar shows.
enum ActivityPeriod: Hashable {
    case lastTwelveMonths
    case year(Int)

    var title: String {
        switch self {
        case .lastTwelveMonths: String(localized: "Last 12 Months")
        case .year(let year): String(year)
        }
    }
}

/// Commits per day for the activity calendar, laid out in week columns like GitHub's contribution grid.
struct ActivityData: Sendable {
    let graph: CommitGraph
    /// First day of the first week column.
    let gridStart: Date
    let weeks: Int
    /// The period's own bounds; days outside are drawn empty.
    let periodStart: Date
    let periodEnd: Date
    /// Day (start of day) → commits that day, newest first.
    let days: [Date: [Int32]]
    /// Commit counts at which a day reaches levels 2, 3 and 4 (level 1 is any commit).
    let thresholds: [Int]
    let total: Int
    let busiest: (day: Date, count: Int)?

    var activeDays: Int { days.count }

    func commits(on day: Date) -> [Int32] {
        days[day] ?? []
    }

    /// 0 for no commits, then 1–4 by quartile of the busier days.
    func level(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return 1 + thresholds.filter { count >= $0 }.count
    }

    func date(week: Int, weekday: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: week * 7 + weekday, to: gridStart) ?? gridStart
    }

    /// Month names above the grid, by week column: the period's first month, then each month in the
    /// week where its first day falls, never past the period and never crowding the previous label.
    var monthLabels: [Int: String] {
        let calendar = Calendar.current
        var labels: [Int: String] = [:]
        var lastWeek: Int?
        for week in 0..<weeks {
            var labelDay: Date?
            for weekday in 0..<7 {
                let day = date(week: week, weekday: weekday)
                guard day >= periodStart, day <= periodEnd else { continue }
                if day == periodStart || calendar.component(.day, from: day) == 1 {
                    labelDay = day
                    break
                }
            }
            guard let labelDay else { continue }
            if let previous = lastWeek, week - previous < 3 {
                // Too close: a real month start wins over the partial first month.
                guard previous == 0 else { continue }
                labels[previous] = nil
            }
            labels[week] = labelDay.formatted(.dateTime.month(.abbreviated))
            lastWeek = week
        }
        return labels
    }

    static func build(graph: CommitGraph, scope: GraphScope, author: Int32?, period: ActivityPeriod) -> ActivityData {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let periodStart: Date
        let periodEnd: Date
        switch period {
        case .lastTwelveMonths:
            periodEnd = today
            periodStart = calendar.date(byAdding: .day, value: 1, to: calendar.date(byAdding: .year, value: -1, to: today) ?? today) ?? today
        case .year(let year):
            periodStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
            periodEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? today
        }
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: periodStart)?.start ?? periodStart
        let weeks = (calendar.dateComponents([.day], from: gridStart, to: periodEnd).day ?? 0) / 7 + 1

        let commits: [Int32]
        if case .all = scope {
            commits = Array(0..<Int32(graph.count))
        } else {
            commits = LaneLayoutEngine.visibleCommits(graph: graph, scope: scope)
        }
        let lower = periodStart.timeIntervalSince1970
        let upper = (calendar.date(byAdding: .day, value: 1, to: periodEnd) ?? periodEnd).timeIntervalSince1970
        var days: [Date: [Int32]] = [:]
        for commit in commits {
            let time = TimeInterval(graph.times[Int(commit)])
            guard time >= lower, time < upper, !graph.isMerge(commit) else { continue }
            if let author, graph.authorOf[Int(commit)] != author { continue }
            days[calendar.startOfDay(for: Date(timeIntervalSince1970: time)), default: []].append(commit)
        }

        let counts = days.values.map(\.count).sorted()
        let thresholds: [Int] = counts.isEmpty ? [] : [0.25, 0.5, 0.75].map { fraction in
            max(2, counts[min(counts.count - 1, Int(Double(counts.count) * fraction))])
        }
        // Ties go to the most recent day, so the summary doesn't change between rebuilds.
        let busiest = days.max { ($0.value.count, $0.key) < ($1.value.count, $1.key) }.map { (day: $0.key, count: $0.value.count) }
        return ActivityData(graph: graph, gridStart: gridStart, weeks: weeks, periodStart: periodStart, periodEnd: periodEnd,
                            days: days, thresholds: thresholds, total: counts.reduce(0, +), busiest: busiest)
    }

    /// Authors by number of commits, for the author filter.
    static func authors(in graph: CommitGraph) -> [(index: Int32, name: String, count: Int)] {
        var counts = [Int](repeating: 0, count: graph.authors.count)
        for author in graph.authorOf { counts[Int(author)] += 1 }
        return counts.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element != $1.element ? $0.element > $1.element : graph.authors[$0.offset] < graph.authors[$1.offset] }
            .map { (Int32($0.offset), graph.authors[$0.offset], $0.element) }
    }

    /// Years that have commits, newest first.
    static func years(in graph: CommitGraph) -> [Int] {
        guard let oldest = graph.times.min(), let newest = graph.times.max() else { return [] }
        let calendar = Calendar.current
        let first = calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(oldest)))
        let last = calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(newest)))
        return Array((first...max(first, last)).reversed())
    }
}

extension Notification.Name {
    /// Asks the windows showing a repository to select a commit. userInfo: repository (UUID), commit (hex).
    static let gitTreeRevealCommit = Notification.Name("GitTreeRevealCommit")
}
