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

    private func matchesFilter(_ repository: Repository) -> Bool {
        let needle = filterText.lowercased()
        return repository.name.lowercased().contains(needle) || repository.fullLocation.lowercased().contains(needle)
    }

    /// The unpinned repositories to list and how many are tucked away behind "Show All".
    private var visibleRepositories: (shown: [Repository], hidden: Int) {
        let all = library.sortedRepositories
        if isFiltering {
            return (all.filter(matchesFilter), 0)
        }
        guard !state.showsAllRepositories, all.count > Self.collapsedLimit + 1 else { return (all, 0) }
        var shown = Array(all.prefix(Self.collapsedLimit))
        if let current = all.first(where: { $0.id == state.repositoryID }), !shown.contains(where: { $0.id == current.id }) {
            shown.append(current)
        }
        return (shown, all.count - shown.count)
    }

    /// With grouping on: unpinned repositories by folder or host, groups sorted by name.
    private var repositoryGroups: [(name: String, repositories: [Repository])] {
        let all = library.sortedRepositories.filter { !isFiltering || matchesFilter($0) }
        let key: (Repository) -> String = library.grouping == .host ? { $0.hostGroup } : { $0.folderGroup }
        var order: [String] = []
        var grouped: [String: [Repository]] = [:]
        for repository in all {
            let name = key(repository)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(repository)
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, grouped[$0] ?? []) }
    }

    private func repositoryRow(_ repository: Repository) -> some View {
        RepositoryRow(repository: repository, isCurrent: repository.id == state.repositoryID)
            .tag(SidebarItem.repository(repository.id))
    }

    var body: some View {
        List(selection: $state.sidebarSelection) {
            let visible = visibleRepositories
            let groups = library.grouping == .none ? [] : repositoryGroups
            FoldingSection(isExpanded: isFiltering ? .constant(true) : $repositoriesExpanded) {
                ForEach(library.pinnedRepositories.filter { !isFiltering || matchesFilter($0) }) { repository in
                    repositoryRow(repository)
                }
                if library.grouping != .none {
                    ForEach(groups, id: \.name) { group in
                        let isExpanded = expansion("repositories:\(group.name)", default: true)
                        DisclosureGroup(isExpanded: isExpanded) {
                            ForEach(group.repositories) { repositoryRow($0) }
                        } label: {
                            CountedLabel(title: group.name, systemImage: library.grouping == .host ? "network" : "folder",
                                         count: group.repositories.count)
                                .togglesDisclosure(isExpanded)
                        }
                    }
                } else {
                ForEach(visible.shown) { repository in
                    repositoryRow(repository)
                }
                .onMove(perform: library.sort == .manual && !isFiltering && visible.hidden == 0 ? { library.move(fromOffsets: $0, toOffset: $1) } : nil)
                }
                if library.grouping == .none, visible.hidden > 0 {
                    Button {
                        state.showsAllRepositories = true
                    } label: {
                        Label("Show All \(library.repositories.count)", systemImage: "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if library.grouping == .none, state.showsAllRepositories, !isFiltering,
                          library.sortedRepositories.count > Self.collapsedLimit + 1 {
                    Button {
                        state.showsAllRepositories = false
                    } label: {
                        Label("Show Fewer", systemImage: "chevron.up")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionHeader(title: "Repositories", count: library.repositories.count,
                              fold: repositoriesExpanded ? fold(groups.map { ("repositories:\($0.name)", true) }) : nil)
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
            // Double-click or Return on a branch, tag or open pull request shows only its history.
            switch items.first {
            case .ref(_, let fullName)?:
                state.graph?.showOnly(refNamed: fullName)
            case .pullRequest(_, let number)?:
                if let graph = state.graph, let commitGraph = graph.commitGraph,
                   let pullRequest = graph.model.pullRequests?.byNumber[number], pullRequest.state == .open,
                   let ref = pullRequest.ref(in: commitGraph) {
                    graph.showOnly(refNamed: ref.fullName)
                }
            default:
                break
            }
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
            let groups = pullRequestGroups(pullRequests)
            if !groups.isEmpty {
                FoldingSection(isExpanded: $pullRequestsExpanded) {
                    ForEach(groups, id: \.id) { group in
                        let isExpanded = expansion(group.id, default: group.expandedByDefault)
                        DisclosureGroup(isExpanded: isExpanded) {
                            ForEach(group.pullRequests) { pullRequest in
                                pullRequestRow(pullRequest, commitGraph: commitGraph, repositoryID: repositoryID)
                            }
                        } label: {
                            CountedLabel(title: group.title, systemImage: group.systemImage, count: group.pullRequests.count)
                                .togglesDisclosure(isExpanded)
                        }
                    }
                } header: {
                    SectionHeader(title: "Pull Requests", count: groups.reduce(0) { $0 + $1.pullRequests.count },
                                  fold: pullRequestsExpanded ? fold(groups.map { ($0.id, $0.expandedByDefault) }) : nil)
                }
            }
        }
        if let pullRequests = state.graph?.model.pullRequests, !pullRequests.stacks.isEmpty, !isFiltering {
            FoldingSection(isExpanded: $stacksExpanded) {
                ForEach(pullRequests.stacks, id: \.first?.number) { stack in
                    let isExpanded = expansion("stack:\(stack.first?.number ?? 0)", default: true)
                    DisclosureGroup(isExpanded: isExpanded) {
                        ForEach(Array(stack.enumerated()), id: \.element.number) { position, pullRequest in
                            stackRow(pullRequest, position: position, commitGraph: commitGraph, repositoryID: repositoryID)
                        }
                    } label: {
                        CountedLabel(title: "on \(stack.first?.base ?? "")", systemImage: "square.stack.3d.up", count: stack.count)
                            .togglesDisclosure(isExpanded)
                            .contextMenu {
                                if let top = stack.last {
                                    // Selecting the top pull request highlights the whole stack.
                                    Button("Highlight Stack") { state.sidebarSelection = .pullRequest(repositoryID, top.number) }
                                }
                            }
                    }
                }
            } header: {
                SectionHeader(title: "Pull Request Stacks", count: pullRequests.stacks.count,
                              fold: stacksExpanded ? fold(pullRequests.stacks.map { ("stack:\($0.first?.number ?? 0)", true) }) : nil)
            }
        }
        if tree.local.count > 0 {
            FoldingSection(isExpanded: isFiltering ? .constant(true) : $branchesExpanded) {
                refContent(tree.local, commitGraph: commitGraph, repositoryID: repositoryID, icon: "arrow.triangle.branch")
            } header: {
                SectionHeader(title: "Branches", count: tree.local.count,
                              fold: branchesExpanded ? fold(tree.local.groups.map { ($0.id, false) }) : nil)
            }
        }
        if !tree.remotes.isEmpty {
            FoldingSection(isExpanded: isFiltering ? .constant(true) : $remotesExpanded) {
                ForEach(tree.remotes) { remote in
                    let isExpanded = expansion("remote:\(remote.name)", default: true)
                    DisclosureGroup(isExpanded: isExpanded) {
                        refContent(remote.section, commitGraph: commitGraph, repositoryID: repositoryID, icon: "cloud")
                    } label: {
                        CountedLabel(title: remote.name, systemImage: "network", count: remote.section.count)
                            .togglesDisclosure(isExpanded)
                    }
                }
            } header: {
                // Folds the folders inside each remote; the remotes themselves (origin) stay open.
                SectionHeader(title: "Remotes", count: tree.remoteCount,
                              fold: remotesExpanded ? fold(tree.remotes.flatMap { remote in remote.section.groups.map { ($0.id, false) } }) : nil)
            }
        }
        if tree.tags.count > 0 {
            FoldingSection(isExpanded: isFiltering ? .constant(true) : $tagsExpanded) {
                refContent(tree.tags, commitGraph: commitGraph, repositoryID: repositoryID, icon: "tag")
            } header: {
                SectionHeader(title: "Tags", count: tree.tags.count,
                              fold: tagsExpanded ? fold(tree.tags.groups.map { ($0.id, false) }) : nil)
            }
        }
    }

    /// Collapse All / Expand All for the groups inside a section, leaving the section itself open.
    /// Each group comes with whether it starts expanded.
    private func fold(_ groups: [(id: String, expandedByDefault: Bool)]) -> FoldControl? {
        guard !groups.isEmpty, !isFiltering else { return nil }
        let anyExpanded = groups.contains { expanded[scopedKey($0.id)] ?? $0.expandedByDefault }
        return FoldControl(anyExpanded: anyExpanded) {
            withAnimation {
                for group in groups { expanded[scopedKey(group.id)] = !anyExpanded }
            }
        }
    }

    /// Groups of the shown repository (folders, stacks, terms) are remembered per repository;
    /// the repository list's own groups are shared.
    private func scopedKey(_ id: String) -> String {
        id.hasPrefix("repositories:") ? id : "\(state.repositoryID?.uuidString ?? "") \(id)"
    }

    @ViewBuilder
    private func refContent(_ section: RefSection, commitGraph: CommitGraph, repositoryID: UUID, icon: String) -> some View {
        ForEach(section.groups) { group in
            let isExpanded = expansion(group.id)
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(group.items) { item in
                    refRow(item, commitGraph: commitGraph, repositoryID: repositoryID, icon: icon)
                }
            } label: {
                CountedLabel(title: group.title, systemImage: "folder", count: group.items.count)
                    .togglesDisclosure(isExpanded)
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

    private struct PullRequestGroup {
        let id: String
        let title: String
        let systemImage: String
        let pullRequests: [PullRequest]
        let expandedByDefault: Bool
    }

    /// Open (outside stacks, which have their own section), drafts, and the latest merged and closed.
    private func pullRequestGroups(_ index: PullRequestIndex) -> [PullRequestGroup] {
        let stacked = Set(index.stacks.flatMap { $0.map(\.number) })
        let newest = index.all.sorted { $0.number > $1.number }
        let open = newest.filter { $0.state == .open && !$0.isDraft && !stacked.contains($0.number) }
        let drafts = newest.filter { $0.state == .open && $0.isDraft && !stacked.contains($0.number) }
        let merged = Array(newest.filter { $0.state == .merged }.prefix(25))
        let closed = Array(newest.filter { $0.state == .closed }.prefix(15))
        return [
            PullRequestGroup(id: "pulls:open", title: "Open", systemImage: "arrow.triangle.pull", pullRequests: open, expandedByDefault: true),
            PullRequestGroup(id: "pulls:drafts", title: "Drafts", systemImage: "circle.dashed", pullRequests: drafts, expandedByDefault: false),
            PullRequestGroup(id: "pulls:merged", title: "Recently Merged", systemImage: "arrow.triangle.merge", pullRequests: merged, expandedByDefault: false),
            PullRequestGroup(id: "pulls:closed", title: "Recently Closed", systemImage: "xmark.circle", pullRequests: closed, expandedByDefault: false),
        ].filter { !$0.pullRequests.isEmpty }
    }

    /// A pull request; selecting it goes to its merge commit (merged) or its branch.
    @ViewBuilder
    private func pullRequestRow(_ pullRequest: PullRequest, commitGraph: CommitGraph, repositoryID: UUID, position: Int? = nil) -> some View {
        let reachable = pullRequest.ref(in: commitGraph) != nil
            || (pullRequest.state == .merged && pullRequest.mergeCommit.map { commitGraph.indexByID[$0] != nil } == true)
        let row = Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let position {
                        Text(verbatim: "\(position + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Text(verbatim: "#\(pullRequest.number)")
                        .monospacedDigit()
                        .foregroundStyle(Self.stateColor(pullRequest))
                    Text(pullRequest.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if pullRequest.state == .open, let readiness = pullRequest.readiness {
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
        // Its own selection, not its branch's: selecting it shouldn't also select the branch row.
        if reachable {
            row.tag(SidebarItem.pullRequest(repositoryID, pullRequest.number))
        } else {
            row.foregroundStyle(.secondary)
        }
    }

    private static func stateColor(_ pullRequest: PullRequest) -> Color {
        if pullRequest.state == .open && pullRequest.isDraft { return .secondary }
        switch pullRequest.state {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    // MARK: Features

    @ViewBuilder
    private func featuresSection(_ graph: GraphViewModel, repositoryID: UUID) -> some View {
        FoldingSection(isExpanded: $featuresExpanded) {
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
                    let isExpanded = expansion("area:\(area.name)", default: true)
                    DisclosureGroup(isExpanded: isExpanded) {
                        ForEach(area.groups) { group in
                            FeatureRow(group: group)
                                .tag(SidebarItem.feature(repositoryID, group.id))
                        }
                    } label: {
                        CountedLabel(title: area.name, systemImage: "square.grid.2x2", count: area.groups.count)
                            .togglesDisclosure(isExpanded)
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
                if featuresExpanded, let report = graph.features, let fold = fold(report.areas.map { ("area:\($0.name)", true) }) {
                    FoldButton(fold: fold)
                }
                if graph.features != nil && graph.featureProgress == nil {
                    Menu {
                        Button("Group Again") { graph.analyzeFeatures() }
                        Button("Forget Learned Terms and Group Again") { graph.forgetFeatureTerms() }
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

    /// One pull request of a stack, laid out like the other pull requests with its place in the stack.
    private func stackRow(_ pullRequest: PullRequest, position: Int, commitGraph: CommitGraph, repositoryID: UUID) -> some View {
        pullRequestRow(pullRequest, commitGraph: commitGraph, repositoryID: repositoryID, position: position)
    }

    /// Open while filtering, so matches show; clicks then change nothing that outlasts the filter.
    private func expansion(_ id: String, default defaultValue: Bool = false) -> Binding<Bool> {
        let key = scopedKey(id)
        return Binding(
            get: { isFiltering || (expanded[key] ?? defaultValue) },
            set: { if !isFiltering { expanded[key] = $0 } }
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
        case .pullRequest(_, let number):
            if let pullRequest = state.graph?.model.pullRequests?.byNumber[number] {
                Button("Open on GitHub") { NSWorkspace.shared.open(pullRequest.url) }
                if pullRequest.state == .open, let commitGraph = state.graph?.commitGraph,
                   let ref = pullRequest.ref(in: commitGraph) {
                    Button("Show Only This Branch") { state.graph?.showOnly(refNamed: ref.fullName) }
                }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private func repositoryMenu(_ repository: Repository) -> some View {
        Button(repository.pinnedAt == nil ? "Pin to Top" : "Unpin") {
            library.setPinned(repository.pinnedAt == nil, for: repository.id)
        }
        Divider()
        Button("Open in New Tab") {
            WindowTabbing.openNextWindowAsTab(in: state.window)
            openWindow(id: "repository", value: WindowTarget.opening(repository.id))
        }
        Button("Open in New Window") { openWindow(id: "repository", value: WindowTarget.opening(repository.id)) }
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
                    Picker("Group Repositories By", selection: $library.grouping) {
                        ForEach(RepositoryGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
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
                    } else if repository.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .help("Pinned")
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

/// A sidebar section whose chevron always shows (the system one appears only on hover). Clicking
/// anywhere on the header opens or closes it.
private struct FoldingSection<Content: View, Header: View>: View {
    @Binding var isExpanded: Bool
    let content: Content
    let header: Header

    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        _isExpanded = isExpanded
        self.content = content()
        self.header = header()
    }

    var body: some View {
        Section {
            if isExpanded { content }
        } header: {
            HStack(spacing: 6) {
                header
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", toggle)
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
    }
}

private extension View {
    /// Clicking a group's label opens or closes it, not only its small chevron.
    func togglesDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            }
    }
}

/// Whether any group in a section is open, and how to fold or unfold them all.
private struct FoldControl {
    let anyExpanded: Bool
    let toggle: () -> Void
}

private struct FoldButton: View {
    let fold: FoldControl

    var body: some View {
        Button(action: fold.toggle) {
            Image(systemName: fold.anyExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(fold.anyExpanded ? "Collapse All" : "Expand All")
        .accessibilityLabel(fold.anyExpanded ? "Collapse All" : "Expand All")
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    /// Collapse All / Expand All for the section's groups, when it has any.
    var fold: FoldControl?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let fold {
                FoldButton(fold: fold)
            }
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
