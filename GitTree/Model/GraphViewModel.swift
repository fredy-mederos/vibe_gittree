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
        didSet {
            guard searchText != oldValue else { return }
            // A search wins over a highlight that's still loading.
            if !searchText.isEmpty { cancelHighlightLoad() }
            scheduleSearch(jump: true)
        }
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
    var featureCommitLimit = 200
    @ObservationIgnored private var featureTask: Task<Void, Never>?

    /// Commits highlighted by a feature or a ticket filter (a search takes precedence).
    private(set) var highlight: CommitHighlight?
    /// "Loading tickets…" while a ticket filter waits for Jira.
    private(set) var highlightProgress: String?
    /// A problem with the highlight: Jira couldn't list a fix version, or statuses still missing.
    private(set) var highlightNote: String?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    /// Loading a ticket or fix version highlight; a newer highlight, a search or Clear cancels it.
    @ObservationIgnored private var highlightLoadTask: Task<Void, Never>?

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

    /// Text to highlight in matching rows: the search, or the highlighted feature's ticket key.
    var highlightText: String? {
        activeQuery ?? highlight?.featureTicket
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
        if activeQuery == nil, highlight != nil {
            applyHighlight(jump: false)
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
        let repositoryID = model.id
        featureProgress = "Grouping \(commits.count) commits…"
        featureTask = Task { [weak self] in
            await FeatureGrouper.analyze(commits, ticketRegex: regex, repositoryID: repositoryID) { message in
                self?.featureProgress = message
            } update: { report in
                self?.features = report
                // Keep a highlighted feature in sync as the grouping improves.
                if let id = self?.highlight?.featureID, let refreshed = report.groups.first(where: { $0.id == id }) {
                    self?.highlight = .feature(refreshed)
                    self?.applyHighlight(jump: false)
                }
            }
            guard let self else { return }
            self.featureProgress = nil
            self.featureTask = nil
        }
    }

    /// Drops the terms learned for this repository and groups again from scratch.
    func forgetFeatureTerms() {
        guard featureTask == nil else { return }
        FeatureCatalog.forget(repositoryID: model.id)
        analyzeFeatures()
    }

    /// Highlights a feature's commits and jumps to its newest one; nil clears the highlight.
    func showFeature(id: String?) {
        guard let id, let group = features?.groups.first(where: { $0.id == id }) else {
            clearHighlight()
            return
        }
        setHighlight(.feature(group))
    }

    // MARK: Highlights

    /// Highlights the commits of tickets with a status, among the latest 500 commits of the scope.
    /// Missing statuses are fetched through the usual Jira queue first.
    func highlightTickets(_ filter: TicketFilter) {
        guard let layout, let jira = JiraStore.shared.connection(for: model.repository) else { return }
        let graph = layout.graph
        var keys: [String] = []
        var seen: Set<String> = []
        var looked = 0
        for row in 0..<layout.rowCount where looked < 500 {
            let commit = layout.rows[row]
            guard !graph.isMerge(commit) else { continue }
            looked += 1
            if let key = graph.ticketKeys(in: graph.subjects[Int(commit)]).first, seen.insert(key).inserted {
                keys.append(key)
            }
        }
        cancelHighlightLoad()
        highlightProgress = "Loading \(counted(keys.count, "ticket", "tickets"))…"
        highlightLoadTask = Task { [weak self] in
            await JiraStore.shared.ensure(keys, connection: jira)
            guard let self, !Task.isCancelled else { return }
            let matching = Set(keys.filter { key in
                guard let issue = JiraStore.shared.issue(key, connection: jira) else { return false }
                return filter.matches(issue)
            })
            let unsettled = keys.filter { !JiraStore.shared.isSettled($0, connection: jira) }.count
            self.setHighlight(.tickets(title: filter.title, keys: matching))
            if unsettled > 0 {
                self.highlightNote = "\(counted(unsettled, "status", "statuses")) still loading"
            }
        }
    }

    /// Highlights the commits of every ticket in a fix version, as listed by Jira.
    func highlightFixVersion(_ fixVersion: String) {
        guard let jira = JiraStore.shared.connection(for: model.repository) else { return }
        cancelHighlightLoad()
        highlightProgress = "Loading fix version \(fixVersion)…"
        highlightLoadTask = Task { [weak self] in
            do {
                let issues = try await JiraStore.shared.issues(inFixVersion: fixVersion, connection: jira)
                guard let self, !Task.isCancelled else { return }
                self.setHighlight(.tickets(title: "Fix version \(fixVersion)", keys: Set(issues.map(\.key))))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.cancelHighlightLoad()
                self.highlightNote = "Couldn't load fix version \(fixVersion): \(error.localizedDescription)"
            }
        }
    }

    /// Clears the highlight, a highlight still loading, and its note.
    func clearHighlight() {
        cancelHighlightLoad()
        guard highlight != nil else { return }
        highlight = nil
        scheduleSearch(jump: false)
    }

    /// Selecting something else in the sidebar ends a feature's or a pull request's highlight
    /// (ticket and fix version highlights come from the toolbar and stay).
    func clearSidebarHighlight() {
        if highlight?.followsSidebar == true { clearHighlight() }
    }

    /// Highlights the commits of open pull requests (one, or a stack), leaving the selection where
    /// it is: the commits on each branch that aren't on the branch it's based on.
    func highlightPullRequests(_ pullRequests: [PullRequest], title: String, systemImage: String) {
        guard let graph = commitGraph else { return }
        cancelHighlightLoad()
        highlightLoadTask = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) {
                PullRequestCommits.commits(of: pullRequests, in: graph)
            }.value
            guard let self, !Task.isCancelled, self.commitGraph === graph else { return }
            self.setHighlight(.commits(title: title, systemImage: systemImage, ids: ids), jump: false)
        }
    }

    private func cancelHighlightLoad() {
        highlightLoadTask?.cancel()
        highlightLoadTask = nil
        highlightProgress = nil
        highlightNote = nil
    }

    private func setHighlight(_ newHighlight: CommitHighlight, jump: Bool = true) {
        cancelHighlightLoad()
        highlight = newHighlight
        if !searchText.isEmpty { searchText = "" }
        applyHighlight(jump: jump)
    }

    private func applyHighlight(jump: Bool) {
        guard let highlight, let layout else { return }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { highlight.rows(in: layout) }.value
            guard let self, !Task.isCancelled, self.layout === layout else { return }
            self.matchRows = rows
            self.matchSet = Set(rows)
            self.currentMatch = rows.isEmpty ? nil : 0
            self.searchVersion += 1
            if jump, let first = rows.first {
                self.select(layout.rows[Int(first)])
            }
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

/// What a highlight (as opposed to a search) marks in the graph.
enum CommitHighlight: Sendable {
    case feature(FeatureGroup)
    case tickets(title: String, keys: Set<String>)
    /// A pull request's commits, or a whole stack's.
    case commits(title: String, systemImage: String, ids: Set<ObjectID>)

    var title: String {
        switch self {
        case .feature(let group): group.name
        case .tickets(let title, _): title
        case .commits(let title, _, _): title
        }
    }

    var systemImage: String {
        switch self {
        case .feature: "sparkles"
        case .tickets: "ticket"
        case .commits(_, let systemImage, _): systemImage
        }
    }

    /// Set by selecting something in the sidebar (a feature or a pull request), so selecting
    /// something else there ends it. Ticket highlights come from the toolbar and stay.
    var followsSidebar: Bool {
        switch self {
        case .feature, .commits: true
        case .tickets: false
        }
    }

    var featureID: String? {
        if case .feature(let group) = self { return group.id }
        return nil
    }

    var featureTicket: String? {
        if case .feature(let group) = self { return group.ticket }
        return nil
    }

    /// Matching rows, top to bottom.
    func rows(in layout: GraphLayout) -> [Int32] {
        switch self {
        case .feature(let group):
            return group.commits
                .compactMap { layout.graph.indexByID[$0.id] }
                .map { layout.rowOfCommit[Int($0)] }
                .filter { $0 >= 0 }
                .sorted()
        case .commits(_, _, let ids):
            return ids
                .compactMap { layout.graph.indexByID[$0] }
                .map { layout.rowOfCommit[Int($0)] }
                .filter { $0 >= 0 }
                .sorted()
        case .tickets(_, let keys):
            guard !keys.isEmpty else { return [] }
            let graph = layout.graph
            var rows: [Int32] = []
            for row in 0..<layout.rowCount {
                let commit = layout.rows[row]
                if let key = graph.ticketKeys(in: graph.subjects[Int(commit)]).first, keys.contains(key) {
                    rows.append(Int32(row))
                }
            }
            return rows
        }
    }
}

/// Ticket statuses the Highlight menu can pick.
enum TicketFilter: CaseIterable {
    case notDone, inProgress, toDo

    var title: String {
        switch self {
        case .notDone: "Tickets Not Done"
        case .inProgress: "Tickets In Progress"
        case .toDo: "Tickets To Do"
        }
    }

    func matches(_ issue: JiraIssue) -> Bool {
        switch self {
        case .notDone: issue.category != .done
        case .inProgress: issue.category == .inProgress
        case .toDo: issue.category == .toDo
        }
    }
}
