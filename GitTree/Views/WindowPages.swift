import AppKit
import SwiftUI

/// What a repository's window shows over its history: changes, a comparison or the activity
/// calendar. Back takes off the top one; the history is always under them.
enum GraphPage: Identifiable {
    case changes(DiffSession)
    case comparison(ComparisonPage)
    case activity(UUID)

    var id: AnyHashable {
        switch self {
        case .changes(let session): ObjectIdentifier(session)
        case .comparison(let page): ObjectIdentifier(page)
        case .activity(let id): id
        }
    }

    /// The narrowest it's useful at, next to what's under it.
    var minimumWidth: CGFloat {
        switch self {
        case .changes: 520
        case .comparison, .activity: 640
        }
    }
}

/// A comparison shown in the window; its toolbar picks other branches.
@MainActor @Observable final class ComparisonPage {
    var target: CompareTarget

    init(target: CompareTarget) {
        self.target = target
    }
}

/// What a comparison or the activity calendar does with what's picked in it while it's in the
/// repository's window. In a window of its own there are none, and it asks the repository's
/// windows instead.
struct PageActions {
    /// A commit, by hash, for the details.
    var selectCommit: @MainActor (String) -> Void
    /// Commits to tint in the history, which is then shown.
    var highlightCommits: @MainActor (_ hashes: [String], _ title: String) -> Void
    /// Changes over the page.
    var showChanges: @MainActor (DiffTarget) -> Void
}

extension EnvironmentValues {
    @Entry var pageActions: PageActions?
}

extension View {
    /// The window's title, for a view in a window of its own. In the repository's window the
    /// repository's name stays.
    @ViewBuilder func windowTitle(_ title: String, subtitle: String, shown: Bool) -> some View {
        if shown {
            navigationTitle(title).navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

/// Where the history and the pages over it go: the top one takes the whole width, or, when there's
/// room for both, the top two share it, the one under on the left.
struct PaneLayout {
    let width: CGFloat
    /// The narrowest each one is useful at: the history, then the pages bottom to top.
    let minimumWidths: [CGFloat]
    /// The left one's share of the width when two are side by side.
    let split: Double

    static let dividerWidth: CGFloat = 1
    static let space = "panes"

    private var top: Int { minimumWidths.count - 1 }

    /// The top two side by side.
    var isSplit: Bool {
        top > 0 && width >= minimumWidths[top - 1] + minimumWidths[top] + Self.dividerWidth
    }

    private var leftRange: ClosedRange<CGFloat> {
        minimumWidths[top - 1]...(width - minimumWidths[top] - Self.dividerWidth)
    }

    private var leftWidth: CGFloat {
        min(max((width * split).rounded(), leftRange.lowerBound), leftRange.upperBound)
    }

    /// Where the line between them is, when two are side by side.
    var dividerX: CGFloat? { isSplit ? leftWidth : nil }

    /// Level 0 is the history, 1 and up the pages.
    func isVisible(_ level: Int) -> Bool {
        level == top || (isSplit && level == top - 1)
    }

    /// Its offset and width. One that isn't shown keeps the whole width.
    func frame(of level: Int) -> (x: CGFloat, width: CGFloat) {
        guard isSplit else { return (0, width) }
        if level == top - 1 { return (0, leftWidth) }
        if level == top { return (leftWidth + Self.dividerWidth, width - leftWidth - Self.dividerWidth) }
        return (0, width)
    }

    /// The share that puts the line at `x`, within both minimums.
    func split(forDividerAt x: CGFloat) -> Double {
        guard isSplit, width > 0 else { return split }
        return Double(min(max(x, leftRange.lowerBound), leftRange.upperBound) / width)
    }
}

/// The line between two panes side by side; dragging it shares the width differently.
struct PaneDivider: View {
    let layout: PaneLayout
    @Binding var split: Double
    @State private var isHovering = false

    var body: some View {
        Color(nsColor: .separatorColor)
            .frame(width: PaneLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            // A wider area to grab than the line.
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHovering else { return }
                isHovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovering { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(PaneLayout.space)).onChanged { value in
                split = layout.split(forDividerAt: value.location.x)
            })
    }
}
