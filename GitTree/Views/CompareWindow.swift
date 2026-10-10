import SwiftUI

/// Two branches (or tags) side by side: where they diverged, and the commits, tickets, files and
/// authors each has that the other doesn't.
struct CompareWindow: View {
    @Binding var target: CompareTarget?

    var body: some View {
        if let current = target, let repository = RepositoryLibrary.shared.repository(id: current.repositoryID) {
            CompareView(model: RepositoryModelStore.shared.model(for: repository),
                        target: Binding(get: { target ?? current }, set: { target = $0 }))
        } else {
            ContentUnavailableView("No Repository", systemImage: "arrow.left.arrow.right",
                                   description: Text("This repository is no longer in GitTree."))
        }
    }
}

private enum CompareTab: String, CaseIterable, Identifiable {
    case commits = "Commits", tickets = "Tickets", files = "Files", authors = "Authors"

    var id: String { rawValue }
}

private struct CompareView: View {
    let model: RepositoryModel
    @Binding var target: CompareTarget

    @State private var comparison: BranchComparison?
    /// Files changed on each side since they diverged, by the side's full ref name.
    @State private var files: [String: (files: [ChangedFile], total: Int)] = [:]
    @State private var filesProblem: String?
    @State private var tab: CompareTab = .commits

    private struct TaskKey: Hashable {
        let base: String?
        let head: String?
        let generation: Int
    }

