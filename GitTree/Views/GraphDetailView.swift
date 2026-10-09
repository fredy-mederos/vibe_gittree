import SwiftUI

/// The graph with its toolbar, search, status bar and commit inspector.
struct GraphDetailView: View {
    @Bindable var graph: GraphViewModel
    @Bindable var state: WindowState
    @FocusState private var searchFocused: Bool

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GraphStatusBar(graph: graph, state: state)
            }
            .inspector(isPresented: $state.showInspector) {
                CommitInspector(graph: graph)
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
            }
            .toolbar { toolbar }
            .searchable(text: $graph.searchText, placement: .toolbar, prompt: Text("Commits, authors, hashes, branches"))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { graph.nextMatch() }
            .onChange(of: state.searchFocusRequest) { searchFocused = true }
    }

    @ViewBuilder private var content: some View {
        let model = graph.model
        if graph.layout != nil {
            GraphTableView(
                graph: graph,
                layoutVersion: graph.layoutVersion,
                selectedCommit: graph.selectedCommit,
                revealToken: graph.revealToken,
                searchVersion: graph.searchVersion,
                showTags: graph.showTags,
                annotationVersion: model.annotationVersion &+ JiraStore.shared.version,
                onShowDetails: { state.showInspector = true }
            )
            .overlay {
                if graph.layout?.rowCount == 0 {
                    ContentUnavailableView("No Commits", systemImage: "circle.dashed",
                                           description: Text("This repository doesn't have any commits yet."))
                }
            }
        } else if case .failed(let message) = model.status {
            ContentUnavailableView {
                Label("Can't Read This Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        } else {
            ProgressView("Reading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Branches", selection: $graph.scope) {
                Text("All").tag(GraphScope.all)
                Text("Local").tag(GraphScope.local)
                Text("HEAD").tag(GraphScope.head)
            }
            .pickerStyle(.segmented)
            .help("Show every branch, only local branches, or only the checked-out branch")
        }
        if let isolated = graph.scope.refName {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    graph.scope = .all
                } label: {
                    Label("Only \(GitRef.shortName(fullName: isolated))", systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help("Show all branches again")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $graph.showTags) {
                Label("Tags", systemImage: "tag")
            }
            .help("Show tag labels in the graph")
        }
        ToolbarItem(placement: .primaryAction) {
            if graph.model.isFetching {
                ProgressView()
                    .controlSize(.small)
                    .help("Fetching…")
            } else {
                Button {
                    state.fetch()
                } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
                .help("Fetch new commits from the remote")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                state.showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .help("Show or hide commit details")
        }
    }
}

/// Where the repository lives, counts for the shown history, search progress and fetch status.
struct GraphStatusBar: View {
    let graph: GraphViewModel
    let state: WindowState

    var body: some View {
        HStack(spacing: 14) {
            let repository = graph.model.repository
            Button {
                if repository.kind == .remote, let web = graph.model.hosting?.webURL {
                    NSWorkspace.shared.open(web)
                } else {
                    state.showInFinder(repository)
                }
            } label: {
                Label(repository.fullLocation, systemImage: repository.kind == .remote ? "globe" : "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.borderless)
            .help(repository.kind == .remote ? "Cloned from \(repository.fullLocation)" : "Show \(repository.fullLocation) in Finder")
            .layoutPriority(-1)

            if let layout = graph.layout {
                Text(summary(layout))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if graph.activeQuery == nil, let feature = graph.selectedFeature {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(feature.name)
                        .lineLimit(1)
                    Button { graph.showFeature(id: nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop highlighting this feature")
                }
                .foregroundStyle(.secondary)
            }
            if graph.activeQuery != nil || graph.selectedFeature != nil {
                searchStatus
            }
            if graph.model.isFetching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Fetching…")
                }
            } else if let error = graph.model.fetchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var searchStatus: some View {
        HStack(spacing: 4) {
            if graph.matchRows.isEmpty {
                Text("No matches")
            } else {
                Text("\((graph.currentMatch.map { $0 + 1 } ?? 0).formatted()) of \(graph.matchRows.count.formatted())")
                    .monospacedDigit()
                Button { graph.previousMatch() } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { graph.nextMatch() } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
        }
        .buttonStyle(.borderless)
    }

    private func summary(_ layout: GraphLayout) -> String {
        let commitGraph = layout.graph
        if layout.scope != .all {
            return "\(layout.rowCount.formatted()) of \(counted(commitGraph.count, "commit", "commits")) · \(layout.scope.title)"
        }
        let refs = commitGraph.refs
        var parts = [
            counted(commitGraph.count, "commit", "commits"),
            counted(commitGraph.mergeCount, "merge", "merges"),
            counted(refs.filter { $0.kind == .local }.count, "branch", "branches"),
        ]
        let remotes = refs.filter { $0.kind == .remote }.count
        if remotes > 0 { parts.append("\(remotes.formatted()) remote") }
        parts.append(counted(refs.filter { $0.kind == .tag }.count, "tag", "tags"))
        return parts.joined(separator: " · ")
    }
}

/// "1 branch", "95 branches".
func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural)"
}
