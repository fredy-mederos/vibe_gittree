import Foundation
import Observation

/// What one window shows of a repository: its scope, selection and search. Several windows can show
/// the same repository with different selections.
@MainActor @Observable final class GraphViewModel {
    let model: RepositoryModel

    var scope: GraphScope = .all {
        didSet { if scope != oldValue { rebuildLayout(reveal: true) } }
    }

    var showTags: Bool = UserDefaults.standard.object(forKey: AppSettings.showTagsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showTags, forKey: AppSettings.showTagsKey) }
    }

    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch(jump: true) } }
    }

    private(set) var layout: GraphLayout?
    /// Increments when `layout` is replaced, so the table knows to reload.
    private(set) var layoutVersion = 0
    private(set) var isLayingOut = false
    private(set) var selectedCommit: Int32?
    /// Increments when the selection should be scrolled into view.
    private(set) var revealToken = 0
    /// Rows matching the search, top to bottom.
    private(set) var matchRows: [Int32] = []
    private(set) var matchSet: Set<Int32> = []
    private(set) var currentMatch: Int?
    private(set) var searchVersion = 0

    /// Recent commits grouped into features (see `FeatureGrouper`).
    private(set) var features: FeatureReport?
    private(set) var featureProgress: String?
    /// The feature whose commits are highlighted in the graph.
    private(set) var selectedFeature: FeatureGroup?
    var featureCommitLimit = 200
    @ObservationIgnored private var featureTask: Task<Void, Never>?

    @ObservationIgnored private var selectedID: ObjectID?
    @ObservationIgnored private var appliedGeneration = -1
    @ObservationIgnored private var hasInitialSelection = false
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refTreeCache: (graph: CommitGraph, filter: String, tree: RefTree)?

    init(model: RepositoryModel) {
        self.model = model
        observeModel()
        syncWithModel()
    }

    /// The history the current layout was built from. Commit indexes in this model refer to it.
    var commitGraph: CommitGraph? { layout?.graph }

    var activeQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 2 ? query : nil
    }

    /// Text to highlight in matching rows: the search, or the selected feature's ticket key.
    var highlightText: String? {
        activeQuery ?? selectedFeature?.ticket
    }

    // MARK: Layout

    private func observeModel() {
        withObservationTracking {
            _ = model.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncWithModel()
                self?.observeModel()
            }
        }
    }

    private func syncWithModel() {
        guard model.generation != appliedGeneration, model.graph != nil else { return }
        appliedGeneration = model.generation
        rebuildLayout(reveal: false)
    }

    private func rebuildLayout(reveal: Bool) {
        guard let graph = model.graph else { return }
        layoutTask?.cancel()
        if case .ref(let name) = scope, !graph.refs.contains(where: { $0.fullName == name }) {
            scope = .all  // the branch is gone; this rebuilds again
            return
        }
        if scope == .all, let all = model.allLayout, all.graph === graph {
            isLayingOut = false
            apply(all, reveal: reveal)
            return
        }
        isLayingOut = true
        let scope = self.scope
        layoutTask = Task { [weak self] in
            let layout = await Task.detached(priority: .userInitiated) {
                LaneLayoutEngine.layout(graph: graph, scope: scope)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.isLayingOut = false
            self.apply(layout, reveal: reveal)
        }
    }

    private func apply(_ layout: GraphLayout, reveal: Bool) {
        let graph = layout.graph
        self.layout = layout
        layoutVersion += 1
        if let id = selectedID, let index = graph.indexByID[id] {
            selectedCommit = index
        } else if !hasInitialSelection {
            let head = graph.headCommit
            let initial = head >= 0 && layout.rowOfCommit[Int(head)] >= 0 ? head : layout.rows.first
            selectedCommit = initial
            selectedID = initial.map { graph.ids[Int($0)] }
        } else {
            selectedCommit = nil
            selectedID = nil
        }
        if reveal || !hasInitialSelection {
            hasInitialSelection = true
            revealToken += 1
        }
        scheduleSearch(jump: false)
    }

    // MARK: Selection

    /// The user clicked or arrowed to a row; it's already visible.
    func userSelected(_ commit: Int32?) {
        selectedCommit = commit
        selectedID = commit.flatMap { commit in commitGraph.map { $0.ids[Int(commit)] } }
    }

    /// Selects a commit and scrolls to it, widening the scope if it's hidden.
    func select(_ commit: Int32, reveal: Bool = true) {
        guard let graph = commitGraph, Int(commit) < graph.count else { return }
        selectedCommit = commit
        selectedID = graph.ids[Int(commit)]
        if let layout, layout.rowOfCommit[Int(commit)] < 0 {
            scope = .all
            return
        }
        if reveal { revealToken += 1 }
    }

    func reveal(refNamed fullName: String) {
        guard let ref = commitGraph?.refs.first(where: { $0.fullName == fullName }) else { return }
        select(ref.commit)
    }

    /// A branch by name, local or on any remote (pull requests only know the bare name).
    func revealBranch(named name: String) {
        guard let refs = commitGraph?.refs else { return }
        let ref = refs.first { $0.kind == .local && $0.name == name }
            ?? refs.first { $0.kind == .remote && $0.remoteParts?.branch == name }
        if let ref { select(ref.commit) }
    }

    func revealHead() {
        guard let graph = commitGraph, graph.headCommit >= 0 else { return }
        select(graph.headCommit)
    }

    func showOnly(refNamed fullName: String) {
        scope = .ref(fullName)
    }

    // MARK: Search

    func nextMatch() { stepMatch(by: 1) }
    func previousMatch() { stepMatch(by: -1) }

    private func stepMatch(by delta: Int) {
        guard let layout, !matchRows.isEmpty else { return }
        let next: Int
        if let current = currentMatch, current < matchRows.count {
            next = (current + delta + matchRows.count) % matchRows.count
        } else {
            let selectedRow = selectedCommit.map { Int(layout.rowOfCommit[Int($0)]) } ?? -1
            if delta > 0 {
                next = matchRows.firstIndex { Int($0) > selectedRow } ?? 0
            } else {
                next = matchRows.lastIndex { Int($0) < selectedRow } ?? matchRows.count - 1
            }
        }
        currentMatch = next
        select(layout.rows[Int(matchRows[next])])
    }

    private func scheduleSearch(jump: Bool) {
        searchTask?.cancel()
        if activeQuery == nil, selectedFeature != nil {
            applyFeatureHighlight(jump: false)
            return
        }
        guard let query = activeQuery, let layout else {
            if !matchRows.isEmpty || currentMatch != nil {
                matchRows = []
                matchSet = []
                currentMatch = nil
                searchVersion += 1
            }
            return
        }
        searchTask = Task { [weak self] in
            if jump { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let self else { return }
            let index = await self.model.searchIndex(for: layout.graph)
            let rows = await Task.detached(priority: .userInitiated) {
                SearchEngine.matches(query: query, layout: layout, index: index)
            }.value
            guard !Task.isCancelled else { return }
            self.matchRows = rows
            self.matchSet = Set(rows)
            self.searchVersion += 1
            if rows.isEmpty {
                self.currentMatch = nil
            } else if jump {
                // Stay on the selected commit if it still matches, otherwise go to the next match below it.
                let selectedRow = self.selectedCommit.map { Int(layout.rowOfCommit[Int($0)]) } ?? -1
                let start = rows.firstIndex { Int($0) >= max(selectedRow, 0) } ?? 0
                self.currentMatch = start
                self.select(layout.rows[Int(rows[start])])
            } else if let current = self.currentMatch, current >= rows.count {
                self.currentMatch = nil
            }
        }
    }

    // MARK: Features

    /// Groups the most recent commits of the current scope into features, off the main thread
    /// (the on-device model runs in its own process). Merges are left out; they repeat their branch.
    func analyzeFeatures() {
        guard featureTask == nil, let layout else { return }
        let graph = layout.graph
        var commits: [FeatureCommit] = []
        for row in 0..<layout.rowCount where commits.count < featureCommitLimit {
            let commit = layout.rows[row]
            guard !graph.isMerge(commit) else { continue }
            let index = Int(commit)
            commits.append(FeatureCommit(id: graph.ids[index], subject: graph.subjects[index],
                                         author: graph.authors[Int(graph.authorOf[index])], date: graph.date(of: commit)))
        }
        let regex = graph.ticketRegex
        featureProgress = "Grouping \(commits.count) commits…"
        featureTask = Task { [weak self] in
            await FeatureGrouper.analyze(commits, ticketRegex: regex) { message in
                self?.featureProgress = message
            } update: { report in
                self?.features = report
                // Keep the highlighted feature's commits in sync as names improve.
                if let selected = self?.selectedFeature, let refreshed = report.groups.first(where: { $0.id == selected.id }) {
                    self?.selectedFeature = refreshed
                }
            }
            guard let self else { return }
            self.featureProgress = nil
            self.featureTask = nil
        }
    }

    /// Highlights a feature's commits and jumps to its newest one; nil clears the highlight.
    func showFeature(id: String?) {
        guard let id, let group = features?.groups.first(where: { $0.id == id }) else {
            selectedFeature = nil
            scheduleSearch(jump: false)
            return
        }
        selectedFeature = group
        if !searchText.isEmpty { searchText = "" }
        applyFeatureHighlight(jump: true)
    }

    private func applyFeatureHighlight(jump: Bool) {
        guard let group = selectedFeature, let layout else { return }
        let rows = group.commits
            .compactMap { layout.graph.indexByID[$0.id] }
            .map { layout.rowOfCommit[Int($0)] }
            .filter { $0 >= 0 }
            .sorted()
        matchRows = rows
        matchSet = Set(rows)
        currentMatch = rows.isEmpty ? nil : 0
        searchVersion += 1
        if jump, let first = rows.first {
            select(layout.rows[Int(first)])
        }
    }

    // MARK: Sidebar

    func refTree(filter: String) -> RefTree? {
        guard let graph = commitGraph else { return nil }
        if let cache = refTreeCache, cache.graph === graph, cache.filter == filter { return cache.tree }
        let tree = RefTree(graph: graph, filter: filter)
        refTreeCache = (graph, filter, tree)
        return tree
    }
}

/// Lowercased subjects and authors, built once per history so searching stays fast.
struct SearchIndex: Sendable {
    let subjects: [String]
    let authors: [String]

    init(graph: CommitGraph) {
        subjects = graph.subjects.map { $0.lowercased() }
        authors = graph.authors.map { $0.lowercased() }
    }
}

enum SearchEngine {
    /// Rows whose subject, author, hash prefix or branch/tag name contains the query.
    static func matches(query: String, layout: GraphLayout, index: SearchIndex) -> [Int32] {
        let graph = layout.graph
        let needle = query.lowercased()
        let isHashQuery = needle.count >= 4 && needle.allSatisfy(\.isHexDigit)
        let authorHits = index.authors.map { $0.contains(needle) }
        var refHits = Set<Int32>()
        for ref in graph.refs where ref.name.lowercased().contains(needle) {
            refHits.insert(ref.commit)
        }
        var rows: [Int32] = []
        for row in 0..<layout.rowCount {
            let commit = Int(layout.rows[row])
            if index.subjects[commit].contains(needle)
                || authorHits[Int(graph.authorOf[commit])]
                || refHits.contains(Int32(commit))
                || (isHashQuery && graph.ids[commit].hex.hasPrefix(needle)) {
                rows.append(Int32(row))
            }
        }
        return rows
    }
}