    var body: some View {
        Group {
            if let graph = model.graph {
                if let comparison, comparison.graph === graph,
                   comparison.base.ref.fullName == target.base, comparison.head.ref.fullName == target.head {
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
        guard let graph = model.graph, let base = ref(target.base, in: graph), let head = ref(target.head, in: graph) else {
            return "Compare Branches"
        }
        return "\(head.name) ↔ \(base.name)"
    }

    private func ref(_ fullName: String?, in graph: CommitGraph) -> GitRef? {
        guard let fullName else { return nil }
        return graph.refs.first { $0.fullName == fullName }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            RefPickerButton(title: "Base", selection: $target.base, graph: model.graph)
                .help("The branch to compare against")
            Button {
                let base = target.base
                target.base = target.head
                target.head = base
            } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap the two branches")
            RefPickerButton(title: "Compare", selection: $target.head, graph: model.graph)
                .help("The branch to compare")
        }
    }

    // MARK: Comparing

    private func compare() async {
        guard let graph = model.graph else { return }
        // Fill in what wasn't picked (or is gone); the task starts again with the new choice.
        if ref(target.head, in: graph) == nil, let head = BranchComparison.defaultHead(in: graph, other: target.base) {
            target.head = head.fullName
            return
        }
        if ref(target.base, in: graph) == nil, let base = BranchComparison.defaultBase(in: graph, other: target.head) {
            target.base = base.fullName
            return
        }
        guard let base = ref(target.base, in: graph), let head = ref(target.head, in: graph) else { return }
        let result = await Task.detached(priority: .userInitiated) {
            BranchComparison.compute(graph: graph, base: base, head: head)
        }.value
        guard !Task.isCancelled else { return }
        comparison = result
        files = [:]
        filesProblem = nil
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
        let detectRenames = model.repository.kind == .local
        for side in [result.base, result.head] where !side.commits.isEmpty {
            do {
                files[side.ref.fullName] = try await BranchDiffLoader.files(
                    from: graph.ids[Int(mergeBase)], to: graph.ids[Int(side.ref.commit)], in: directory, detectRenames: detectRenames
                )
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
                ForEach(CompareTab.allCases) { Text($0.rawValue).tag($0) }
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
        SideColumn(side: side, other: other, graph: comparison.graph, tab: tab, files: files[side.ref.fullName],
                   filesNote: comparison.mergeBase == nil ? "They share no history, so there's nothing to diff against." : filesProblem,
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
        let headName = "“\(head.ref.name)”"
        let baseName = "“\(base.ref.name)”"
        switch (head.nonMergeCount, base.nonMergeCount) {
        case (0, 0): return "\(headName) and \(baseName) have the same commits."
        case (0, let behind): return "Everything on \(headName) is on \(baseName), which has \(counted(behind, "commit", "commits")) more."
        case (let ahead, 0): return "\(headName) has \(counted(ahead, "commit", "commits")) that \(baseName) doesn't, and everything \(baseName) has."
        case (let ahead, let behind):
            return "\(headName) has \(counted(ahead, "commit", "commits")) that \(baseName) doesn't; \(baseName) has \(counted(behind, "commit", "commits")) that \(headName) doesn't."
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
    let files: (files: [ChangedFile], total: Int)?
    let filesNote: String?
    let jira: JiraConnection?
    let repositoryID: UUID

    /// Lists stop here; the header still counts everything.
    private static let rowLimit = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if side.commits.isEmpty {
                ContentUnavailableView("Nothing Else Here", systemImage: "checkmark.circle",
                                       description: Text("Every commit on “\(side.ref.name)” is on “\(other.ref.name)” too."))
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
                    Text(side.ref.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: side.ref.kind == .tag ? "tag" : (side.ref.kind == .remote ? "cloud" : "arrow.triangle.branch"))
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
                Spacer(minLength: 8)
                Button("Highlight in Graph") {
                    NotificationCenter.default.post(name: .gitTreeHighlightCommits, object: nil, userInfo: [
                        "repository": repositoryID,
                        "commits": side.commits.map { graph.ids[Int($0)].hex },
                        "title": "Only on \(side.ref.name), not on \(other.ref.name)",
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
        var parts = [counted(side.nonMergeCount, "commit", "commits")
            + (side.commits.count > side.nonMergeCount ? " and \(counted(side.commits.count - side.nonMergeCount, "merge", "merges"))" : "")]
        if !side.tickets.isEmpty { parts.append(counted(side.tickets.count, "ticket", "tickets")) }
        if !side.authors.isEmpty { parts.append(counted(side.authors.count, "author", "authors")) }
        if let oldest = side.oldest, let newest = side.newest {
            let range = oldest.formatted(.dateTime.month(.abbreviated).day()) + " – " + newest.formatted(.dateTime.month(.abbreviated).day())
            parts.append(range)
        }
        return "Not on \(other.ref.name): " + parts.joined(separator: " · ")
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
                Text("\((side.commits.count - Self.rowLimit).formatted()) more not listed.")
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
                                         alsoOn: otherKeys.contains(ticket.key) ? other.ref.name : nil, connection: jira)
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
                Text("\(counted(loose, "commit doesn't", "commits don't")) mention a ticket.")
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
        if let files {
            List {
                ForEach(files.files) { file in
                    HStack(spacing: 8) {
                        Text(file.status)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(Self.color(file.status))
                            .frame(width: 14)
                        Text(file.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                }
                if files.total > files.files.count {
                    Text("\((files.total - files.files.count).formatted()) more not listed.")
                        .foregroundStyle(.secondary)
                }
                if files.total == 0 {
                    Text("No files differ: the commits cancel out.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("\(counted(files.total, "file", "files")) changed on “\(side.ref.name)” since the branches diverged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private static func color(_ status: String) -> Color {
        switch status {
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
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
        .help(Text(verbatim: [ticket.key, issue?.summary, issue.map { "\($0.status) · \(counted(ticket.commits, "commit", "commits"))" }]
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
                Text(selection.map { GitRef.shortName(fullName: $0) } ?? title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let graph {
                RefPickerList(graph: graph, selection: selection) { ref in
                    selection = ref.fullName
                    isPresented = false
                }
                .frame(width: 340, height: 440)
            }
        }
    }
}

/// Branches, remote branches and tags, newest first, narrowed by what's typed.
private struct RefPickerList: View {
    let graph: CommitGraph
    let selection: String?
    let pick: (GitRef) -> Void

    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter, prompt: Text("Branches and tags"))
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                section("Branches", kind: .local, limit: 500)
                section("Remote Branches", kind: .remote, limit: 500)
                section("Tags", kind: .tag, limit: 200)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind: GitRef.Kind, limit: Int) -> some View {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let refs = graph.refs
            .filter { $0.kind == kind && (needle.isEmpty || $0.name.lowercased().contains(needle)) }
            .sorted { graph.times[Int($0.commit)] > graph.times[Int($1.commit)] }
            .prefix(limit)
        if !refs.isEmpty {
            Section(title) {
                ForEach(Array(refs)) { ref in
                    Button {
                        pick(ref)
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
