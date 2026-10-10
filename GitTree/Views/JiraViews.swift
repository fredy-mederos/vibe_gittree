import SwiftUI

/// A ticket's type as an SF Symbol in Jira's colors: a purple bolt for epics, a green bookmark for
/// stories, a blue check for tasks, a red bug for bugs.
struct IssueTypeIcon: View {
    let type: String?
    let level: Int?

    var body: some View {
        Image(systemName: style.symbol)
            .foregroundStyle(style.color)
            .help(type ?? "Ticket")
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

/// A ticket's status in its category's color, as text.
struct IssueStatusText: View {
    let status: String
    let category: JiraIssue.Category

    var body: some View {
        Text(status)
            .foregroundStyle(Color(nsColor: category.color))
    }
}

/// How far a fix version is: done in green, in progress in blue, the rest gray.
struct ReleaseProgressBar: View {
    let progress: JiraVersion.Progress

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, CGFloat(progress.total))
            HStack(spacing: 0) {
                Rectangle().fill(Color.green).frame(width: proxy.size.width * CGFloat(progress.done) / total)
                Rectangle().fill(Color.blue).frame(width: proxy.size.width * CGFloat(progress.inProgress) / total)
                Rectangle().fill(Color.secondary.opacity(0.25))
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("\(progress.done) of \(progress.total) tickets done, \(progress.inProgress) in progress")
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
    var progressSummary: String? {
        guard let progress, progress.total > 0 else { return nil }
        var text = "\(progress.done) of \(counted(progress.total, "ticket", "tickets")) done"
        if progress.inProgress > 0 { text += " · \(progress.inProgress) in progress" }
        return text
    }
}
