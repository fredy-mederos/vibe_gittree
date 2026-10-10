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

    /// Tickets in the latest commits grouped by epic, when the repository has Jira.
    private(set) var epics: EpicReport?
    /// "Reading 120 tickets from Jira…" while the Epics section waits for answers.
    private(set) var epicProgress: String?
    /// How many of the latest commits the Epics section covers.
    var epicCommitLimit = UserDefaults.standard.object(forKey: AppSettings.epicCommitLimitKey) as? Int ?? 500 {
        didSet {
            guard epicCommitLimit != oldValue else { return }
            UserDefaults.standard.set(epicCommitLimit, forKey: AppSettings.epicCommitLimitKey)
            loadJiraOverview()
        }
    }
    /// The unreleased fix versions of the repository's Jira projects.
    private(set) var releases: ReleaseReport?
    /// The tickets of fix versions opened in the sidebar, by version id.
    private(set) var releaseTickets: [String: [TicketSummary]] = [:]
    private(set) var loadingReleases: Set<String> = []
    /// Why a fix version's tickets couldn't be listed, by version id.
    private(set) var releaseProblems: [String: String] = [:]
    @ObservationIgnored private var ticketIndex: (graph: CommitGraph, index: TicketIndex)?
    @ObservationIgnored private var recentTickets: [RecentTicket] = []
    /// What the Jira sections were last loaded for, so showing the repository again asks nothing new.
    @ObservationIgnored private var jiraLoadedFor: (layout: GraphLayout, limit: Int, connection: JiraConnection)?
    @ObservationIgnored private var jiraTask: Task<Void, Never>?
    @ObservationIgnored private var jiraRebuild: Task<Void, Never>?
    @ObservationIgnored private var openedReleases: Set<String> = []

    /// Commits highlighted by a feature or a ticket filter (a search takes precedence).
    private(set) var highlight: CommitHighlight?
    /// "Loading tickets…" while a ticket filter waits for Jira.
    private(set) var highlightProgress: String?
    /// A problem with the highlight: Jira couldn't list a fix version, or statuses still missing.
    private(set) var highlightNote: String?
    /// The highlight shows what's known and is waiting for Jira's full list (an epic's tickets).
    private(set) var highlightRefining = false
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    /// Loading a ticket or fix version highlight; a newer highlight, a search or Clear cancels it.
    @ObservationIgnored private var highlightLoadTask: Task<Void, Never>?
    /// Increments with every new highlight, so a late answer can't change a newer one.
    @ObservationIgnored private var highlightGeneration = 0
    /// For a highlight that takes in the tickets below the ones picked (an epic's stories and
    /// tasks, their sub-tasks): the tickets picked, so it grows as Jira tells more.
    @ObservationIgnored private var highlightBase: Set<String>?

    @ObservationIgnored private var selectedID: ObjectID?
    @ObservationIgnored private var appliedGeneration = -1
    @ObservationIgnored private var hasInitialSelection = false
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refTreeCache: (graph: CommitGraph, filter: String, tree: RefTree)?

    init(model: RepositoryModel) {
        self.model = model
        observeModel()
        observeJira()
        syncWithModel()
    }

    /// The history the current layout was built from. Commit indexes in this model refer to it.
    var commitGraph: CommitGraph? { layout?.graph }

    /// The Jira this repository's tickets live in.
    var jira: JiraConnection? { JiraStore.shared.connection(for: model.repository) }

    var activeQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 2 ? query : nil
    }

    /// Text to highlight in matching rows: the search, or the highlighted feature's or ticket's key.
    var highlightText: String? {
        activeQuery ?? highlight?.markedText
    }

    // MARK: Layout

    private func observeModel() {
        withObservationTracking {
            _ = model.generation
            _ = model.repository
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncWithModel()
                // Another Jira profile (or none) changes the Epics and Releases sections.
                self?.loadJiraOverview()
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
        loadJiraOverview()
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

    // MARK: Epics and releases

    /// Fills the Epics and Releases sections from what Jira has said so far, then asks it, gently,
    /// about what's missing: recent tickets it hasn't answered about (and the stories and tasks
    /// above sub-tasks), and the projects' fix versions every half hour. Runs when the history is
    /// laid out and when the repository is shown again; when nothing changed it asks nothing.
    func loadJiraOverview() {
        guard let layout, let jira, layout.graph.ticketRegex != nil else {
            jiraTask?.cancel()
            jiraLoadedFor = nil
            ticketIndex = nil
            recentTickets = []
            if epics != nil { epics = nil }
            if releases != nil { releases = nil }
            if !releaseTickets.isEmpty { releaseTickets = [:] }
            if epicProgress != nil { epicProgress = nil }
            return
        }
        let limit = epicCommitLimit
        if let loaded = jiraLoadedFor, loaded.layout === layout, loaded.limit == limit, loaded.connection == jira {
            guard WindowState.isShowing(model.id) else { return }
            refreshVersions(jira)
            // Shown again with tickets Jira hasn't answered about (it was unreachable, say): ask for those.
            if (epics?.pending ?? 0) > 0, epicProgress == nil {
                let keys = recentTickets.map(\.key)
                jiraTask = Task { [weak self] in await self?.readEpics(of: keys, connection: jira) }
            }
            return
        }
        jiraLoadedFor = (layout, limit, jira)
        jiraTask?.cancel()
        epicProgress = nil
        let graph = layout.graph
        jiraTask = Task { [weak self] in
            guard let self else { return }
            let tickets = await Task.detached(priority: .userInitiated) { RecentTicket.find(in: layout, limit: limit) }.value
            let index = await self.model.ticketIndex(for: graph)
            guard !Task.isCancelled else { return }
            self.ticketIndex = (graph, index)
            self.recentTickets = tickets
            self.rebuildJiraReports()
            // Only repositories a window shows ask Jira for anything; the rest wait until they're shown.
            guard WindowState.isShowing(self.model.id) else {
                self.jiraLoadedFor = nil
                return
            }
            self.refreshVersions(jira)
            await self.readEpics(of: tickets.map(\.key), connection: jira)
        }
    }

    /// The Epics section's Refresh: asks Jira again about every recent ticket and the fix versions.
    func refreshJiraOverview() {
        guard let jira, let graph = commitGraph else { return }
        let keys = recentTickets.map(\.key)
        jiraTask?.cancel()
        JiraStore.shared.refreshVersions(projects: Self.projects(of: graph), connection: jira, force: true)
        jiraTask = Task { [weak self] in
            guard let self else { return }
            self.epicProgress = "Reading \(counted(keys.count, "ticket", "tickets")) from Jira…"
            await JiraStore.shared.refresh(keys, connection: jira)
            guard !Task.isCancelled else { return }
            await self.readEpics(of: keys, connection: jira)
        }
    }

    /// Ticket keys like PROJ-123 name the Jira projects whose fix versions are listed (at most three).
    static func projects(of graph: CommitGraph) -> [String] {
        Array(graph.ticketPrefixes.prefix(3))
    }

    private func refreshVersions(_ jira: JiraConnection) {
        guard let graph = commitGraph else { return }
        JiraStore.shared.refreshVersions(projects: Self.projects(of: graph), connection: jira)
    }

    /// Asks Jira about recent tickets it hasn't answered about, then about the stories and tasks
    /// above sub-tasks, so every ticket's epic is known.
    private func readEpics(of keys: [String], connection: JiraConnection) async {
        let store = JiraStore.shared
        let unread = keys.filter { store.issue($0, connection: connection)?.knowsParent != true && !store.isMissing($0, connection: connection) }
        if !unread.isEmpty {
            epicProgress = "Reading \(counted(unread.count, "ticket", "tickets")) from Jira…"
            await store.ensureKnown(unread, connection: connection)
            guard !Task.isCancelled else { return }
        }
        let parents = store.parentsToRead(of: keys, connection: connection)
        if !parents.isEmpty {
            epicProgress = "Reading \(counted(parents.count, "parent ticket", "parent tickets")) from Jira…"
            await store.ensureKnown(parents, connection: connection)
            guard !Task.isCancelled else { return }
        }
        epicProgress = nil
        rebuildJiraReports()
    }

    /// Redraws the Epics and Releases sections when Jira answers anything (never asks it anything).
    private func observeJira() {
        withObservationTracking {
            _ = JiraStore.shared.version
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleJiraRebuild()
                self?.observeJira()
            }
        }
    }

    private func scheduleJiraRebuild() {
        guard ticketIndex != nil else { return }
        jiraRebuild?.cancel()
        jiraRebuild = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuildJiraReports()
        }
    }

    private func rebuildJiraReports() {
        guard let jira, let ticketIndex else { return }
        let (graph, index) = ticketIndex
        epics = EpicReport.build(recentTickets, commitLimit: jiraLoadedFor?.limit ?? epicCommitLimit, connection: jira)
        releases = ReleaseReport.build(projects: Self.projects(of: graph), index: index, connection: jira)
        if !openedReleases.isEmpty {
            let children = index.children(connection: jira)
            var lists: [String: [TicketSummary]] = [:]
            for id in openedReleases {
                if let keys = JiraStore.shared.cachedTickets(inFixVersionID: id, connection: jira) {
                    lists[id] = TicketSummary.list(keys, index: index, children: children, graph: graph, connection: jira)
                }
            }
            releaseTickets = lists
        }
        widenHighlight()
    }

    /// Jira told more: a highlight that takes in the tickets below the picked ones may cover more
    /// commits now (sub-tasks whose stories weren't known when it was picked, say).
    private func widenHighlight() {
        guard let base = highlightBase, case .tickets(let title, let keys, let image, let follows) = highlight else { return }
        let widened = withChildren(base)
        guard widened != keys else { return }
        highlight = .tickets(title: title, keys: widened, systemImage: image, followsSidebar: follows)
        // Nothing matched before, so nothing was selected: go to the first match now.
        applyHighlight(jump: matchRows.isEmpty)
    }

    /// Asks Jira for a fix version's tickets (cached for ten minutes) so the sidebar can list them.
    func loadRelease(_ id: String) {
        guard let jira else { return }
        if openedReleases.insert(id).inserted { rebuildJiraReports() }
        guard !loadingReleases.contains(id) else { return }
        loadingReleases.insert(id)
        releaseProblems[id] = nil
        Task { [weak self] in
            do {
                _ = try await JiraStore.shared.tickets(inFixVersion: id, isID: true, connection: jira)
            } catch {
                self?.releaseProblems[id] = error.localizedDescription
            }
            self?.loadingReleases.remove(id)
            self?.rebuildJiraReports()
        }
    }

    /// Highlights the commits of an epic: right away those of the tickets the Epics section lists
    /// under it, then those of every ticket Jira has in the epic (sub-tasks included), wherever
    /// they are in the history. An empty id stands for the tickets without an epic.
    func showEpic(_ id: String) {
        let group = epics?.groups.first { $0.id == id }
        guard !id.isEmpty else {
            guard let group else { return clearHighlight() }
            setHighlight(.tickets(title: "Tickets without an epic", keys: Set(group.tickets.map(\.key)), systemImage: "tray",
                                  followsSidebar: true))
            return
        }
        highlightEpic(id, title: group?.epic.map { "\($0.key) \($0.summary)" } ?? id, known: Set(group?.tickets.map(\.key) ?? []))
    }

    /// Highlights an epic's commits, starting with the tickets already known to be in it.
    func highlightEpic(_ key: String, title: String, known: Set<String> = []) {
        guard let jira else { return }
        let base = known.union([key])
        setHighlight(.tickets(title: title, keys: withChildren(base), systemImage: "bolt.fill", followsSidebar: true), base: base)
        refineHighlight(base: base, what: "the epic's tickets") {
            try await JiraStore.shared.tickets(inEpic: key, connection: jira).map(\.key)
        }
    }

    /// Highlights the commits of a fix version's tickets and lists the tickets in the sidebar.
    func showRelease(_ id: String) {
        guard let version = releases?.version(id: id) else { return clearHighlight() }
        loadRelease(id)
        highlightFixVersion(version.name, id: id, fromSidebar: true)
    }

    /// Highlights a ticket's commits and its sub-tasks'.
    func showTicket(_ key: String) {
        let summary = jira.flatMap { JiraStore.shared.issue(key, connection: $0)?.summary }
        setHighlight(.tickets(title: [key, summary].compactMap { $0 }.joined(separator: " "), keys: withChildren([key]),
                              systemImage: "ticket", followsSidebar: true), base: [key])
    }

    /// These tickets and the ones below them mentioned in this history (an epic's stories and
    /// tasks, their sub-tasks), as far as Jira has told.
    private func withChildren(_ keys: Set<String>) -> Set<String> {
        guard let jira, let index = ticketIndex?.index else { return keys }
        let children = index.children(connection: jira)
        var result = keys
        var frontier = Array(keys)
        while let key = frontier.popLast() {
            for child in children[key] ?? [] where result.insert(child).inserted {
                frontier.append(child)
            }
        }
        return result
    }

    // MARK: Highlights

    /// Highlights the commits of tickets with a status, among the latest 500 commits of the scope.
    /// Missing statuses are fetched through the usual Jira queue first.
    func highlightTickets(_ filter: TicketFilter) {
        guard let layout, let jira else { return }
        let graph = layout.graph
        var keys: [String] = []
        var seen: Set<String> = []
        var looked = 0
        for row in 0..<layout.rowCount where looked < 500 {
            let commit = layout.rows[row]
            guard !graph.isMerge(commit) else { continue }
            looked += 1
            if let key = graph.ticketKey(in: graph.subjects[Int(commit)]), seen.insert(key).inserted {
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

    /// Highlights the commits of every ticket in a fix version and of their sub-tasks, as listed
    /// by Jira: by id for the versions GitTree listed, by name for one typed in.
    func highlightFixVersion(_ name: String, id: String? = nil, fromSidebar: Bool = false) {
        guard let jira else { return }
        let title = "Fix version \(name)"
        if let id, let keys = JiraStore.shared.cachedTickets(inFixVersionID: id, connection: jira) {
            // What Jira said last time shows right away; a fresh list follows when it's due.
            setHighlight(.tickets(title: title, keys: withChildren(Set(keys)), systemImage: "shippingbox", followsSidebar: fromSidebar),
                         base: Set(keys))
            refineHighlight(base: [], what: "the fix version's tickets") {
                try await JiraStore.shared.tickets(inFixVersion: id, isID: true, connection: jira).map(\.key)
            }
            return
        }
        cancelHighlightLoad()
        highlightProgress = "Loading fix version \(name)…"
        highlightLoadTask = Task { [weak self] in
            do {
                let issues = try await JiraStore.shared.tickets(inFixVersion: id ?? name, isID: id != nil, connection: jira)
                guard let self, !Task.isCancelled else { return }
                let keys = Set(issues.map(\.key))
                self.setHighlight(.tickets(title: title, keys: self.withChildren(keys), systemImage: "shippingbox", followsSidebar: fromSidebar),
                                  base: keys)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.cancelHighlightLoad()
                self.highlightNote = "Couldn't load fix version \(name): \(error.localizedDescription)"
            }
        }
    }

    /// Highlights a set of commits (one side of a branch comparison, say) without moving the selection.
    func highlightCommits(_ ids: Set<ObjectID>, title: String, systemImage: String) {
        setHighlight(.commits(title: title, systemImage: systemImage, ids: ids), jump: false)
    }

    /// Clears the highlight, a highlight still loading, and its note.
    func clearHighlight() {
        cancelHighlightLoad()
        guard highlight != nil else { return }
        highlight = nil
        highlightBase = nil
        highlightGeneration += 1
        scheduleSearch(jump: false)
    }

    /// Selecting something else in the sidebar ends a highlight that came from there (ticket
    /// status and fix version highlights from the toolbar stay).
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
        highlightRefining = false
    }

    /// `base`: for a ticket highlight that takes in the tickets below the ones picked, the tickets picked.
    private func setHighlight(_ newHighlight: CommitHighlight, jump: Bool = true, base: Set<String>? = nil) {
        cancelHighlightLoad()
        highlight = newHighlight
        highlightBase = base
        highlightGeneration += 1
        if !searchText.isEmpty { searchText = "" }
        applyHighlight(jump: jump)
    }

    /// Widens the current ticket highlight to what Jira lists (an epic's or a fix version's
    /// tickets) when it answers, without moving the selection; a newer highlight cancels it.
    private func refineHighlight(base: Set<String>, what: String, _ load: @escaping @MainActor () async throws -> [String]) {
        let generation = highlightGeneration
        highlightRefining = true
        highlightLoadTask = Task { [weak self] in
            let loaded: [String]
            do {
                loaded = try await load()
            } catch {
                guard let self, !Task.isCancelled, self.highlightGeneration == generation else { return }
                self.highlightRefining = false
                self.highlightNote = "Couldn't ask Jira for \(what)"
                return
            }
            guard let self, !Task.isCancelled, self.highlightGeneration == generation else { return }
            self.highlightRefining = false
            guard case .tickets(let title, let keys, let image, let follows) = self.highlight else { return }
            self.highlightBase = base.union(loaded)
            let refined = self.withChildren(base.union(loaded))
            guard refined != keys else { return }
            self.highlight = .tickets(title: title, keys: refined, systemImage: image, followsSidebar: follows)
            // Nothing matched before, so nothing was selected: go to the first match now.
            self.applyHighlight(jump: self.matchRows.isEmpty)
        }
    }

    private func applyHighlight(jump: Bool) {
        guard let highlight, let layout else { return }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { highlight.rows(in: layout) }.value
            guard let self, !Task.isCancelled, self.layout === layout else { return }
            self.matchRows = rows
            self.matchSet = Set(rows)
            if jump, let first = rows.first {
                self.currentMatch = 0
                self.select(layout.rows[Int(first)])
            } else {
                // The selection stays; it counts as the current match when it's one of them.
                let selectedRow = self.selectedCommit.map { layout.rowOfCommit[Int($0)] }
                self.currentMatch = selectedRow.flatMap { rows.firstIndex(of: $0) }
            }
            self.searchVersion += 1
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
    /// Commits that mention these tickets: ticket statuses or a fix version picked in the toolbar,
    /// or an epic, fix version or ticket picked in the sidebar.
    case tickets(title: String, keys: Set<String>, systemImage: String = "ticket", followsSidebar: Bool = false)
    /// A pull request's commits, or a whole stack's.
    case commits(title: String, systemImage: String, ids: Set<ObjectID>)

    var title: String {
        switch self {
        case .feature(let group): group.name
        case .tickets(let title, _, _, _): title
        case .commits(let title, _, _): title
        }
    }

    var systemImage: String {
        switch self {
        case .feature: "sparkles"
        case .tickets(_, _, let systemImage, _): systemImage
        case .commits(_, let systemImage, _): systemImage
        }
    }

    /// Set by selecting something in the sidebar (a feature, an epic, a pull request…), so
    /// selecting something else there ends it. Highlights from the toolbar stay.
    var followsSidebar: Bool {
        switch self {
        case .feature, .commits: true
        case .tickets(_, _, _, let followsSidebar): followsSidebar
        }
    }

    var featureID: String? {
        if case .feature(let group) = self { return group.id }
        return nil
    }

    /// The ticket key to mark in matching subjects: a feature's ticket, or the one ticket highlighted.
    var markedText: String? {
        switch self {
        case .feature(let group): group.ticket
        case .tickets(_, let keys, _, _): keys.count == 1 ? keys.first : nil
        case .commits: nil
        }
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
        case .tickets(_, let keys, _, _):
            guard !keys.isEmpty else { return [] }
            let graph = layout.graph
            var rows: [Int32] = []
            for row in 0..<layout.rowCount {
                let commit = layout.rows[row]
                if let key = graph.ticketKey(in: graph.subjects[Int(commit)]), keys.contains(key) {
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
