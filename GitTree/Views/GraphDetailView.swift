import SwiftUI

/// The graph with its toolbar, search, status bar and commit inspector.
struct GraphDetailView: View {
    @Bindable var graph: GraphViewModel
    @Bindable var state: WindowState
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    /// The details' width as last dragged, for every window and repository (SwiftUI doesn't keep it).
    @AppStorage(AppSettings.inspectorWidthKey) private var inspectorWidth = AppSettings.defaultInspectorWidth
    @State private var inspectorWidthKeeper = InspectorWidthKeeper()

    private static let inspectorWidths = 260.0...560.0

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GraphStatusBar(graph: graph, state: state)
            }
            .inspector(isPresented: $state.showInspector) {
                // SwiftUI opens it at its narrowest whatever the ideal width (a wider one can make it
                // fix the column's width), then the keeper gives it the width last dragged to.
                CommitInspector(graph: graph)
                    .darkerPanelInDarkMode()
                    .inspectorColumnWidth(min: Self.inspectorWidths.lowerBound, ideal: Self.inspectorWidths.lowerBound,
                                          max: Self.inspectorWidths.upperBound)
                    .onAppear(perform: keepInspectorWidth)
            }
            // Shown again, it keeps its content (no onAppear) but opens at its narrowest.
            .onChange(of: state.showInspector) { _, shown in
                if shown { keepInspectorWidth() }
            }
            .toolbar { toolbar }
            .searchable(text: $graph.searchText, placement: .toolbar, prompt: Text("Commits, authors, hashes, branches"))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { graph.nextMatch() }
            .onChange(of: state.searchFocusRequest) { searchFocused = true }
            .sheet(isPresented: $state.isFixVersionPromptPresented) {
                FixVersionPrompt { fixVersion in graph.highlightFixVersion(fixVersion) }
            }
    }

    private func keepInspectorWidth() {
        inspectorWidthKeeper.attach(to: state.window, width: inspectorWidth, range: Self.inspectorWidths) { width in
            inspectorWidth = width
        }
    }

    @ViewBuilder private var content: some View {
        let model = graph.model
        if graph.layout != nil {
            GraphTableView(
                graph: graph,
                layoutVersion: graph.layoutVersion,
                selectedCommit: graph.selectedCommit,
                selectsWorkingTree: graph.selectsWorkingTree,
                revealToken: graph.revealToken,
                searchVersion: graph.searchVersion,
                showTags: graph.showTags,
                annotationVersion: model.annotationVersion &+ JiraStore.shared.version,
                workingTreeVersion: model.workingTreeVersion,
                onShowDetails: { state.showInspector = true },
                onCompare: { openWindow(id: "compare", value: $0) }
            )
            .overlay {
                if graph.layout?.rowCount == 0 && graph.layout?.workingRow == nil {
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
        if let jira = JiraStore.shared.connection(for: graph.model.repository) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Tickets in the latest 500 commits") {
                        ForEach(TicketFilter.allCases, id: \.title) { filter in
                            Button(filter.title) { graph.highlightTickets(filter) }
                        }
                    }
                    Section("Fix Version") {
                        // The unreleased versions this repository's tickets are in, then others seen in its tickets.
                        let unreleased = graph.releases?.used ?? []
                        ForEach(unreleased.prefix(10)) { version in
                            Button(version.name) { graph.highlightFixVersion(version.name, id: version.id) }
                        }
                        let known = JiraStore.shared.knownFixVersions(for: jira).filter { name in !unreleased.contains { $0.name == name } }
                        ForEach(known.prefix(unreleased.isEmpty ? 12 : 6), id: \.self) { fixVersion in
                            Button(fixVersion) { graph.highlightFixVersion(fixVersion) }
                        }
                        Button("Other Fix Version…") { state.isFixVersionPromptPresented = true }
                    }
                    if graph.highlight != nil {
                        Divider()
                        Button("Clear Highlight") { graph.clearHighlight() }
                    }
                } label: {
                    Label("Highlight", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Highlight commits by ticket status or fix version")
            }
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
                openWindow(id: "activity", value: graph.model.id)
            } label: {
                Label("Activity", systemImage: "calendar")
            }
            .help("Show commits per day in a calendar")
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
            if let progress = graph.highlightProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                }
            } else if graph.activeQuery == nil, let highlight = graph.highlight {
                HStack(spacing: 4) {
                    Image(systemName: highlight.systemImage)
                    Text(highlight.title)
                        .lineLimit(1)
                    if graph.highlightRefining {
                        ProgressView()
                            .controlSize(.mini)
                            .help("Asking Jira for the rest of its tickets")
                    }
                    if let note = graph.highlightNote {
                        Text(verbatim: "· \(note)")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    Button { graph.clearHighlight() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Stop highlighting")
                }
                .foregroundStyle(.secondary)
            } else if let note = graph.highlightNote {
                HStack(spacing: 4) {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(note)
                    Button { graph.clearHighlight() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
            if graph.activeQuery != nil || (graph.highlight != nil && graph.highlightProgress == nil) {
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
                // Without a current match the selection is elsewhere (a highlight that didn't move it).
                Text(graph.currentMatch.map { String(localized: "\($0 + 1) of \(graph.matchRows.count)", comment: "The current search match and how many there are") }
                     ?? String(localized: "\(graph.matchRows.count) matches"))
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
            let commits = String(localized: "\(commitGraph.count) commits")
            return String(localized: "\(layout.rowCount) of \(commits) · \(layout.scope.title)", comment: "Commits shown of all commits, then which branches are shown")
        }
        let refs = commitGraph.refs
        var parts = [
            String(localized: "\(commitGraph.count) commits"),
            String(localized: "\(commitGraph.mergeCount) merges"),
            String(localized: "\(refs.filter { $0.kind == .local }.count) branches"),
        ]
        let remotes = refs.filter { $0.kind == .remote }.count
        if remotes > 0 { parts.append(String(localized: "\(remotes) remote", comment: "Remote branches, after the local ones: 12 branches · 30 remote")) }
        parts.append(String(localized: "\(refs.filter { $0.kind == .tag }.count) tags"))
        return parts.joined(separator: " · ")
    }
}

/// Asks which fix version to highlight when it isn't among the ones already seen.
private struct FixVersionPrompt: View {
    let onHighlight: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fixVersion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlight a Fix Version")
                .font(.headline)
            Text("Vibe GitTree asks Jira for the tickets in this fix version and highlights the commits that mention them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Fix version", text: $fixVersion, prompt: Text("2.12"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(highlight)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Highlight", action: highlight)
                    .keyboardShortcut(.defaultAction)
                    .disabled(fixVersion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func highlight() {
        let value = fixVersion.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        onHighlight(value)
        dismiss()
    }
}
