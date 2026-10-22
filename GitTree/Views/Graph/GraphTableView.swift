import AppKit
import SwiftUI

extension PullRequest.Readiness {
    var color: NSColor {
        switch self {
        case .ready, .checksPassed: .systemGreen
        case .checksRunning: .systemOrange
        case .checksFailing: .systemRed
        }
    }
}

private enum ColumnID {
    static let graph = NSUserInterfaceItemIdentifier("graph")
    static let description = NSUserInterfaceItemIdentifier("description")
    static let ticket = NSUserInterfaceItemIdentifier("ticket")
    static let author = NSUserInterfaceItemIdentifier("author")
    static let date = NSUserInterfaceItemIdentifier("date")
    static let commit = NSUserInterfaceItemIdentifier("commit")
}

/// The commit list: an `NSTableView`, which only builds the rows on screen, so histories with
/// hundreds of thousands of commits scroll as smoothly as small ones.
struct GraphTableView: NSViewRepresentable {
    let graph: GraphViewModel
    // Passed explicitly so SwiftUI calls `updateNSView` when they change.
    let layoutVersion: Int
    let selectedCommit: Int32?
    /// The row for uncommitted changes is selected.
    let selectsWorkingTree: Bool
    let revealToken: Int
    let searchVersion: Int
    let showTags: Bool
    /// Pull requests or ticket statuses changed.
    let annotationVersion: Int
    /// The working tree was looked at again (the uncommitted row's counts).
    let workingTreeVersion: Int
    let onShowDetails: () -> Void
    /// Opens a comparison window (two commits picked in the graph, say).
    let onCompare: (CompareTarget) -> Void

    func makeCoordinator() -> GraphTableCoordinator {
        GraphTableCoordinator(graph: graph)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = GraphNSTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = GraphMetrics.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsTypeSelect = false
        // The description column is sized by the coordinator to fill whatever the others leave.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = NSTableHeaderView()

        tableView.addTableColumn(Self.column(ColumnID.graph, title: "Graph", width: 100, minWidth: 24, maxWidth: 800))
        tableView.addTableColumn(Self.column(ColumnID.description, title: "Description", width: 640, minWidth: 220))
        let ticket = Self.column(ColumnID.ticket, title: "Ticket", width: 160, minWidth: 60)
        ticket.isHidden = true  // shown when the repository's tickets are on the connected Jira site
        tableView.addTableColumn(ticket)
        tableView.addTableColumn(Self.column(ColumnID.author, title: "Author", width: 150, minWidth: 60))
        tableView.addTableColumn(Self.column(ColumnID.date, title: "Date", width: 178, minWidth: 80))
        tableView.addTableColumn(Self.column(ColumnID.commit, title: "Commit", width: 84, minWidth: 60))

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(GraphTableCoordinator.doubleClicked(_:))
        tableView.onActivate = { [weak coordinator] in coordinator?.onShowDetails() }
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu
        coordinator.tableView = tableView
        coordinator.onShowDetails = onShowDetails
        coordinator.onCompare = onCompare

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // SwiftUI already keeps the view below the toolbar; automatic insets would add a gap.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(GraphTableCoordinator.visibleAreaDidResize(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(GraphTableCoordinator.visibleAreaDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onShowDetails = onShowDetails
        context.coordinator.onCompare = onCompare
        context.coordinator.update(
            graph: graph,
            layoutVersion: layoutVersion,
            selectedCommit: selectedCommit,
            selectsWorkingTree: selectsWorkingTree,
            revealToken: revealToken,
            searchVersion: searchVersion,
            showTags: showTags,
            annotationVersion: annotationVersion,
            workingTreeVersion: workingTreeVersion
        )
    }

    private static func column(_ id: NSUserInterfaceItemIdentifier, title: String.LocalizationValue, width: CGFloat, minWidth: CGFloat,
                               maxWidth: CGFloat = 10_000) -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = String(localized: title)
        column.width = width
        column.minWidth = minWidth
        column.maxWidth = maxWidth
        column.resizingMask = .userResizingMask
        return column
    }
}

/// Opens the commit's details on Return.
final class GraphNSTableView: NSTableView {
    var onActivate: () -> Void = {}

