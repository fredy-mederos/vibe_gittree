import SwiftUI

/// Two branches (or tags, or commits) side by side: where they diverged, and the commits, tickets,
/// files and authors each has that the other doesn't.
struct CompareWindow: View {
    @Binding var target: CompareTarget?

    var body: some View {
        if let current = target, let repository = RepositoryLibrary.shared.repository(id: current.repositoryID) {
            CompareView(model: RepositoryModelStore.shared.model(for: repository),
                        target: Binding(get: { target ?? current }, set: { target = $0 }))
        } else {
            ContentUnavailableView("No Repository", systemImage: "arrow.left.arrow.right",
                                   description: Text("This repository is no longer in Vibe GitTree."))
        }
    }
}

private enum CompareTab: String, CaseIterable, Identifiable {
    case commits = "Commits", tickets = "Tickets", files = "Files", authors = "Authors"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commits: String(localized: "Commits")
        case .tickets: String(localized: "Tickets")
        case .files: String(localized: "Files")
        case .authors: String(localized: "Authors")
        }
    }

    /// The tab a comparison opens on (`-GTCompareTab` picks another in test runs).
    @MainActor static var initial: CompareTab {
        #if DEBUG
        if let name = DebugLaunch.compareTab, let tab = allCases.first(where: { $0.rawValue.lowercased() == name }) { return tab }
        #endif
        return .commits
    }
}

private struct CompareView: View {
    let model: RepositoryModel
    @Binding var target: CompareTarget

    @State private var comparison: BranchComparison?
    /// Files changed on each side since they diverged, by the side's ref name or hash.
    @State private var files: [String: [DiffFile]] = [:]
    @State private var filesProblem: String?
    @State private var tab = CompareTab.initial

    private struct TaskKey: Hashable {
        let base: String?
        let head: String?
        let generation: Int
    }

