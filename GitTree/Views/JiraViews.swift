import SwiftUI

/// A ticket's type as an SF Symbol in Jira's colors: a purple bolt for epics, a green bookmark for
/// stories, a blue check for tasks, a red bug for bugs. White on a selected row.
struct IssueTypeIcon: View {
    let type: String?
    let level: Int?

    var body: some View {
        Image(systemName: style.symbol)
            .foregroundStyle(style.color, selected: .primary)
            .help(type ?? String(localized: "Ticket"))
    }

    private var style: (symbol: String, color: Color) {
        let name = type?.lowercased() ?? ""
        if (level ?? 0) >= 1 || name == "epic" { return ("bolt.fill", .purple) }
        if (level ?? 0) < 0 || name.contains("sub") { return ("arrow.turn.down.right", .blue) }
        if name.contains("bug") { return ("ladybug.fill", .red) }
        if name.contains("story") { return ("bookmark.fill", .green) }
        if name.contains("task") { return ("checkmark.square.fill", .blue) }
        return ("ticket", .secondary)
    }
}

/// A ticket's status in its category's color, as text (white on a selected row).
struct IssueStatusText: View {
    let status: String
    let category: JiraIssue.Category

    var body: some View {
        Text(status)
            .foregroundStyle(Color(nsColor: category.color.readable), selected: .primary)
    }
}

/// How far a fix version or an epic is: done in green (with a Definition of Done, its statuses
/// too), in progress in blue, the rest gray. On a selected row, shades of white instead.
struct TicketProgressBar: View {
    let progress: TicketProgress
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        GeometryReader { proxy in
            let total = max(1, CGFloat(progress.total))
            HStack(spacing: 0) {
                Rectangle().fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
                    .frame(width: proxy.size.width * CGFloat(progress.done) / total)
                Rectangle().fill(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.blue))
                    .frame(width: proxy.size.width * CGFloat(progress.inProgress) / total)
                Rectangle().fill(selected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.secondary.opacity(0.25)))
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("\(progress.done) of \(progress.total) tickets done, \(progress.inProgress) in progress")
    }
}

/// The bar with "5/8 done" after it, in a fix version's or an epic's row.
struct TicketProgressLabel: View {
    let progress: TicketProgress

    var body: some View {
        HStack(spacing: 6) {
            TicketProgressBar(progress: progress)
                .frame(maxWidth: 80)
            Text("\(progress.done)/\(progress.total) done", comment: "Tickets done out of all of them, as in 5/8 done")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

extension TicketProgress {
    /// "5 of 8 tickets done · 2 in progress".
    var summary: String? {
        guard total > 0 else { return nil }
        let tickets = String(localized: "\(total) tickets")
        var text = String(localized: "\(done) of \(tickets) done", comment: "5 of 8 tickets done")
        if inProgress > 0 { text += " · " + String(localized: "\(inProgress) in progress", comment: "Tickets in progress") }
        return text
    }
}

extension JiraVersion {
    /// "Oct 13", or "Oct 13, 2027" when it isn't this year.
    var shortReleaseDate: String? {
        guard let day = releaseDay else { return nil }
        let sameYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        return sameYear ? day.formatted(.dateTime.month(.abbreviated).day())
            : day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "5 of 8 tickets done · 2 in progress".
    var progressSummary: String? { progress?.summary }
}
