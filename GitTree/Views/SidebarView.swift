import SwiftUI

/// Repositories on top, then the current repository's branches, remotes and tags.
struct SidebarView: View {
    @Bindable var state: WindowState
    @Environment(\.openWindow) private var openWindow
    private let library = RepositoryLibrary.shared

    @AppStorage("sidebar.repositoriesExpanded") private var repositoriesExpanded = true
    @AppStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = false
    @State private var expanded: [String: Bool] = [:]

    private var isFiltering: Bool {
        !state.refFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List(selection: $state.sidebarSelection) {
            Section("Repositories", isExpanded: $repositoriesExpanded) {
                ForEach(library.repositories) { repository in
                    RepositoryRow(repository: repository, isCurrent: repository.id == state.repositoryID)
                        .tag(SidebarItem.repository(repository.id))
                        .contextMenu { repositoryMenu(repository) }
                }
                .onMove { library.move(fromOffsets: $0, toOffset: $1) }
            }

            if let graph = state.graph, let repositoryID = state.repositoryID,
               let commitGraph = graph.commitGraph, let tree = graph.refTree(filter: state.refFilter) {
                refSections(tree, commitGraph: commitGraph, repositoryID: repositoryID)
            }
        }
        .listStyle(.sidebar)
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
        RefRow(item: item, date: commitGraph.date(of: item.ref.commit), subject: commitGraph.subjects[Int(item.ref.commit)], systemImage: icon)
            .tag(SidebarItem.ref(repositoryID, item.ref.fullName))
            .contextMenu { refMenu(item.ref) }
    }

    private func expansion(_ id: String, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: { isFiltering || (expanded[id] ?? defaultValue) },
            set: { expanded[id] = $0 }
        )
    }

    // MARK: Menus

    @ViewBuilder
    private func repositoryMenu(_ repository: Repository) -> some View {
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
                if let pulls = hosting.pullRequestsURL(forBranch: branch) {
                    Button("Pull Requests for This Branch") { NSWorkspace.shared.open(pulls) }
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Add Local Repository…", systemImage: "folder.badge.plus") { state.addLocalRepository() }
                Button("Clone Remote Repository…", systemImage: "icloud.and.arrow.down") { state.cloneRemoteRepository() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a repository")

            TextField("Filter", text: $state.refFilter, prompt: Text("Filter branches and tags"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
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
            HStack(spacing: 6) {
                Text(repository.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model?.isBusy == true {
                    ProgressView().controlSize(.mini)
                }
            }
        } icon: {
            Image(systemName: repository.kind == .remote ? "globe" : "folder")
        }
        .help(repository.kind == .remote ? (repository.remoteURL ?? repository.path) : repository.path)
    }
}

private struct RefRow: View {
    let item: RefItem
    let date: Date
    let subject: String
    let systemImage: String

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.label)
                    .fontWeight(item.ref.isHead ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(RelativeAge.short(date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        } icon: {
            Image(systemName: item.ref.isHead ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(item.ref.isHead ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .help("\(item.ref.name)\n\(subject)")
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
