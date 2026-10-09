import SwiftUI

/// A contribution grid per repository: one square per day, shaded by how many commits it has.
/// Hover a day to see its tickets and commits; click to keep it; click a commit to select it in the graph.
struct ActivityWindow: View {
    let repositoryID: UUID?

    var body: some View {
        if let repositoryID, let repository = RepositoryLibrary.shared.repository(id: repositoryID) {
            ActivityView(model: RepositoryModelStore.shared.model(for: repository))
        } else {
            ContentUnavailableView("No Repository", systemImage: "calendar",
                                   description: Text("This repository is no longer in GitTree."))
        }
    }
}

private struct ActivityView: View {
    let model: RepositoryModel

    @State private var period: ActivityPeriod = .lastTwelveMonths
    @State private var scope: GraphScope = .all
    @State private var author: Int32?
    @State private var activity: ActivityData?
    @State private var authors: [(index: Int32, name: String, count: Int)] = []
    @State private var years: [Int] = []
    @State private var catalog = FeatureCatalog()
    @State private var hovered: Date?
    @State private var pinned: Date?

    private static let cell: CGFloat = 13
    private static let gap: CGFloat = 3

    private var shownDay: Date? { hovered ?? pinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activity {
                ScrollView(.horizontal) {
                    grid(activity)
                        .padding(16)
                }
                legend(activity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                Divider()
                DayDetails(activity: activity, day: shownDay, isPinned: pinned != nil && hovered == nil,
                           catalog: catalog, repositoryID: model.id)
            } else if case .failed(let message) = model.status {
                ContentUnavailableView("Can't Read This Repository", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ProgressView("Reading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(model.repository.name)
        .toolbar { toolbar }
        .onAppear { model.loadIfNeeded() }
        .task(id: TaskKey(period: period, scope: scope, author: author, generation: model.generation)) {
            guard let graph = model.graph else { return }
            let (period, scope, author) = (self.period, self.scope, self.author)
            let built = await Task.detached(priority: .userInitiated) {
                ActivityData.build(graph: graph, scope: scope, author: author, period: period)
            }.value
            if authors.isEmpty || activity?.graph !== graph {
                authors = ActivityData.authors(in: graph)
                years = ActivityData.years(in: graph)
                let repositoryID = model.id
                catalog = await Task.detached { FeatureCatalog.load(repositoryID: repositoryID) }.value
            }
            activity = built
        }
    }

    private struct TaskKey: Hashable {
        let period: ActivityPeriod
        let scope: GraphScope
        let author: Int32?
        let generation: Int
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Period", selection: $period) {
                Text(ActivityPeriod.lastTwelveMonths.title).tag(ActivityPeriod.lastTwelveMonths)
                Divider()
                ForEach(years, id: \.self) { year in
                    Text(verbatim: String(year)).tag(ActivityPeriod.year(year))
                }
            }
            .help("Which year to show")
        }
        ToolbarItem {
            Picker("Branches", selection: $scope) {
                Text("All Branches").tag(GraphScope.all)
                Text("Local Branches").tag(GraphScope.local)
                Text("Current Branch").tag(GraphScope.head)
            }
            .help("Which branches' commits to count")
        }
        ToolbarItem {
            Picker("Author", selection: $author) {
                Text("Everyone").tag(Int32?.none)
                Divider()
                ForEach(authors.prefix(60), id: \.index) { entry in
                    Text(verbatim: "\(entry.name) (\(entry.count))").tag(Int32?.some(entry.index))
                }
            }
            .help("Only count one person's commits")
        }
    }

    private func grid(_ activity: ActivityData) -> some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let firstWeekday = calendar.firstWeekday - 1
        return VStack(alignment: .leading, spacing: 4) {
            // Month labels above the week where each month starts.
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: 28, height: 12)
                ForEach(0..<activity.weeks, id: \.self) { week in
                    let first = activity.date(week: week, weekday: 0)
                    let last = activity.date(week: week, weekday: 6)
                    let startsMonth = calendar.component(.month, from: first) != calendar.component(.month, from: last)
                        || calendar.component(.day, from: first) == 1 || week == 0
                    Text(startsMonth ? last.formatted(.dateTime.month(.abbreviated)) : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: Self.cell, height: 12, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(alignment: .trailing, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        Text(weekday % 2 == 1 ? symbols[(firstWeekday + weekday) % 7] : "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: Self.cell, alignment: .trailing)
                    }
                }
                ForEach(0..<activity.weeks, id: \.self) { week in
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            dayCell(activity, date: activity.date(week: week, weekday: weekday))
                        }
                    }
                }
            }
        }
        .onHover { inside in if !inside { hovered = nil } }
    }

    private func dayCell(_ activity: ActivityData, date: Date) -> some View {
        let inPeriod = date >= activity.periodStart && date <= activity.periodEnd
        let count = activity.commits(on: date).count
        let isShown = date == shownDay
        return RoundedRectangle(cornerRadius: 2.5)
            .fill(inPeriod ? Self.color(level: activity.level(count)) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(isShown ? Color.primary.opacity(0.8) : Color.clear, lineWidth: 1.5)
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
            .onHover { inside in if inside && inPeriod { hovered = date } }
            .onTapGesture { if inPeriod { pinned = pinned == date ? nil : date } }
            .help(inPeriod ? "\(date.formatted(date: .abbreviated, time: .omitted)): \(counted(count, "commit", "commits"))" : "")
    }

    private func legend(_ activity: ActivityData) -> some View {
        HStack(spacing: 14) {
            Text("\(counted(activity.total, "commit", "commits")) on \(counted(activity.activeDays, "day", "days"))")
            if let busiest = activity.busiest {
                Text("Busiest: \(busiest.day.formatted(date: .abbreviated, time: .omitted)) with \(busiest.count)")
            }
            Spacer()
            HStack(spacing: 3) {
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Self.color(level: level))
                        .frame(width: 11, height: 11)
                }
                Text("More")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    static func color(level: Int) -> Color {
        switch level {
        case 0: Color.secondary.opacity(0.13)
        case 1: Color.green.opacity(0.32)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.78)
        default: Color.green
        }
    }
}

