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
                                   description: Text("This repository is no longer in Vibe GitTree."))
        }
    }
}

/// The calendar in the repository's window, over its history or next to it.
struct ActivityPageView: View {
    let model: RepositoryModel
    /// On screen: only then are its pickers in the window's toolbar.
    let isActive: Bool

    var body: some View {
        ActivityView(model: model, isEmbedded: true, isActive: isActive)
    }
}

private struct ActivityView: View {
    let model: RepositoryModel
    /// In the repository's window: no title of its own.
    var isEmbedded = false
    var isActive = true

    @State private var period: ActivityPeriod = .lastTwelveMonths
    @State private var scope: GraphScope = .all
    /// By name, so the filter survives reloads (author numbers follow the history's order).
    @State private var author: String?
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
                // Narrower than the year (next to the history, say): the latest weeks first.
                .defaultScrollAnchor(.trailing)
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
        .windowTitle(String(localized: "Activity"), subtitle: model.repository.name, shown: !isEmbedded)
        .toolbar {
            if isActive { toolbar }
        }
        .onAppear { model.loadIfNeeded() }
        .task(id: TaskKey(period: period, scope: scope, author: author, generation: model.generation)) {
            guard let graph = model.graph else { return }
            let (period, scope, author) = (self.period, self.scope, self.author)
            let built = await Task.detached(priority: .userInitiated) {
                // An author no longer in the history matches nothing.
                let index = author.map { name in graph.authors.firstIndex(of: name).map(Int32.init) ?? -1 }
                return ActivityData.build(graph: graph, scope: scope, author: index, period: period)
            }.value
            if authors.isEmpty || activity?.graph !== graph {
                authors = ActivityData.authors(in: graph)
                years = ActivityData.years(in: graph)
                // Tickets' terms come from grouping features, when that's on in Settings.
                let repositoryID = model.id
                catalog = UserDefaults.standard.bool(forKey: AppSettings.groupsFeaturesKey)
                    ? await Task.detached { FeatureCatalog.load(repositoryID: repositoryID) }.value
                    : FeatureCatalog()
            }
            activity = built
        }
    }

    private struct TaskKey: Hashable {
        let period: ActivityPeriod
        let scope: GraphScope
        let author: String?
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
                Text("Everyone").tag(String?.none)
                Divider()
                ForEach(authors.prefix(60), id: \.index) { entry in
                    Text(verbatim: "\(entry.name) (\(entry.count))").tag(String?.some(entry.name))
                }
                // Someone outside the top 60 stays selectable once picked.
                if let author, !authors.prefix(60).contains(where: { $0.name == author }) {
                    Text(verbatim: author).tag(String?.some(author))
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
            let monthLabels = activity.monthLabels
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: 28, height: 12)
                ForEach(0..<activity.weeks, id: \.self) { week in
                    Text(monthLabels[week] ?? "")
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
            .help(inPeriod ? String(localized: "\(date.formatted(date: .abbreviated, time: .omitted)): \(count) commits", comment: "A day and its commits") : "")
    }

    private func legend(_ activity: ActivityData) -> some View {
        HStack(spacing: 14) {
            let commits = String(localized: "\(activity.total) commits")
            Text("\(commits) on \(activity.activeDays) days", comment: "1,234 commits on 210 days")
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
    @Environment(\.pageActions) private var actions

    var body: some View {
        if let day {
            let commits = activity.commits(on: day)
            let graph = activity.graph
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(day.formatted(date: .complete, time: .omitted))
                            .font(.headline)
                        Text("\(commits.count) commits")
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
                                        Text(verbatim: "·").foregroundStyle(.tertiary)
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
                                if let actions { return actions.selectCommit(graph.ids[Int(commit)].hex) }
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
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }
}
