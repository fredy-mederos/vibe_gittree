import SwiftUI

/// A pull request's story at a glance: a track from opening to merge (or to now) with a mark per
/// event, the events themselves, and how long it took.
struct PullRequestTimelineView: View {
    let timeline: PullRequestTimeline
    /// Events listed before the rest fold away.
    var limit = 8

    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineTrack(timeline: timeline)
                .frame(height: 12)
            VStack(alignment: .leading, spacing: 3) {
                let events = timeline.events
                if showsAll || events.count <= limit {
                    ForEach(events) { TimelineEventRow(event: $0) }
                } else {
                    // The opening, then the latest events.
                    TimelineEventRow(event: events[0])
                    Button {
                        showsAll = true
                    } label: {
                        Text("\(events.count - limit) earlier events")
                            .font(.caption)
                            .padding(.leading, 18)
                    }
                    .buttonStyle(.link)
                    ForEach(events.suffix(limit - 1)) { TimelineEventRow(event: $0) }
                }
            }
            Text(timeline.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TimelineEventRow: View {
    let event: PullRequestTimeline.Event

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: event.kind.symbol)
                .font(.caption2)
                .foregroundStyle(event.kind.color)
                .frame(width: 12)
            Text(event.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(RelativeAge.short(event.date))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .help(Text(verbatim: "\(event.title)\n\(event.date.formatted(date: .abbreviated, time: .shortened))"))
    }
}

/// The time from opening to merge (or now) as a line, with a dot per event: small gray ones for
/// commits, colored ones for reviews and the merge.
private struct TimelineTrack: View {
    let timeline: PullRequestTimeline

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 5
            let start = timeline.createdAt
            let lastEvent = timeline.events.last?.date ?? start
            let end = timeline.endedAt ?? max(Date(), lastEvent)
            let span = max(end.timeIntervalSince(start), 60)
            let width = max(1, size.width - inset * 2)
            func x(_ date: Date) -> CGFloat {
                inset + width * CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1))
            }
            let middle = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: inset, y: middle))
            line.addLine(to: CGPoint(x: inset + width, y: middle))
            context.stroke(line, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            // Still open: a hollow ring at the end stands for now.
            if timeline.endedAt == nil {
                let ring = CGRect(x: inset + width - 3.5, y: middle - 3.5, width: 7, height: 7)
                context.stroke(Path(ellipseIn: ring), with: .color(.secondary), lineWidth: 1.5)
            }
            // Commits first, so reviews and the merge sit on top.
            for event in timeline.events.sorted(by: { !$0.kind.isMajor && $1.kind.isMajor }) {
                let radius: CGFloat = event.kind.isMajor ? 4 : 2.5
                let rect = CGRect(x: x(event.date) - radius, y: middle - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(event.kind.color))
            }
        }
        .accessibilityHidden(true)
    }
}

extension PullRequestTimeline.Event {
    var title: String {
        let by = actor.map { " by \($0)" } ?? ""
        switch kind {
        case .opened(let commits, let draft):
            let opened = (draft ? "Opened as a draft" : "Opened") + by
            return commits > 0 ? "\(opened) · \(counted(commits, "commit", "commits"))" : opened
        case .commits(let count): return count == 1 ? "New commit" : "\(count) new commits"
        case .forcePushed: return "Force-pushed" + by
        case .reviewRequested(let names): return "Review requested: \(names.joined(separator: ", "))"
        case .approved: return "Approved" + by
        case .changesRequested: return "Changes requested" + by
        case .commented: return "Reviewed with comments" + by
        case .dismissed: return actor.map { "Reviewed by \($0), later dismissed" } ?? "Review dismissed"
        case .readyForReview: return "Ready for review"
        case .convertedToDraft: return "Back to draft"
        case .merged: return "Merged" + by
        case .closed: return "Closed" + by
        case .reopened: return "Reopened" + by
        }
    }
}

extension PullRequestTimeline.Event.Kind {
    var symbol: String {
        switch self {
        case .opened: "arrow.triangle.pull"
        case .commits: "arrow.up.circle.fill"
        case .forcePushed: "exclamationmark.arrow.circlepath"
        case .reviewRequested: "person.badge.clock"
        case .approved: "checkmark.circle.fill"
        case .changesRequested: "exclamationmark.circle.fill"
        case .commented: "text.bubble.fill"
        case .dismissed: "xmark.circle"
        case .readyForReview: "eye.circle.fill"
        case .convertedToDraft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle.fill"
        case .reopened: "arrow.uturn.backward.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .opened, .reopened, .approved: .green
        case .commits, .reviewRequested, .dismissed, .convertedToDraft: .secondary
        case .forcePushed, .changesRequested: .orange
        case .commented, .readyForReview: .blue
        case .merged: .purple
        case .closed: .red
        }
    }

    /// Reviews, the opening and the end get big marks on the track; commits small ones.
    var isMajor: Bool {
        switch self {
        case .commits, .reviewRequested, .dismissed: false
        default: true
        }
    }
}