/// The hovered (or clicked) day: its tickets grouped under their terms, then its commits.
private struct DayDetails: View {
    let activity: ActivityData
    let day: Date?
    let isPinned: Bool
    let catalog: FeatureCatalog
    let repositoryID: UUID

    var body: some View {
        if let day {
            let commits = activity.commits(on: day)
            let graph = activity.graph
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(day.formatted(date: .complete, time: .omitted))
                            .font(.headline)
                        Text(counted(commits.count, "commit", "commits"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isPinned {
                            Label("Pinned — click the day again to release", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let tickets = ticketCounts(commits, graph: graph)
                    if !tickets.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(tickets, id: \.key) { ticket in
                                HStack(spacing: 4) {
                                    if let term = ticket.term {
                                        Text(term).foregroundStyle(.secondary)
                                        Text("·").foregroundStyle(.tertiary)
                                    }
                                    Text(verbatim: ticket.key).monospaced()
                                    Text(verbatim: "\(ticket.count)").foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(commits.prefix(80)), id: \.self) { commit in
                            Button {
                                NotificationCenter.default.post(name: .gitTreeRevealCommit, object: nil, userInfo: [
                                    "repository": repositoryID, "commit": graph.ids[Int(commit)].hex,
                                ])
                            } label: {
                                HStack(spacing: 10) {
                                    Text(graph.date(of: commit), format: .dateTime.hour().minute())
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(graph.subjects[Int(commit)])
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(graph.authors[Int(graph.authorOf[Int(commit)])])
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Select this commit in the graph")
                        }
                        if commits.count > 80 {
                            Text("\(commits.count - 80) more").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Hover over a day to see its tickets and commits; click a day to keep it here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        }
    }

    /// Ticket keys mentioned that day, busiest first, with the term each belongs to.
    private func ticketCounts(_ commits: [Int32], graph: CommitGraph) -> [(key: String, term: String?, count: Int)] {
        var counts: [String: Int] = [:]
        for commit in commits {
            for key in graph.ticketKeys(in: graph.subjects[Int(commit)]).prefix(1) {
                counts[key, default: 0] += 1
            }
        }
        return counts
            .map { key, count in
                let term = catalog.assignments["ticket:\(key)"].flatMap { catalog.terms[$0]?.name }
                return (key, term, count)
            }
            .sorted { $0.count > $1.count }
    }
}