    /// In dark mode, the system's stripes on the window's darker background (`DarkerWindowBackground`);
    /// the rows leave their background to this.
    override func drawBackground(inClipRect clipRect: NSRect) {
        guard effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
            return super.drawBackground(inClipRect: clipRect)
        }
        NSColor.darkerWindowBackground.setFill()
        clipRect.fill()
        NSColor.alternatingContentBackgroundColors[1].setFill()
        let height = rowHeight + intercellSpacing.height
        for row in max(0, Int(clipRect.minY / height))...max(0, Int(clipRect.maxY / height)) where row % 2 == 1 {
            NSRect(x: clipRect.minX, y: CGFloat(row) * height, width: clipRect.width, height: height).fill(using: .sourceOver)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {  // Return, Enter
            onActivate()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor final class GraphTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private(set) var graph: GraphViewModel
    weak var tableView: NSTableView?
    var onShowDetails: () -> Void = {}
    var onCompare: (CompareTarget) -> Void = { _ in }

    private var layout: GraphLayout?
    private var appliedLayoutVersion = -1
    private var appliedSearchVersion = -1
    private var appliedRevealToken = -1
    private var appliedShowTags = true
    private var appliedAnnotationVersion = -1
    private var appliedWorkingTreeVersion = -1
    private var isApplyingSelection = false
    /// The Jira this repository's tickets live in, when it has one.
    private var jira: JiraConnection?
    private var ticketRequest: DispatchWorkItem?
    private var isFittingColumns = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return formatter
    }()

    init(graph: GraphViewModel) {
        self.graph = graph
    }

    // MARK: Rows

    /// Table rows above the history: one for uncommitted changes, when there are any.
    private var leadingRows: Int { layout?.workingRow == nil ? 0 : 1 }

    /// The layout row (commit) a table row shows; nil for the row of uncommitted changes.
    private func layoutRow(_ row: Int) -> Int? {
        guard let layout else { return nil }
        let index = row - leadingRows
        return index >= 0 && index < layout.rowCount ? index : nil
    }

    private func isWorkingRow(_ row: Int) -> Bool {
        row >= 0 && row < leadingRows
    }

    // MARK: Updates from SwiftUI

    func update(graph newGraph: GraphViewModel, layoutVersion: Int, selectedCommit: Int32?, selectsWorkingTree: Bool, revealToken: Int,
                searchVersion: Int, showTags: Bool, annotationVersion: Int, workingTreeVersion: Int) {
        guard let tableView else { return }
        let switchedRepository = newGraph !== graph
        graph = newGraph
        let changed = switchedRepository || layoutVersion != appliedLayoutVersion || annotationVersion != appliedAnnotationVersion
        if changed {
            updateTicketColumn()
        }

        if switchedRepository || layoutVersion != appliedLayoutVersion {
            let previousLayout = layout
            let anchor = switchedRepository ? nil : captureScrollAnchor()
            layout = newGraph.layout
            appliedLayoutVersion = layoutVersion
            appliedSearchVersion = searchVersion
            appliedShowTags = showTags
            appliedAnnotationVersion = annotationVersion
            appliedWorkingTreeVersion = workingTreeVersion
            tableView.reloadData()
            if let layout, switchedRepository || previousLayout == nil || previousLayout?.scope != layout.scope {
                sizeGraphColumn(for: layout)
            }
            if let anchor {
                restoreScrollAnchor(anchor)
            } else if switchedRepository {
                tableView.scroll(.zero)
            }
            scheduleTicketRequest()
        } else if searchVersion != appliedSearchVersion || showTags != appliedShowTags || annotationVersion != appliedAnnotationVersion {
            let annotationsChanged = annotationVersion != appliedAnnotationVersion
            appliedSearchVersion = searchVersion
            appliedShowTags = showTags
            appliedAnnotationVersion = annotationVersion
            reloadVisibleRows()
            // After "Refresh Ticket Statuses" the visible tickets are stale and get asked for once;
            // after statuses arrive they're fresh, so this asks for nothing.
            if annotationsChanged { scheduleTicketRequest() }
        }
        if workingTreeVersion != appliedWorkingTreeVersion {
            appliedWorkingTreeVersion = workingTreeVersion
            if leadingRows > 0 {
                tableView.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            }
        }

        applySelection(selectedCommit, workingTree: selectsWorkingTree)
        if revealToken != appliedRevealToken {
            appliedRevealToken = revealToken
            // After this layout pass, so a freshly loaded table has its final size.
            DispatchQueue.main.async { [weak self] in
                if selectsWorkingTree {
                    self?.tableView?.scrollRowToVisible(0)
                } else {
                    self?.reveal(selectedCommit)
                }
            }
        }
    }

    private func sizeGraphColumn(for layout: GraphLayout) {
        guard let column = tableView?.tableColumn(withIdentifier: ColumnID.graph) else { return }
        let lanes = min(max(layout.suggestedLaneCount, 2), 24)
        isFittingColumns = true
        column.width = GraphMetrics.width(forLanes: lanes)
        isFittingColumns = false
        fitDescriptionColumn()
    }

    /// Gives the description column all the width the other columns leave, so nothing runs off the edge.
    private func fitDescriptionColumn() {
        guard let tableView, let scrollView = tableView.enclosingScrollView,
              let description = tableView.tableColumn(withIdentifier: ColumnID.description) else { return }
        let others = tableView.tableColumns.filter { $0 !== description && !$0.isHidden }.reduce(0) { $0 + $1.width }
        let spacing = tableView.intercellSpacing.width * CGFloat(tableView.tableColumns.count)
        let width = max(description.minWidth, floor(scrollView.contentView.bounds.width - others - spacing - 2))
        guard abs(description.width - width) > 0.5 else { return }
        isFittingColumns = true
        description.width = width
        isFittingColumns = false
    }

    @objc func visibleAreaDidResize(_ notification: Notification) {
        fitDescriptionColumn()
        scheduleTicketRequest()
    }

    @objc func visibleAreaDidScroll(_ notification: Notification) {
        scheduleTicketRequest()
    }

    // MARK: Jira

    private func updateTicketColumn() {
        let connection = JiraStore.shared.connection(for: graph.model.repository)
        jira = connection
        guard let column = tableView?.tableColumn(withIdentifier: ColumnID.ticket), column.isHidden != (connection == nil) else { return }
        column.isHidden = connection == nil
        fitDescriptionColumn()
    }

    /// Asks Jira for the tickets on screen once scrolling pauses. Redraws when statuses arrive don't
    /// come through here, so they can't trigger more requests.
    private func scheduleTicketRequest() {
        guard jira != nil else { return }
        ticketRequest?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestVisibleTickets() }
        }
        ticketRequest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The tickets on screen first, then those a screen below and a screen above, at most one
    /// batch's worth of new ones: scrolling on finds the next screen mostly known, so it doesn't
    /// send a request per screen.
    private func requestVisibleTickets() {
        guard let tableView, let layout, let jira else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let start = max(0, visible.location - leadingRows)
        let end = min(layout.rowCount, start + visible.length)
        let rows = Array(start..<end)
            + Array(end..<min(layout.rowCount, end + visible.length))
            + Array(max(0, start - visible.length)..<start).reversed()
        var keys: [String] = []
        var seen: Set<String> = []
        for row in rows {
            if let key = layout.graph.ticketKey(in: layout.graph.subjects[Int(layout.rows[row])]), seen.insert(key).inserted {
                keys.append(key)
            }
        }
        guard !keys.isEmpty else { return }
        JiraStore.shared.request(keys, connection: jira, limit: 50)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isFittingColumns,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier != ColumnID.description else { return }
        fitDescriptionColumn()
    }