    var body: some View {
        Group {
            if let graph = model.graph {
                if let comparison, comparison.graph === graph,
                   comparison.base.point.spec == target.base, comparison.head.point.spec == target.head {
                    content(comparison)
                } else if target.base == nil || target.head == nil {
                    ContentUnavailableView("Pick Two Branches", systemImage: "arrow.left.arrow.right",
                                           description: Text("Choose the branches to compare in the toolbar."))
                } else {
                    ProgressView("Comparing…")
                }
            } else if case .failed(let message) = model.status {
                ContentUnavailableView("Can't Read This Repository", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ProgressView("Reading history…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationSubtitle(model.repository.name)
        .toolbar { toolbar }
        .onAppear { model.loadIfNeeded() }
        .task(id: TaskKey(base: target.base, head: target.head, generation: model.generation)) { await compare() }
    }

    private var title: String {
        guard let graph = model.graph, let base = ComparePoint.resolve(target.base, in: graph),
              let head = ComparePoint.resolve(target.head, in: graph) else {
            return String(localized: "Compare Branches")
        }
        return "\(head.name) ↔ \(base.name)"
    }

    /// Comparisons opened before in this repository, other than this one.
    private var recentComparisons: [RecentComparison] {
        (RepositoryLibrary.shared.repository(id: model.id)?.recentComparisons ?? [])
            .filter { $0.base != target.base || $0.head != target.head }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            RefPickerButton(title: String(localized: "Base", comment: "Picks the branch a comparison is made against, as on GitHub"),
                            selection: $target.base, graph: model.graph)
                .help("The branch to compare against")
            Button {
                let base = target.base
                target.base = target.head
                target.head = base
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap the two branches")
            RefPickerButton(title: String(localized: "Compare", comment: "Picks the branch that is compared with the base one, as on GitHub"),
                            selection: $target.head, graph: model.graph)
                .help("The branch to compare")
        }
        ToolbarItem {
            Menu {
                ForEach(recentComparisons, id: \.self) { recent in
                    Button(recent.title) {
                        target.base = recent.base
                        target.head = recent.head
                    }
                }
                if recentComparisons.isEmpty {
                    Text("No Other Comparisons")
                }
            } label: {
                Label("Recent Comparisons", systemImage: "clock.arrow.circlepath")
            }
            .help("Comparisons opened before in this repository")
        }
    }

    // MARK: Comparing

    private func compare() async {
        guard let graph = model.graph else { return }
        // Fill in what wasn't picked (or is gone); the task starts again with the new choice.
        if ComparePoint.resolve(target.head, in: graph) == nil, let head = BranchComparison.defaultHead(in: graph, other: target.base) {
            target.head = head.fullName
            return
        }
        if ComparePoint.resolve(target.base, in: graph) == nil, let base = BranchComparison.defaultBase(in: graph, other: target.head) {
            target.base = base.fullName
            return
        }
        guard let base = ComparePoint.resolve(target.base, in: graph), let head = ComparePoint.resolve(target.head, in: graph) else { return }
        let result = await Task.detached(priority: .userInitiated) {
            BranchComparison.compute(graph: graph, base: base, head: head)
        }.value
        guard !Task.isCancelled else { return }
        comparison = result
        files = [:]
        filesProblem = nil
        RepositoryLibrary.shared.recordComparison(base: base.spec, head: head.spec, for: model.id)
        #if DEBUG
        DebugLaunch.describeComparison(result)
        #endif

        if let jira = JiraStore.shared.connection(for: model.repository) {
            // Statuses and epics for the tickets on both sides, through the usual paced queue.
            let keys = Array(Set((result.base.tickets + result.head.tickets).map(\.key)).prefix(300))
            Task {
                await JiraStore.shared.ensureKnown(keys, connection: jira)
                let parents = JiraStore.shared.parentsToRead(of: keys, connection: jira)
                if !parents.isEmpty { await JiraStore.shared.ensureKnown(parents, connection: jira) }
            }
        }

        guard let mergeBase = result.mergeBase else { return }
        let directory = model.repository.directory
        // Line counts (and renames) only where the contents are here, not for partial clones.
        let isLocal = model.repository.kind == .local
        for side in [result.base, result.head] where !side.commits.isEmpty {
            let changes = DiffTarget(repositoryID: model.id, commit: graph.ids[Int(side.point.commit)].hex, path: "",
                                     base: graph.ids[Int(mergeBase)].hex)
            do {
                files[side.point.spec] = try await DiffFileListLoader.files(for: changes, firstParent: nil, workingTree: nil,
                                                                             in: directory, counts: isLocal)
            } catch {
                guard !Task.isCancelled else { return }
                filesProblem = error.localizedDescription
            }
        }
    }

    // MARK: Content

    private func content(_ comparison: BranchComparison) -> some View {
        VStack(spacing: 0) {
            summary(comparison)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Picker("Show", selection: $tab) {
                ForEach(CompareTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                column(comparison.base, other: comparison.head, comparison: comparison)
                Divider()
                column(comparison.head, other: comparison.base, comparison: comparison)
            }
        }
    }

    private func column(_ side: BranchComparison.Side, other: BranchComparison.Side, comparison: BranchComparison) -> some View {
        SideColumn(side: side, other: other, graph: comparison.graph, tab: tab, files: files[side.point.spec],
                   filesNote: comparison.mergeBase == nil ? String(localized: "They share no history, so there's nothing to diff against.") : filesProblem,
                   mergeBase: comparison.mergeBase.map { comparison.graph.ids[Int($0)] },
                   jira: JiraStore.shared.connection(for: model.repository), repositoryID: model.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ comparison: BranchComparison) -> some View {
        let graph = comparison.graph
        let base = comparison.base
        let head = comparison.head
        return VStack(alignment: .leading, spacing: 5) {
            Text(headline(base: base, head: head))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let mergeBase = comparison.mergeBase {
                Button {
                    reveal(mergeBase, in: graph)
                } label: {
                    Text("They diverged at \(graph.ids[Int(mergeBase)].short) “\(graph.subjects[Int(mergeBase)])”, \(graph.date(of: mergeBase).formatted(date: .abbreviated, time: .omitted)) (\(graph.date(of: mergeBase).formatted(.relative(presentation: .named)))).")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
                .help("Select this commit in the graph")
            } else {
                Text("They share no history.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func headline(base: BranchComparison.Side, head: BranchComparison.Side) -> String {
        let headName = "“\(head.point.name)”"
        let baseName = "“\(base.point.name)”"
        switch (head.nonMergeCount, base.nonMergeCount) {
        case (0, 0): return String(localized: "\(headName) and \(baseName) have the same commits.")
        case (0, let behind): return String(localized: "Everything on \(headName) is on \(baseName), which has \(behind) commits more.")
        case (let ahead, 0): return String(localized: "\(headName) has \(ahead) commits that \(baseName) doesn't, and everything \(baseName) has.")
        case (let ahead, let behind):
            let aheadClause = String(localized: "\(headName) has \(ahead) commits that \(baseName) doesn't", comment: "One of two clauses about two branches")
            let behindClause = String(localized: "\(baseName) has \(behind) commits that \(headName) doesn't", comment: "One of two clauses about two branches")
            return String(localized: "\(aheadClause); \(behindClause).", comment: "Two clauses, each saying what one branch has that the other doesn't")
        }
    }

    private func reveal(_ commit: Int32, in graph: CommitGraph) {
        NotificationCenter.default.post(name: .gitTreeRevealCommit, object: nil, userInfo: [
            "repository": model.id, "commit": graph.ids[Int(commit)].hex,
        ])
    }
}

/// What one side has that the other doesn't, as the picked tab shows it.
private struct SideColumn: View {
    let side: BranchComparison.Side
    let other: BranchComparison.Side
    let graph: CommitGraph
    let tab: CompareTab
    let files: [DiffFile]?
    let filesNote: String?
    /// Where the two sides diverged, which their files are compared with.
    let mergeBase: ObjectID?
    let jira: JiraConnection?
    let repositoryID: UUID

    @Environment(\.openWindow) private var openWindow
    /// The Files tab's order, the diff window's too.
    @AppStorage("diff.fileOrder") private var order = DiffFileOrder.path

    /// Lists stop here; the header still counts everything.
    private static let rowLimit = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if side.commits.isEmpty {
                ContentUnavailableView("Nothing Else Here", systemImage: "checkmark.circle",
                                       description: Text("Every commit on “\(side.point.name)” is on “\(other.point.name)” too."))
                    .frame(maxHeight: .infinity)
            } else {
                switch tab {
                case .commits: commits
                case .tickets: tickets
                case .files: changedFiles
                case .authors: authors
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label {
                    Text(side.point.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: side.point.systemImage)
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
                Spacer(minLength: 8)
                Button("Highlight in Graph") {
                    NotificationCenter.default.post(name: .gitTreeHighlightCommits, object: nil, userInfo: [
                        "repository": repositoryID,
                        "commits": side.commits.map { graph.ids[Int($0)].hex },
                        "title": String(localized: "Only on \(side.point.name), not on \(other.point.name)"),
                    ])
                }
                .disabled(side.commits.isEmpty)
                .help("Highlight these commits in the repository's window")
            }
            Text(details)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
    }

    /// "Not on develop: 12 commits (and 2 merges) · 5 tickets · 3 authors · Sep 28 – Oct 9".
    private var details: String {
        let commits = String(localized: "\(side.nonMergeCount) commits")
        let merges = side.commits.count - side.nonMergeCount
        var parts = [merges > 0 ? String(localized: "\(commits) and \(merges) merges", comment: "12 commits and 2 merges") : commits]
        if !side.tickets.isEmpty { parts.append(String(localized: "\(side.tickets.count) tickets")) }
        if !side.authors.isEmpty { parts.append(String(localized: "\(side.authors.count) authors")) }
        if let oldest = side.oldest, let newest = side.newest {
            parts.append(oldest.formatted(.dateTime.month(.abbreviated).day()) + " – " + newest.formatted(.dateTime.month(.abbreviated).day()))
        }
        return String(localized: "Not on \(other.point.name): \(parts.joined(separator: " · "))", comment: "Followed by what a branch has: 12 commits · 5 tickets · 3 authors · Sep 28 – Oct 9")
    }

    // MARK: Tabs

    private var commits: some View {
        List {
            ForEach(Array(side.commits.prefix(Self.rowLimit)), id: \.self) { commit in
                Button {
                    NotificationCenter.default.post(name: .gitTreeRevealCommit, object: nil, userInfo: [
                        "repository": repositoryID, "commit": graph.ids[Int(commit)].hex,
                    ])
                } label: {
                    HStack(spacing: 8) {
                        Text(graph.date(of: commit), format: .dateTime.month(.abbreviated).day())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(graph.subjects[Int(commit)])
                            .lineLimit(1)
                            .foregroundStyle(graph.isMerge(commit) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
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
            if side.commits.count > Self.rowLimit {
                Text("\(side.commits.count - Self.rowLimit) more not listed.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tickets under their epics when Jira is connected, newest first.
    private var tickets: some View {
        let store = JiraStore.shared
        let _ = store.version
        let otherKeys = Set(other.tickets.map(\.key))
        let groups = epicGroups()
        let loose = side.nonMergeCount - side.tickets.reduce(0) { $0 + $1.commits }
        return List {
            ForEach(groups, id: \.id) { group in
                Section {
                    ForEach(group.tickets) { ticket in
                        CompareTicketRow(ticket: ticket, issue: jira.flatMap { store.issue(ticket.key, connection: $0) },
                                         alsoOn: otherKeys.contains(ticket.key) ? other.point.name : nil, connection: jira)
                    }
                } header: {
                    if let epic = group.epic {
                        Label {
                            Text(verbatim: "\(epic.summary.isEmpty ? epic.key : epic.summary)  \(epic.key)")
                        } icon: {
                            IssueTypeIcon(type: "Epic", level: 1)
                        }
                    } else if jira != nil {
                        Text(groups.count > 1 ? "No Epic" : "Tickets")
                    } else {
                        Text("Tickets")
                    }
                }
            }
            if loose > 0 {
                Text("\(loose) commits don't mention a ticket.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct EpicGroup {
        let id: String
        let epic: JiraLink?
        var tickets: [RecentTicket]
    }

    private func epicGroups() -> [EpicGroup] {
        guard let jira else { return side.tickets.isEmpty ? [] : [EpicGroup(id: "", epic: nil, tickets: side.tickets)] }
        var order: [String] = []
        var groups: [String: EpicGroup] = [:]
        for ticket in side.tickets {
            var epic: JiraLink?
            if case .epic(let link) = JiraStore.shared.epic(of: ticket.key, connection: jira) { epic = link }
            let id = epic?.key ?? ""
            if groups[id] == nil {
                order.append(id)
                groups[id] = EpicGroup(id: id, epic: epic, tickets: [])
            }
            groups[id]?.tickets.append(ticket)
        }
        // Epics in order of their newest ticket; tickets without one last.
        return order.filter { !$0.isEmpty }.compactMap { groups[$0] } + (groups[""].map { [$0] } ?? [])
    }

    @ViewBuilder private var changedFiles: some View {
        if let listed = files {
            let files = order.sorted(listed)
            let most = DiffFileRow.most(of: files)
            List {
                ForEach(files) { file in
                    Button {
                        openDiff(of: file, allFiles: false)
                    } label: {
                        DiffFileRow(file: file, most: most)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if files.isEmpty {
                    Text("No files differ: the commits cancel out.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(files.count) files changed on “\(side.point.name)” since the branches diverged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    DiffFileOrderPicker(order: $order)
                        .font(.caption)
                        .controlSize(.small)
                    if let first = files.first {
                        Button("Show All Changes") { openDiff(of: first, allFiles: true) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Every change on this side since the branches diverged, one file after another")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        } else if let filesNote {
            ContentUnavailableView("No File List", systemImage: "doc.questionmark", description: Text(filesNote))
        } else {
            ProgressView("Listing changed files…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var authors: some View {
        let most = max(1, side.authors.first?.commits ?? 1)
        return List {
            ForEach(side.authors, id: \.name) { author in
                HStack(spacing: 10) {
                    Text(author.name)
                        .lineLimit(1)
                        .frame(minWidth: 120, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: max(3, proxy.size.width * CGFloat(author.commits) / CGFloat(most)), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 14)
                    Text(author.commits.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
        }
    }

    /// A file's changes on this side, from where the branches diverged to this side's tip, in the
    /// diff window (listing the side's other files), or all of them one after another.
    private func openDiff(of file: DiffFile, allFiles: Bool) {
        guard let mergeBase else { return }
        openWindow(id: "diff", value: DiffTarget(repositoryID: repositoryID, commit: graph.ids[Int(side.point.commit)].hex, path: file.path,
                                                 base: mergeBase.hex, oldPath: file.oldPath, allFiles: allFiles ? true : nil,
                                                 title: String(localized: "\(side.point.name) since \(other.point.name)", comment: "A branch's changes since it diverged from another branch")))
    }
}

/// A ticket on one side: its type, key, summary, status and commits there.
private struct CompareTicketRow: View {
    let ticket: RecentTicket
    let issue: JiraIssue?
    /// The other branch, when it has commits for this ticket too.
    let alsoOn: String?
    let connection: JiraConnection?

    var body: some View {
        HStack(spacing: 8) {
            IssueTypeIcon(type: issue?.type, level: issue?.level)
            Text(verbatim: ticket.key)
                .monospaced()
            Text(issue?.summary ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let alsoOn {
                Text("also on \(alsoOn)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("Some of this ticket's commits are on \(alsoOn) too")
            }
            if let issue {
                IssueStatusText(status: issue.status, category: JiraStore.shared.category(of: issue, connection: connection))
                    .font(.caption.weight(.semibold))
            }
            Text(ticket.commits.formatted())
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .help(Text(verbatim: [ticket.key, issue?.summary, issue.map { "\($0.status) · " + String(localized: "\(ticket.commits) commits") }]
            .compactMap { $0 }.joined(separator: "\n")))
    }
}

/// A toolbar button showing the picked branch; it opens a searchable list of branches and tags.
private struct RefPickerButton: View {
    let title: String
    @Binding var selection: String?
    let graph: CommitGraph?

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selection.map(label) ?? title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let graph {
                RefPickerList(graph: graph, selection: selection) { spec in
                    selection = spec
                    isPresented = false
                }
                .frame(width: 340, height: 440)
            }
        }
    }

    /// A branch's or tag's name, or a commit's short hash and subject.
    private func label(_ spec: String) -> String {
        guard !spec.hasPrefix("refs/"), let graph, let commit = graph.index(matching: spec) else { return ComparePoint.shortName(spec) }
        return "\(graph.ids[Int(commit)].short) \(graph.subjects[Int(commit)])"
    }
}

/// Branches, remote branches and tags, newest first, narrowed by what's typed; a commit too, by
/// its hash.
private struct RefPickerList: View {
    let graph: CommitGraph
    let selection: String?
    /// Gets a full ref name, or a commit's hash.
    let pick: (String) -> Void

    @State private var filter = ""

    /// The commit whose hash is typed (at least four characters of it).
    private var typedCommit: Int32? {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.count >= 4 ? graph.index(matching: text) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter, prompt: Text("Branches, tags or a commit hash"))
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                if let commit = typedCommit {
                    Section("Commit") {
                        Button {
                            pick(graph.ids[Int(commit)].hex)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "smallcircle.filled.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(graph.ids[Int(commit)].short)
                                    .monospaced()
                                Text(graph.subjects[Int(commit)])
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                section("Branches", kind: .local, limit: 500)
                section("Remote Branches", kind: .remote, limit: 500)
                section("Tags", kind: .tag, limit: 200)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, kind: GitRef.Kind, limit: Int) -> some View {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let refs = graph.refs
            .filter { $0.kind == kind && (needle.isEmpty || $0.name.lowercased().contains(needle)) }
            .sorted { graph.times[Int($0.commit)] > graph.times[Int($1.commit)] }
            .prefix(limit)
        if !refs.isEmpty {
            Section(title) {
                ForEach(Array(refs)) { ref in
                    Button {
                        pick(ref.fullName)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: ref.fullName == selection ? "checkmark" : (kind == .tag ? "tag" : (kind == .remote ? "cloud" : "arrow.triangle.branch")))
                                .foregroundStyle(ref.fullName == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 16)
                            Text(ref.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(RelativeAge.short(graph.date(of: ref.commit)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
