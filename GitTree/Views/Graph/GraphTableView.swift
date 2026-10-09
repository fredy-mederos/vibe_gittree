import AppKit
import SwiftUI

private enum ColumnID {
    static let graph = NSUserInterfaceItemIdentifier("graph")
    static let description = NSUserInterfaceItemIdentifier("description")
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
    let revealToken: Int
    let searchVersion: Int
    let showTags: Bool
    let onShowDetails: () -> Void

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onShowDetails = onShowDetails
        context.coordinator.update(
            graph: graph,
            layoutVersion: layoutVersion,
            selectedCommit: selectedCommit,
            revealToken: revealToken,
            searchVersion: searchVersion,
            showTags: showTags
        )
    }

    private static func column(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat,
                               maxWidth: CGFloat = 10_000) -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = title
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

    private var layout: GraphLayout?
    private var appliedLayoutVersion = -1
    private var appliedSearchVersion = -1
    private var appliedRevealToken = -1
    private var appliedShowTags = true
    private var isApplyingSelection = false
    private var isFittingColumns = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return formatter
    }()

    init(graph: GraphViewModel) {
        self.graph = graph
    }

    // MARK: Updates from SwiftUI

    func update(graph newGraph: GraphViewModel, layoutVersion: Int, selectedCommit: Int32?, revealToken: Int,
                searchVersion: Int, showTags: Bool) {
        guard let tableView else { return }
        let switchedRepository = newGraph !== graph
        graph = newGraph

        if switchedRepository || layoutVersion != appliedLayoutVersion {
            let previousLayout = layout
            let anchor = switchedRepository ? nil : captureScrollAnchor()
            layout = newGraph.layout
            appliedLayoutVersion = layoutVersion
            appliedSearchVersion = searchVersion
            appliedShowTags = showTags
            tableView.reloadData()
            if let layout, switchedRepository || previousLayout == nil || previousLayout?.scope != layout.scope {
                sizeGraphColumn(for: layout)
            }
            if let anchor {
                restoreScrollAnchor(anchor)
            } else if switchedRepository {
                tableView.scroll(.zero)
            }
        } else if searchVersion != appliedSearchVersion || showTags != appliedShowTags {
            appliedSearchVersion = searchVersion
            appliedShowTags = showTags
            reloadVisibleDescriptions()
        }

        applySelection(selectedCommit)
        if revealToken != appliedRevealToken {
            appliedRevealToken = revealToken
            // After this layout pass, so a freshly loaded table has its final size.
            DispatchQueue.main.async { [weak self] in self?.reveal(selectedCommit) }
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
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isFittingColumns,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier != ColumnID.description else { return }
        fitDescriptionColumn()
    }

    private func reloadVisibleDescriptions() {
        guard let tableView else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        let column = tableView.column(withIdentifier: ColumnID.description)
        guard rows.length > 0, column >= 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
                             columnIndexes: IndexSet(integer: column))
    }

    private func applySelection(_ commit: Int32?) {
        guard let tableView, let layout else { return }
        var desired = -1
        if let commit, Int(commit) < layout.rowOfCommit.count {
            desired = Int(layout.rowOfCommit[Int(commit)])
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
        let row = Int(layout.rowOfCommit[Int(commit)])
        guard row >= 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 4, row > visible.location + 1, row < visible.location + visible.length - 2 { return }
        let half = max(1, visible.length / 2)
        let target = row >= visible.location ? min(layout.rowCount - 1, row + half - 1) : max(0, row - half + 1)
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
        guard row >= 0, row < layout.rowCount else { return nil }
        let offset = visible.minY - tableView.rect(ofRow: row).minY
        return (layout.graph.ids[Int(layout.rows[row])], offset)
    }

    private func restoreScrollAnchor(_ anchor: (id: ObjectID, offset: CGFloat)) {
        guard let tableView, let layout, let commit = layout.graph.indexByID[anchor.id] else { return }
        let row = Int(layout.rowOfCommit[Int(commit)])
        guard row >= 0 else { return }
        tableView.scroll(NSPoint(x: 0, y: tableView.rect(ofRow: row).minY + anchor.offset))
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        layout?.rowCount ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let layout, let tableColumn, row < layout.rowCount else { return nil }
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
                highlight: graph.matchSet.contains(Int32(row)) ? graph.activeQuery : nil
            )
            return cell

        case ColumnID.author:
            let cell = textCell(tableView, ColumnID.author, font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
            let author = Int(commitGraph.authorOf[index])
            cell.textField?.stringValue = commitGraph.authors[author]
            cell.toolTip = "\(commitGraph.authors[author]) <\(commitGraph.authorEmails[author])>"
            return cell

        case ColumnID.date:
            let cell = textCell(tableView, ColumnID.date, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
            cell.textField?.stringValue = Self.dateFormatter.string(from: commitGraph.date(of: commit))
            return cell

        case ColumnID.commit:
            let cell = textCell(tableView, ColumnID.commit, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .tertiaryLabelColor)
            cell.textField?.stringValue = commitGraph.ids[index].short
            return cell

        default:
            return nil
        }
    }

    private func textCell(_ tableView: NSTableView, _ identifier: NSUserInterfaceItemIdentifier, font: NSFont, color: NSColor) -> TextCellView {
        tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView
            ?? TextCellView(identifier: identifier, font: font, color: color)
    }

    /// Local branches first (merged with their remote counterpart when both point here), then
    /// remote-only branches, then tags; at most three plus a "+n".
    private func badges(for commit: Int32, row: Int, layout: GraphLayout) -> [DescriptionCellView.Badge] {
        let refs = layout.graph.refs(at: commit)
        guard !refs.isEmpty else { return [] }
        let laneColor = LanePalette.color(layout.color[row])
        let remoteBranches = Set(refs.compactMap { $0.remoteParts?.branch })
        var badges: [DescriptionCellView.Badge] = []
        for ref in refs where ref.kind == .local {
            badges.append(.init(style: ref.isHead ? .head : .branch, text: ref.name, color: laneColor,
                                synced: remoteBranches.contains(ref.name)))
        }
        let localNames = Set(refs.filter { $0.kind == .local }.map(\.name))
        for ref in refs where ref.kind == .remote {
            guard let parts = ref.remoteParts, !localNames.contains(parts.branch) else { continue }
            badges.append(.init(style: .remote, text: parts.branch, prefix: parts.remote + "/", color: laneColor))
        }
        if graph.showTags {
            for ref in refs where ref.kind == .tag {
                badges.append(.init(style: .tag, text: ref.name))
            }
        }
        if badges.count > 3 {
            let hidden = badges.count - 3
            badges = Array(badges.prefix(3)) + [.init(style: .overflow, text: "+\(hidden)")]
        }
        return badges
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        GraphMetrics.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let tableView, let layout else { return }
        let row = tableView.selectedRow
        graph.userSelected(row >= 0 && row < layout.rowCount ? layout.rows[row] : nil)
    }

    @objc func doubleClicked(_ sender: Any?) {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        onShowDetails()
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, let layout else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < layout.rowCount else { return }
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
                addItem(to: menu, "Open Pull Request #\(number)", #selector(openURL(_:)), hosting.pullRequestURL(number))
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
        addItem(to: menu, "Show Details", #selector(showDetails(_:)), NSNumber(value: commit))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, _ payload: Any?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
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
