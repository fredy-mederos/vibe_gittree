import SwiftUI

/// Repositories on top, then the current repository's branches, remotes and tags.
struct SidebarView: View {
    @Bindable var state: WindowState
    @Environment(\.openWindow) private var openWindow
    @Bindable private var library = RepositoryLibrary.shared

    @AppStorage("sidebar.repositoriesExpanded") private var repositoriesExpanded = true
    @AppStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false
    @AppStorage("sidebar.stacksExpanded") private var stacksExpanded = true
    @AppStorage("sidebar.pullRequestsExpanded") private var pullRequestsExpanded = false
    @AppStorage("sidebar.featuresExpanded") private var featuresExpanded = true
    @State private var expanded: [String: Bool] = [:]

    /// Repositories listed before "Show All" takes over.
    private static let collapsedLimit = 8

    private var filterText: String {
        state.refFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool { !filterText.isEmpty }

    /// The repositories to list and how many are tucked away behind "Show All".
    private var visibleRepositories: (shown: [Repository], hidden: Int) {
        let all = library.sortedRepositories
        if isFiltering {
            let needle = filterText.lowercased()
            return (all.filter { $0.name.lowercased().contains(needle) || $0.fullLocation.lowercased().contains(needle) }, 0)
        }
        guard !state.showsAllRepositories, all.count > Self.collapsedLimit + 1 else { return (all, 0) }
        var shown = Array(all.prefix(Self.collapsedLimit))
        if let current = all.first(where: { $0.id == state.repositoryID }), !shown.contains(where: { $0.id == current.id }) {
            shown.append(current)
        }
        return (shown, all.count - shown.count)
    }

    var body: some View {
        List(selection: $state.sidebarSelection) {
            let visible = visibleRepositories
            Section(isExpanded: isFiltering ? .constant(true) : $repositoriesExpanded) {
                ForEach(visible.shown) { repository in
                    RepositoryRow(repository: repository, isCurrent: repository.id == state.repositoryID)
                        .tag(SidebarItem.repository(repository.id))
                }
                .onMove(perform: library.sort == .manual && !isFiltering && visible.hidden == 0 ? { library.move(fromOffsets: $0, toOffset: $1) } : nil)
                if visible.hidden > 0 {
                    Button {
                        state.showsAllRepositories = true
                    } label: {
                        Label("Show All \(library.repositories.count)", systemImage: "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if state.showsAllRepositories, !isFiltering, library.repositories.count > Self.collapsedLimit + 1 {
                    Button {
                        state.showsAllRepositories = false
                    } label: {
                        Label("Show Fewer", systemImage: "chevron.up")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionHeader(title: "Repositories", count: library.repositories.count)
            }

            if let graph = state.graph, let repositoryID = state.repositoryID,
               let commitGraph = graph.commitGraph, let tree = graph.refTree(filter: state.refFilter) {
                refSections(tree, commitGraph: commitGraph, repositoryID: repositoryID)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { contextMenu(for: item) }
        } primaryAction: { items in
            // Double-click or Return on a branch or tag shows only its history.
            guard case .ref(_, let fullName)? = items.first else { return }
            state.graph?.showOnly(refNamed: fullName)
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.addLocal(urls: urls)
            return true
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
    }

    // MARK: Refs

    @ViewBuilder
    private func refSections(_ tree: RefTree, commitGraph: CommitGraph, repositoryID: UUID) -> some View {
        if let graph = state.graph, !isFiltering {
            featuresSection(graph, repositoryID: repositoryID)
        }
        if let pullRequests = state.graph?.model.pullRequests, !isFiltering {
            let stacked = Set(pullRequests.stacks.flatMap { $0.map(\.number) })
            let others = pullRequests.all.filter { $0.state == .open && !stacked.contains($0.number) }
            if !others.isEmpty {
                Section(isExpanded: $pullRequestsExpanded) {
                    ForEach(others) { pullRequest in
                        pullRequestRow(pullRequest, commitGraph: commitGraph, repositoryID: repositoryID)
                    }
                } header: {
                    SectionHeader(title: "Pull Requests", count: others.count)
                }
            }
        }
        if let pullRequests = state.graph?.model.pullRequests, !pullRequests.stacks.isEmpty, !isFiltering {
            Section(isExpanded: $stacksExpanded) {
                ForEach(pullRequests.stacks, id: \.first?.number) { stack in
                    DisclosureGroup(isExpanded: expansion("stack:\(stack.first?.number ?? 0)", default: true)) {
                        ForEach(Array(stack.enumerated()), id: \.element.number) { position, pullRequest in
                            stackRow(pullRequest, position: position, commitGraph: commitGraph, repositoryID: repositoryID)
                        }
                    } label: {
                        CountedLabel(title: "on \(stack.first?.base ?? "")", systemImage: "square.stack.3d.up", count: stack.count)
                    }
                }
            } header: {
                SectionHeader(title: "Pull Request Stacks", count: pullRequests.stacks.count)
            }
        }
        if tree.local.count > 0 {
            Section(isExpanded: isFiltering ? .constant(true) : $branchesExpanded) {
                refContent(tree.local, commitGraph: commitGraph, repositoryID: repositoryID, icon: "arrow.triangle.branch")
            } header: {
                SectionHeader(title: "Branches", count: tree.local.count)
            }
        }
        if !tree.remotes.isEmpty {
            Section(isExpanded: isFiltering ? .constant(true) : $remotesExpanded) {
                ForEach(tree.remotes) { remote in
                    DisclosureGroup(isExpanded: expansion("remote:\(remote.name)", default: true)) {
                        refContent(remote.section, commitGraph: commitGraph, repositoryID: repositoryID, icon: "cloud")
                    } label: {
                        CountedLabel(title: remote.name, systemImage: "network", count: remote.section.count)
                    }
                }
            } header: {
                SectionHeader(title: "Remotes", count: tree.remoteCount)
            }
        }
        if tree.tags.count > 0 {
            Section(isExpanded: isFiltering ? .constant(true) : $tagsExpanded) {
                refContent(tree.tags, commitGraph: commitGraph, repositoryID: repositoryID, icon: "tag")
            } header: {
                SectionHeader(title: "Tags", count: tree.tags.count)
            }
        }
    }

    @ViewBuilder
    private func refContent(_ section: RefSection, commitGraph: CommitGraph, repositoryID: UUID, icon: String) -> some View {
        ForEach(section.groups) { group in
            DisclosureGroup(isExpanded: expansion(group.id)) {
                ForEach(group.items) { item in
                    refRow(item, commitGraph: commitGraph, repositoryID: repositoryID, icon: icon)
                }
            } label: {
                CountedLabel(title: group.title, systemImage: "folder", count: group.items.count)
            }
        }
        ForEach(section.items) { item in
            refRow(item, commitGraph: commitGraph, repositoryID: repositoryID, icon: icon)
        }
    }

    private func refRow(_ item: RefItem, commitGraph: CommitGraph, repositoryID: UUID, icon: String) -> some View {
        let pullRequest = item.ref.kind == .tag ? nil
            : state.graph?.model.pullRequests?.openPullRequest(forBranch: item.ref.remoteParts?.branch ?? item.ref.name)
        return RefRow(item: item, date: commitGraph.date(of: item.ref.commit), subject: commitGraph.subjects[Int(item.ref.commit)],
                      systemImage: icon, pullRequest: pullRequest)
            .tag(SidebarItem.ref(repositoryID, item.ref.fullName))
    }

    /// An open pull request; selecting it goes to its branch.
    @ViewBuilder
    private func pullRequestRow(_ pullRequest: PullRequest, commitGraph: CommitGraph, repositoryID: UUID) -> some View {
        let ref = commitGraph.refs.first { $0.kind == .local && $0.name == pullRequest.head }
            ?? commitGraph.refs.first { $0.kind == .remote && $0.remoteParts?.branch == pullRequest.head }
        let row = Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pullRequest.number)")
                        .monospacedDigit()
                        .foregroundStyle(pullRequest.isDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                    Text(pullRequest.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if let readiness = pullRequest.readiness {
                        ReadinessMark(readiness: readiness)
                    }
                }
                Text(verbatim: "\(pullRequest.base) ← \(pullRequest.head)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: pullRequest.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                .foregroundStyle(.secondary)
        }
        .help(Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)\n\(pullRequest.stateTitle)\(pullRequest.author.map { " · \($0)" } ?? "")"))
        if let ref {
            row.tag(SidebarItem.ref(repositoryID, ref.fullName))
        } else {
            row.foregroundStyle(.secondary)
        }
    }

    // MARK: Features

    @ViewBuilder
    private func featuresSection(_ graph: GraphViewModel, repositoryID: UUID) -> some View {
        Section(isExpanded: $featuresExpanded) {
            if let progress = graph.featureProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let report = graph.features {
                ForEach(report.areas, id: \.name) { area in
                    DisclosureGroup(isExpanded: expansion("area:\(area.name)", default: true)) {
                        ForEach(area.groups) { group in
                            FeatureRow(group: group)
                                .tag(SidebarItem.feature(repositoryID, group.id))
                        }
                    } label: {
                        CountedLabel(title: area.name, systemImage: "square.grid.2x2", count: area.groups.count)
                    }
                }
                if let note = report.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if graph.featureProgress == nil {
                Button {
                    graph.analyzeFeatures()
                } label: {
                    Label("Group Recent Commits", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Group the latest \(graph.featureCommitLimit) commits into features with Apple's on-device model")
            }
        } header: {
            HStack {
                Text("Features")
                Spacer()
                if graph.features != nil && graph.featureProgress == nil {
                    Menu {
                        Button("Group Again") { graph.analyzeFeatures() }
                        Picker("Commits to Group", selection: Bindable(graph).featureCommitLimit) {
                            ForEach([100, 200, 500, 1000], id: \.self) { Text("Latest \($0)").tag($0) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    /// One pull request of a stack; selecting it goes to its branch.
    @ViewBuilder
    private func stackRow(_ pullRequest: PullRequest, position: Int, commitGraph: CommitGraph, repositoryID: UUID) -> some View {
        let ref = commitGraph.refs.first { $0.kind == .local && $0.name == pullRequest.head }
            ?? commitGraph.refs.first { $0.kind == .remote && $0.remoteParts?.branch == pullRequest.head }
        let row = Label {
            HStack(spacing: 6) {
                Text("\(position + 1). \(pullRequest.head)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: "#\(pullRequest.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pullRequest.isDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
            }
        } icon: {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(.secondary)
        }
        .help(Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)\n\(pullRequest.base) ← \(pullRequest.head)"))
        if let ref {
            row.tag(SidebarItem.ref(repositoryID, ref.fullName))
        } else {
            row.foregroundStyle(.secondary)
        }
    }

    private func expansion(_ id: String, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: { isFiltering || (expanded[id] ?? defaultValue) },
            set: { expanded[id] = $0 }
        )
    }

    // MARK: Menus

    @ViewBuilder
    private func contextMenu(for item: SidebarItem) -> some View {
        switch item {
        case .repository(let id):
            if let repository = library.repository(id: id) { repositoryMenu(repository) }
        case .ref(_, let fullName):
            if let ref = state.graph?.commitGraph?.refs.first(where: { $0.fullName == fullName }) { refMenu(ref) }
        case .feature:
            Button("Clear Highlight") { state.graph?.showFeature(id: nil) }
        }
    }

    @ViewBuilder
    private func repositoryMenu(_ repository: Repository) -> some View {
        Button("Open in New Tab") {
            WindowTabbing.openNextWindowAsTab()
            openWindow(id: "repository", value: repository.id)
        }
        Button("Open in New Window") { openWindow(id: "repository", value: repository.id) }
        Divider()
        Button("Show in Finder") { state.showInFinder(repository) }
        if repository.kind == .local {
            Button("Open in Terminal") { state.openInTerminal(repository) }
        }
        if let hosting = state.hosting(for: repository) {
            Button("Open on \(hosting.displayName)") { NSWorkspace.shared.open(hosting.webURL) }
        }
        Divider()
        Button("Fetch") { state.fetch(repository) }
        Button("Repository Settings…") { state.editingRepository = repository }
        Divider()
        Button("Remove from GitTree…", role: .destructive) { state.repositoryPendingRemoval = repository }
    }

    @ViewBuilder
    private func refMenu(_ ref: GitRef) -> some View {
        Button(ref.kind == .tag ? "Show Only This Tag" : "Show Only This Branch") {
            state.graph?.showOnly(refNamed: ref.fullName)
        }
        Button("Reveal in Graph") { state.graph?.reveal(refNamed: ref.fullName) }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.remoteParts?.branch ?? ref.name, forType: .string)
        }
        if let hosting = state.graph?.model.hosting {
            Divider()
            if ref.kind == .tag {
                Button("Open on \(hosting.displayName)") { NSWorkspace.shared.open(hosting.tagURL(ref.name)) }
            } else {
                let branch = ref.remoteParts?.branch ?? ref.name
                Button("Open on \(hosting.displayName)") { NSWorkspace.shared.open(hosting.branchURL(branch)) }
                let known = state.graph?.model.pullRequests?.pullRequests(forBranch: branch) ?? []
                if !known.isEmpty {
                    Menu("Pull Requests") {
                        ForEach(known) { pullRequest in
                            Button {
                                NSWorkspace.shared.open(pullRequest.url)
                            } label: {
                                Text(verbatim: "#\(pullRequest.number) \(pullRequest.title) (\(pullRequest.stateTitle))")
                            }
                        }
                    }
                } else if let pulls = hosting.pullRequestsURL(forBranch: branch) {
                    Button("Pull Requests for This Branch") { NSWorkspace.shared.open(pulls) }
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = state.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Menu {
                    Button("Add Local Repository…", systemImage: "folder.badge.plus") { state.addLocalRepository() }
                    Button("Add Repositories in Folder…", systemImage: "folder.badge.gearshape") { state.addRepositoriesInFolder() }
                    Button("Clone Remote Repository…", systemImage: "icloud.and.arrow.down") { state.cloneRemoteRepository() }
                    Divider()
                    Picker("Sort Repositories By", selection: $library.sort) {
                        ForEach(RepositorySort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add repositories or change their order")

                TextField("Filter", text: $state.refFilter, prompt: Text("Filter repositories, branches, tags"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct RepositoryRow: View {
    let repository: Repository
    let isCurrent: Bool

    var body: some View {
        let model = RepositoryModelStore.shared.existingModel(id: repository.id)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(repository.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if model?.isBusy == true {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(repository.locationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } icon: {
            Image(systemName: repository.kind == .remote ? "globe" : "folder")
        }
        .help(repository.fullLocation)
    }
}

private struct RefRow: View {
    let item: RefItem
    let date: Date
    let subject: String
    let systemImage: String
    /// The branch's open pull request, if any.
    var pullRequest: PullRequest?

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.label)
                    .fontWeight(item.ref.isHead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let pullRequest {
                    Text(verbatim: "#\(pullRequest.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pullRequest.isDraft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                }
                Text(RelativeAge.short(date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: item.ref.isHead ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(item.ref.isHead ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .help(help)
    }

    private var help: String {
        var lines = [item.ref.name, subject]
        if let pullRequest { lines.append("Pull request #\(pullRequest.number): \(pullRequest.title)") }
        return lines.joined(separator: "\n")
    }
}

/// A feature: its name, ticket and how many commits it has.
private struct FeatureRow: View {
    let group: FeatureGroup

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(group.commits.count.formatted())
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: [group.ticket, RelativeAge.short(group.latest)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: group.ticket == nil ? "circle.grid.cross" : "ticket")
                .foregroundStyle(.secondary)
        }
        .help(Text(verbatim: "\(group.name)\n\(group.commits.count) commits by \(group.authors.prefix(3).joined(separator: ", "))"))
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CountedLabel: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text(count.formatted())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

/// Compact ages for lists: 5m, 3h, 12d, 4mo, 2.5y.
enum RelativeAge {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<3600: return "\(max(1, Int(seconds / 60)))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 45): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30.4)))mo"
        default:
            let years = seconds / (86_400 * 365.25)
            return years < 3 ? String(format: "%.1fy", years).replacingOccurrences(of: ".0y", with: "y") : "\(Int(years))y"
        }
    }
}