    /// Redraws what's on screen (labels, highlights, statuses) without touching the rest.
    private func reloadVisibleRows() {
        guard let tableView else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        let range = rows.location..<(rows.location + rows.length)
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        for row in range {
            let isMatch = layoutRow(row).map { graph.matchSet.contains(Int32($0)) } ?? false
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? GraphRowView)?.isMatch = isMatch
        }
    }

    private func applySelection(_ commit: Int32?, workingTree: Bool) {
        guard let tableView, let layout else { return }
        var desired = -1
        if workingTree {
            desired = leadingRows > 0 ? 0 : -1
        } else if let commit, Int(commit) < layout.rowOfCommit.count, layout.rowOfCommit[Int(commit)] >= 0 {
            desired = Int(layout.rowOfCommit[Int(commit)]) + leadingRows
        }
        guard desired != tableView.selectedRow else { return }
        isApplyingSelection = true
        if desired >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: desired), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isApplyingSelection = false
    }

    /// Scrolls so the commit sits near the middle, unless it's already comfortably visible.
    private func reveal(_ commit: Int32?) {
        guard let tableView, let layout, let commit, Int(commit) < layout.rowOfCommit.count else { return }
        guard layout.rowOfCommit[Int(commit)] >= 0 else { return }
        let row = Int(layout.rowOfCommit[Int(commit)]) + leadingRows
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 4, row > visible.location + 1, row < visible.location + visible.length - 2 { return }
        let half = max(1, visible.length / 2)
        let target = row >= visible.location ? min(layout.rowCount + leadingRows - 1, row + half - 1) : max(0, row - half + 1)
        tableView.scrollRowToVisible(target)
        tableView.scrollRowToVisible(row)
    }

    // MARK: Keeping the scroll position across reloads

    /// The commit at the top of the view and how far it's scrolled past, so new commits arriving
    /// above don't push the view around. At the very top we stay at the top to show them.
    private func captureScrollAnchor() -> (id: ObjectID, offset: CGFloat)? {
        guard let tableView, let layout, layout.rowCount > 0 else { return nil }
        let visible = tableView.visibleRect
        guard visible.minY > 1 else { return nil }
        let row = tableView.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard let index = layoutRow(row) else { return nil }
        let offset = visible.minY - tableView.rect(ofRow: row).minY
        return (layout.graph.ids[Int(layout.rows[index])], offset)
    }

    private func restoreScrollAnchor(_ anchor: (id: ObjectID, offset: CGFloat)) {
        guard let tableView, let layout, let commit = layout.graph.indexByID[anchor.id] else { return }
        guard layout.rowOfCommit[Int(commit)] >= 0 else { return }
        let row = Int(layout.rowOfCommit[Int(commit)]) + leadingRows
        tableView.scroll(NSPoint(x: 0, y: tableView.rect(ofRow: row).minY + anchor.offset))
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        (layout?.rowCount ?? 0) + leadingRows
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row tableRow: Int) -> NSView? {
        guard let layout, let tableColumn else { return nil }
        if isWorkingRow(tableRow) { return workingRowView(tableView, column: tableColumn.identifier, layout: layout) }
        guard let row = layoutRow(tableRow) else { return nil }
        let commitGraph = layout.graph
        let commit = layout.rows[row]
        let index = Int(commit)

        switch tableColumn.identifier {
        case ColumnID.graph:
            let cell = tableView.makeView(withIdentifier: GraphCellView.identifier, owner: nil) as? GraphCellView ?? GraphCellView()
            cell.configure(layout: layout, row: row, isHead: commit == commitGraph.headCommit, isMerge: commitGraph.isMerge(commit))
            return cell

        case ColumnID.description:
            let cell = tableView.makeView(withIdentifier: DescriptionCellView.identifier, owner: nil) as? DescriptionCellView
                ?? DescriptionCellView()
            cell.configure(
                badges: badges(for: commit, row: row, layout: layout),
                subject: commitGraph.subjects[index],
                isMerge: commitGraph.isMerge(commit),
                ticketRegex: commitGraph.ticketRegex,
                highlight: graph.matchSet.contains(Int32(row)) ? graph.highlightText : nil
            )
            return cell

        case ColumnID.ticket:
            let cell = tableView.makeView(withIdentifier: TicketStatusCellView.identifier, owner: nil) as? TicketStatusCellView
                ?? TicketStatusCellView()
            let key = jira == nil ? nil : commitGraph.ticketKey(in: commitGraph.subjects[index])
            var epic: JiraLink?
            if let key, let jira, case .epic(let link) = JiraStore.shared.epic(of: key, connection: jira) { epic = link }
            let issue = key.flatMap { key in jira.flatMap { JiraStore.shared.issue(key, connection: $0) } }
            cell.configure(key: key, issue: issue, epic: epic, category: issue.map { JiraStore.shared.category(of: $0, connection: jira) })
            return cell

        case ColumnID.author:
            let cell = textCell(tableView, ColumnID.author)
            let author = Int(commitGraph.authorOf[index])
            cell.textField?.stringValue = commitGraph.authors[author]
            cell.toolTip = "\(commitGraph.authors[author]) <\(commitGraph.authorEmails[author])>"
            return cell

        case ColumnID.date:
            let cell = textCell(tableView, ColumnID.date)
            cell.textField?.stringValue = Self.dateFormatter.string(from: commitGraph.date(of: commit))
            return cell

        case ColumnID.commit:
            let cell = textCell(tableView, ColumnID.commit)
            cell.textField?.stringValue = commitGraph.ids[index].short
            return cell

        default:
            return nil
        }
    }

    /// A reused cell of a text column, or a new one in that column's font and color (the row for
    /// uncommitted changes uses them too, so cells made for it suit the commits they're reused for).
    private func textCell(_ tableView: NSTableView, _ identifier: NSUserInterfaceItemIdentifier) -> TextCellView {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView { return cell }
        switch identifier {
        case ColumnID.date:
            return TextCellView(identifier: identifier, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
        case ColumnID.commit:
            return TextCellView(identifier: identifier, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .tertiaryLabelColor)
        default:
            return TextCellView(identifier: identifier, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
        }
    }

    /// The row above the history: a dashed ring, "Uncommitted Changes" and what changed.
    private func workingRowView(_ tableView: NSTableView, column: NSUserInterfaceItemIdentifier, layout: GraphLayout) -> NSView? {
        switch column {
        case ColumnID.graph:
            let cell = tableView.makeView(withIdentifier: GraphCellView.identifier, owner: nil) as? GraphCellView ?? GraphCellView()
            cell.configureWorkingRow(layout: layout)
            return cell
        case ColumnID.description:
            let cell = tableView.makeView(withIdentifier: DescriptionCellView.identifier, owner: nil) as? DescriptionCellView
                ?? DescriptionCellView()
            cell.configureWorkingRow(summary: graph.model.workingTree?.summary ?? "")
            return cell
        case ColumnID.ticket:
            let cell = tableView.makeView(withIdentifier: TicketStatusCellView.identifier, owner: nil) as? TicketStatusCellView
                ?? TicketStatusCellView()
            cell.configure(key: nil, issue: nil)
            return cell
        case ColumnID.author, ColumnID.date, ColumnID.commit:
            let cell = textCell(tableView, column)
            cell.textField?.stringValue = ""
            cell.toolTip = nil
            return cell
        default:
            return nil
        }
    }

    /// Local branches first (merged with their remote counterpart when both point here, marked when
    /// checked out in another worktree), each followed by its open pull request, then the other
    /// worktrees detached here, remote-only branches, then tags; at most four plus a "+n".
    private func badges(for commit: Int32, row: Int, layout: GraphLayout) -> [DescriptionCellView.Badge] {
        let refs = layout.graph.refs(at: commit)
        let worktrees = layout.graph.detachedWorktrees(at: commit)
        guard !refs.isEmpty || !worktrees.isEmpty else { return [] }
        let laneColor = LanePalette.color(layout.color[row])
        let pullRequests = graph.model.pullRequests
        let remoteBranches = Set(refs.compactMap { $0.remoteParts?.branch })
        var badges: [DescriptionCellView.Badge] = []
        var shownPullRequests: Set<Int> = []
        func addPullRequest(forBranch branch: String) {
            guard let pullRequests, let pullRequest = pullRequests.openPullRequest(forBranch: branch),
                  shownPullRequests.insert(pullRequest.number).inserted else { return }
            badges.append(Self.badge(for: pullRequest, in: pullRequests))
        }
        for ref in refs where ref.kind == .local {
            badges.append(.init(style: ref.isHead ? .head : .branch, text: ref.name, color: laneColor,
                                synced: remoteBranches.contains(ref.name),
                                worktree: layout.graph.otherWorktree(checkingOut: ref.fullName)?.name))
            addPullRequest(forBranch: ref.name)
        }
        // One label for all of them: worktrees often start out on the same commit.
        if let first = worktrees.first {
            badges.append(.init(style: .worktree, text: worktrees.count == 1 ? first.name : String(localized: "\(worktrees.count) worktrees"),
                                worktree: worktrees.map(\.name).joined(separator: ", ")))
        }
        let localNames = Set(refs.filter { $0.kind == .local }.map(\.name))
        for ref in refs where ref.kind == .remote {
            guard let parts = ref.remoteParts else { continue }
            if !localNames.contains(parts.branch) {
                badges.append(.init(style: .remote, text: parts.branch, prefix: parts.remote + "/", color: laneColor))
            }
            addPullRequest(forBranch: parts.branch)
        }
        if graph.showTags {
            for ref in refs where ref.kind == .tag {
                badges.append(.init(style: .tag, text: ref.name))
            }
        }
        if badges.count > 4 {
            let hidden = badges.count - 4
            badges = Array(badges.prefix(4)) + [.init(style: .overflow, text: "+\(hidden)")]
        }
        return badges
    }

    /// `#8160`, or `#8160 · 2/3` for the second of three stacked pull requests, with its checks.
    private static func badge(for pullRequest: PullRequest, in index: PullRequestIndex) -> DescriptionCellView.Badge {
        var text = "#\(pullRequest.number)"
        let stack = index.stack(containing: pullRequest)
        if let position = stack.firstIndex(where: { $0.number == pullRequest.number }) {
            text += " · \(position + 1)/\(stack.count)"
        }
        var badge = DescriptionCellView.Badge(style: .pullRequest, text: text,
                                              color: pullRequest.isDraft ? .secondaryLabelColor : .systemGreen)
        if let readiness = pullRequest.readiness {
            badge.trailingSymbol = readiness.symbol
            badge.trailingColor = readiness.color
        }
        return badge
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GraphMetrics.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: GraphRowView.identifier, owner: nil) as? GraphRowView ?? GraphRowView()
        view.identifier = GraphRowView.identifier
        view.isMatch = layoutRow(row).map { graph.matchSet.contains(Int32($0)) } ?? false
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let tableView, let layout else { return }
        let row = tableView.selectedRow
        if isWorkingRow(row) {
            graph.userSelectedWorkingTree()
        } else {
            graph.userSelected(layoutRow(row).map { layout.rows[$0] })
        }
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        onShowDetails()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, let layout else { return }
        if isWorkingRow(tableView.clickedRow) {
            addItem(to: menu, "Show Uncommitted Changes", #selector(showWorkingTree(_:)), nil)
            return
        }
        guard let row = layoutRow(tableView.clickedRow) else { return }
        let commitGraph = layout.graph
        let commit = layout.rows[row]
        let id = commitGraph.ids[Int(commit)]
        let subject = commitGraph.subjects[Int(commit)]

        addItem(to: menu, "Copy Commit Hash", #selector(copyText(_:)), id.hex)
        addItem(to: menu, "Copy Short Hash", #selector(copyText(_:)), id.short)
        addItem(to: menu, "Copy Subject", #selector(copyText(_:)), subject)

        if let hosting = graph.model.hosting {
            menu.addItem(.separator())
            addItem(to: menu, "Open Commit on \(hosting.displayName)", #selector(openURL(_:)), hosting.commitURL(id.hex))
            for number in PullRequestReferences.numbers(in: subject) {
                addItem(to: menu, "Open Pull Request #\(String(number))", #selector(openURL(_:)), hosting.pullRequestURL(number))
            }
        }

        let branches = commitGraph.refs(at: commit).filter { $0.kind != .tag }.prefix(3)
        if !branches.isEmpty || graph.scope != .all {
            menu.addItem(.separator())
            for ref in branches {
                addItem(to: menu, "Show Only “\(ref.name)”", #selector(showOnly(_:)), ref.fullName)
            }
            if graph.scope != .all {
                addItem(to: menu, "Show All Branches", #selector(showAll(_:)), nil)
            }
        }

        menu.addItem(.separator())
        // Another commit selected, HEAD, or a branch to pick: compared in their own window.
        let repositoryID = graph.model.id
        if let selected = graph.selectedCommit, selected != commit, Int(selected) < commitGraph.count {
            let title: String.LocalizationValue = "Compare with “\(commitGraph.ids[Int(selected)].short) \(Self.shortened(commitGraph.subjects[Int(selected)]))”"
            addItem(to: menu, title, #selector(compare(_:)),
                    CompareTarget(repositoryID: repositoryID, base: commitGraph.ids[Int(selected)].hex, head: id.hex))
        }
        let head = commitGraph.headCommit
        if head >= 0, head != commit, head != graph.selectedCommit {
            addItem(to: menu, "Compare with HEAD", #selector(compare(_:)),
                    CompareTarget(repositoryID: repositoryID, base: commitGraph.ids[Int(head)].hex, head: id.hex))
        }
        addItem(to: menu, "Compare with…", #selector(compare(_:)), CompareTarget(repositoryID: repositoryID, head: id.hex))

        menu.addItem(.separator())
        addItem(to: menu, "Show Details", #selector(showDetails(_:)), NSNumber(value: commit))
    }

    /// A subject short enough for a menu item.
    private static func shortened(_ subject: String) -> String {
        subject.count > 40 ? String(subject.prefix(39)) + "…" : subject
    }

    @objc private func compare(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CompareTarget else { return }
        onCompare(target)
    }

    @objc private func showWorkingTree(_ sender: NSMenuItem) {
        graph.selectWorkingTree()
        onShowDetails()
    }

    private func addItem(to menu: NSMenu, _ title: String.LocalizationValue, _ action: Selector, _ payload: Any?) {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        menu.addItem(item)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showOnly(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        graph.showOnly(refNamed: name)
    }

    @objc private func showAll(_ sender: NSMenuItem) {
        graph.scope = .all
    }

    @objc private func showDetails(_ sender: NSMenuItem) {
        guard let commit = (sender.representedObject as? NSNumber)?.int32Value else { return }
        graph.select(commit, reveal: false)
        onShowDetails()
    }
}
