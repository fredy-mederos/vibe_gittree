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
            if !searchText.isEmpty {
                cancelHighlightLoad()
                uncoverHistory()
            }
            scheduleSearch(jump: true)
        }
    }

    private(set) var layout: GraphLayout?
    /// Increments when `layout` is replaced, so the table knows to reload.
    private(set) var layoutVersion = 0
    private(set) var isLayingOut = false
    private(set) var selectedCommit: Int32?
    /// The row for uncommitted changes is selected instead of a commit.
    private(set) var selectsWorkingTree = false
    /// A stash picked in the sidebar, which the details show instead of a commit.
    private(set) var selectedStash: ObjectID?
    /// The commit message being written for the uncommitted changes, kept while looking elsewhere.
    var commitSummary = ""
    var commitDescription = ""
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
    /// Fix versions whose tickets are being asked for, first or again.
    private(set) var loadingReleases: Set<String> = []
    /// The Releases section's Refresh is under way.
    private(set) var isRefreshingReleases = false
    /// Why a fix version's tickets couldn't be listed, by version id.
    private(set) var releaseProblems: [String: String] = [:]
    @ObservationIgnored private var ticketIndex: (graph: CommitGraph, index: TicketIndex)?
    @ObservationIgnored private var recentTickets: [RecentTicket] = []
    /// What the Jira sections were last loaded for, so showing the repository again asks nothing new.
    @ObservationIgnored private var jiraLoadedFor: (layout: GraphLayout, limit: Int, connection: JiraConnection)?
    @ObservationIgnored private var jiraTask: Task<Void, Never>?
    @ObservationIgnored private var jiraRebuild: Task<Void, Never>?
    @ObservationIgnored private var definitionTask: Task<Void, Never>?
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
    /// The fix version whose tickets are highlighted, by id, so refreshing it updates the highlight.
    @ObservationIgnored private var highlightedRelease: String?

    @ObservationIgnored private var selectedID: ObjectID?
    /// Until then the selection follows HEAD: the selected uncommitted changes were committed, and
    /// the history may need a reload or two to show the new commit.
    @ObservationIgnored private var followsHeadUntil: Date?
    @ObservationIgnored private var appliedGeneration = -1
    @ObservationIgnored private var appliedWorkingTree = false
    @ObservationIgnored private var appliedMainBranch: String?
    @ObservationIgnored private var hasInitialSelection = false
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refTreeCache: (graph: CommitGraph, filter: String, tree: RefTree)?

    init(model: RepositoryModel) {
        self.model = model
        observeModel()
        observeJira()
        observeDefinitionOfDone()
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
            _ = model.hasUncommittedChanges
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncWithModel()
                // Another Jira profile (or none) changes the Epics and Releases sections, and
                // another fix version pattern what Releases lists as the repository's.
                self?.loadJiraOverview()
                self?.rebuildJiraReports()
                self?.observeModel()
            }
        }
    }

    private func syncWithModel() {
        guard model.graph != nil, model.generation != appliedGeneration || model.hasUncommittedChanges != appliedWorkingTree
                || model.mainBranch != appliedMainBranch else { return }
        appliedGeneration = model.generation
        appliedWorkingTree = model.hasUncommittedChanges
        appliedMainBranch = model.mainBranch
        rebuildLayout(reveal: false)
    }

    private func rebuildLayout(reveal: Bool) {
        guard let graph = model.graph else { return }
        layoutTask?.cancel()
        if case .ref(let name) = scope, !graph.refs.contains(where: { $0.fullName == name }) {
            scope = .all  // the branch is gone; this rebuilds again
            return
        }
        let workingTree = model.hasUncommittedChanges
        let mainBranch = model.mainBranch
        if scope == .all, let all = model.allLayout, all.graph === graph, all.includesWorkingTree == workingTree,
           all.mainBranch == mainBranch {
            isLayingOut = false
            apply(all, reveal: reveal)
            return
        }
        isLayingOut = true
        let scope = self.scope
        layoutTask = Task { [weak self] in
            let layout = await Task.detached(priority: .userInitiated) {
                LaneLayoutEngine.layout(graph: graph, scope: scope, workingTree: workingTree, mainBranch: mainBranch)
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
        if selectsWorkingTree {
            // Committed or stashed away: the commit they became (HEAD) takes their place.
            if layout.workingRow == nil, layout.includesWorkingTree == false {
                selectsWorkingTree = false
                followsHeadUntil = Date().addingTimeInterval(5)
                selectHead(in: layout)
            }
        } else if let until = followsHeadUntil, until > Date() {
            selectHead(in: layout)
            selectedCommit = selectedID.flatMap { graph.indexByID[$0] }
        } else if selectedStash != nil {
            selectedCommit = nil
        } else if let id = selectedID, let index = graph.indexByID[id] {
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

    /// Selects HEAD's commit, by its id: indexes of the same commit differ from one history to the next.
    private func selectHead(in layout: GraphLayout) {
        let head = layout.graph.headCommit
        guard head >= 0, layout.rowOfCommit[Int(head)] >= 0 else { return }
        let id = layout.graph.ids[Int(head)]
        selectedCommit = head
        guard id != selectedID else { return }
        selectedID = id
        revealToken += 1
    }

    /// The user clicked or arrowed to a row; it's already visible.
    func userSelected(_ commit: Int32?) {
        selectedCommit = commit
        selectedID = commit.flatMap { commit in commitGraph.map { $0.ids[Int(commit)] } }
        selectsWorkingTree = false
        selectedStash = nil
        followsHeadUntil = nil
        followSelection()
    }

    /// The user clicked or arrowed to the row for uncommitted changes.
    func userSelectedWorkingTree() {
        selectedCommit = nil
        selectedID = nil
        selectsWorkingTree = true
        selectedStash = nil
        followsHeadUntil = nil
        followSelection()
    }

    /// Selects the row for uncommitted changes and scrolls up to it.
    func selectWorkingTree() {
        userSelectedWorkingTree()
        revealToken += 1
    }

    /// Shows a stash in the details instead of a commit (picked in the sidebar).
    func showStash(_ id: ObjectID) {
        selectedCommit = nil
        selectedID = nil
        selectsWorkingTree = false
        selectedStash = id
        followsHeadUntil = nil
    }

    /// Selects a commit and scrolls to it, widening the scope if it's hidden.
    func select(_ commit: Int32, reveal: Bool = true) {
        guard let graph = commitGraph, Int(commit) < graph.count else { return }
        selectedCommit = commit
        selectedID = graph.ids[Int(commit)]
        selectsWorkingTree = false
        selectedStash = nil
        followsHeadUntil = nil
        followSelection()
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

    /// The commit a worktree has checked out.
    func reveal(worktreeAt path: String) {
        guard let worktree = commitGraph?.worktree(at: path), worktree.commit >= 0 else { return }
        select(worktree.commit)
    }

    func showOnly(refNamed fullName: String) {
        scope = .ref(fullName)
    }

    // MARK: Pages over the history

    /// What the window shows over the history, bottom to top: a comparison or the activity
    /// calendar, then changes opened from the details or a comparison. Back takes off the top one.
    private(set) var pages: [GraphPage] = []
    /// Whether the history is on screen, not covered by a page (the window says, as its width changes).
    @ObservationIgnored var historyIsVisible = true

    /// A file's changes, or every file's, over what's shown; changes already on top make way.
    func showChanges(_ target: DiffTarget) {
        if case .changes? = pages.last { pages.removeLast() }
        pages.append(.changes(DiffSession(target: target)))
    }

    /// A comparison over the history, instead of the pages shown (one already there takes the
    /// new branches, keeping its tab).
    func showComparison(_ target: CompareTarget) {
        if case .comparison(let page)? = pages.first {
            page.target = target
            pages = [pages[0]]
        } else {
            pages = [.comparison(ComparisonPage(target: target))]
        }
    }

    /// The activity calendar over the history, instead of the pages shown (one already there
    /// keeps its period, branches and author).
    func showActivity() {
        if case .activity? = pages.first {
            if pages.count > 1 { pages = [pages[0]] }
        } else {
            pages = [.activity(UUID())]
        }
    }

    func goBack() {
        _ = pages.popLast()
    }

    func showHistory() {
        if !pages.isEmpty { pages = [] }
    }

    /// The history back on screen when a page covers it: for what's about to happen there, a search say.
    func uncoverHistory() {
        if !historyIsVisible { showHistory() }
    }

    /// Changes on top follow the selection (in the history beside them, say): another commit, or the
    /// uncommitted changes, shows its own, one file at a time or all of them as before. Nothing
    /// selected takes them off.
    private func followSelection() {
        guard case .changes(let shown)? = pages.last else { return }
        let allFiles: Bool? = shown.showsAllFiles ? true : nil
        let target: DiffTarget
        if selectsWorkingTree {
            guard shown.target.uncommitted == nil else { return }
            target = DiffTarget(repositoryID: model.id, commit: "", path: "", uncommitted: .unstaged, allFiles: allFiles,
                                title: String(localized: "Uncommitted Changes"))
        } else if let commit = selectedCommit, let graph = commitGraph, Int(commit) < graph.count {
            let id = graph.ids[Int(commit)]
            guard id.hex != shown.target.commit || shown.target.base != nil else { return }
            target = DiffTarget(repositoryID: model.id, commit: id.hex, path: "", allFiles: allFiles,
                                title: "\(id.short) \(graph.subjects[Int(commit)])")
        } else {
            pages.removeLast()
            return
        }
        pages[pages.count - 1] = .changes(DiffSession(target: target))
    }

    // MARK: Search

    func nextMatch() {
        uncoverHistory()
        stepMatch(by: 1)
    }

    func previousMatch() {
        uncoverHistory()
        stepMatch(by: -1)
    }

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
        featureProgress = String(localized: "Grouping \(commits.count) commits…")
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
    /// above sub-tasks), and the projects' fix versions every hour. Runs when the history is
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
            Task { [weak self] in
                await self?.refreshReleaseProgress(jira, force: false)
                await self?.refreshEpicProgress(jira, force: false)
            }
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
            await self.readEpics(of: tickets.map(\.key), connection: jira)
            // After the tickets: the projects to ask about are the ones Jira answered tickets for.
            guard !Task.isCancelled else { return }
            await self.refreshReleaseProgress(jira, force: false)
            guard !Task.isCancelled else { return }
            await self.refreshEpicProgress(jira, force: false)
        }
    }

    /// The Epics section's Refresh: asks Jira again about every recent ticket and the fix versions.
    func refreshJiraOverview() {
        guard let jira else { return }
        let keys = recentTickets.map(\.key)
        jiraTask?.cancel()
        JiraStore.shared.refreshVersions(projects: jiraProjects(jira), connection: jira, force: true)
        jiraTask = Task { [weak self] in
            guard let self else { return }
            self.epicProgress = String(localized: "Reading \(keys.count) tickets from Jira…")
            await JiraStore.shared.refresh(keys, connection: jira)
            guard !Task.isCancelled else { return }
            await self.readEpics(of: keys, connection: jira)
            guard !Task.isCancelled else { return }
            self.epicProgress = String(localized: "Reading the epics' stories and tasks…")
            await self.refreshEpicProgress(jira, force: true)
            self.epicProgress = nil
        }
    }

    /// The Jira projects whose fix versions are listed, named by the repository's ticket keys
    /// (PROJ-123 → PROJ), at most three: only prefixes Jira has answered tickets for, so ones that
    /// merely look like project keys are never asked about.
    private func jiraProjects(_ jira: JiraConnection) -> [String] {
        guard let graph = commitGraph else { return [] }
        var known: Set<String> = []
        for ticket in recentTickets where JiraStore.shared.issue(ticket.key, connection: jira) != nil {
            if let dash = ticket.key.lastIndex(of: "-") { known.insert(String(ticket.key[..<dash])) }
        }
        return Array(graph.ticketPrefixes.filter(known.contains).prefix(3))
    }

    /// The fix versions (every hour), then the tickets of those whose project has a Definition of
    /// Done, which their progress counts (in one query, at most every hour); `force` asks anyway.
    /// Returns, for each fix version whose tickets were asked for, the ones it had before.
    @discardableResult
    private func refreshReleaseProgress(_ jira: JiraConnection, force: Bool) async -> [String: [String]] {
        let store = JiraStore.shared
        let projects = jiraProjects(jira)
        guard !projects.isEmpty else { return [:] }
        await store.refreshVersions(projects: projects, connection: jira, force: force).value
        let counted = store.unreleasedVersions(projects: projects, connection: jira)
            .filter { store.hasDefinitionOfDone(project: $0.project, connection: jira) }
        return counted.isEmpty ? [:] : await store.refreshTickets(of: counted, connection: jira, force: force)
    }

    /// The listed epics' stories and tasks, which their progress counts (in one query, at most
    /// every hour); `force` asks anyway.
    private func refreshEpicProgress(_ jira: JiraConnection, force: Bool) async {
        let keys = epics?.groups.compactMap { $0.epic?.key } ?? []
        if !keys.isEmpty { await JiraStore.shared.refreshChildren(ofEpics: keys, connection: jira, force: force) }
    }

    /// Asks Jira about recent tickets it hasn't answered about, then about the stories and tasks
    /// above sub-tasks, so every ticket's epic is known.
    private func readEpics(of keys: [String], connection: JiraConnection) async {
        let store = JiraStore.shared
        let unread = keys.filter { store.issue($0, connection: connection)?.knowsParent != true && !store.isMissing($0, connection: connection) }
        if !unread.isEmpty {
            epicProgress = String(localized: "Reading \(unread.count) tickets from Jira…")
            await store.ensureKnown(unread, connection: connection)
            guard !Task.isCancelled else { return }
        }
        let parents = store.parentsToRead(of: keys, connection: connection)
        if !parents.isEmpty {
            epicProgress = String(localized: "Reading \(parents.count) parent tickets from Jira…")
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

    /// A project got a Definition of Done (or another one) in Settings: once the typing stops, the
    /// tickets of its fix versions that aren't listed yet are asked for, so their progress counts it.
    private func observeDefinitionOfDone() {
        withObservationTracking {
            _ = JiraStore.shared.definitionVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.definitionOfDoneChanged()
                self?.observeDefinitionOfDone()
            }
        }
    }

    private func definitionOfDoneChanged() {
        guard let jira, ticketIndex != nil, WindowState.isShowing(model.id) else { return }
        definitionTask?.cancel()
        definitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refreshReleaseProgress(jira, force: false)
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
        releases = ReleaseReport.build(projects: jiraProjects(jira), index: index, pattern: model.repository.fixVersionRegex, connection: jira)
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

    /// The Releases section's Refresh: asks Jira again for the projects' fix versions (dates and
    /// progress), then for the tickets of the fix versions open in the sidebar (`open`) and the
    /// highlighted one. Other fix versions' tickets are asked for again when they're next opened.
    func refreshReleases(open: Set<String>) {
        guard let jira, !isRefreshingReleases else { return }
        let refreshing = open.union(highlightedRelease.map { [$0] } ?? [])
        JiraStore.shared.markStale(fixVersionIDs: openedReleases.subtracting(refreshing), connection: jira)
        isRefreshingReleases = true
        Task { [weak self] in
            // Fix versions whose project has a Definition of Done come all together, the open ones too.
            guard let before = await self?.refreshReleaseProgress(jira, force: true) else { return }
            await self?.ticketsMoved(before, connection: jira)
            for id in refreshing where before[id] == nil {
                // One being loaded or refreshed on its own already gets Jira's latest answer.
                guard let self, !self.loadingReleases.contains(id) else { continue }
                await self.reloadRelease(id, connection: jira)
            }
            self?.isRefreshingReleases = false
        }
    }

    /// One fix version's Refresh: its project's fix versions (its date and progress) and its tickets.
    func refreshRelease(_ id: String) {
        guard let jira, let version = releases?.version(id: id), !loadingReleases.contains(id) else { return }
        loadingReleases.insert(id)
        Task { [weak self] in
            await JiraStore.shared.refreshVersions(projects: [version.project], connection: jira, force: true).value
            await self?.reloadRelease(id, connection: jira)
        }
    }

    /// Asks Jira again for a fix version's tickets, showing the last answer meanwhile.
    private func reloadRelease(_ id: String, connection jira: JiraConnection) async {
        let store = JiraStore.shared
        let before = store.cachedTickets(inFixVersionID: id, connection: jira) ?? []
        loadingReleases.insert(id)
        releaseProblems[id] = nil
        openedReleases.insert(id)
        do {
            _ = try await store.tickets(inFixVersion: id, isID: true, force: true, connection: jira)
            await ticketsMoved([id: before], connection: jira)
        } catch {
            releaseProblems[id] = error.localizedDescription
        }
        loadingReleases.remove(id)
        rebuildJiraReports()
    }

    /// Fix versions' tickets came again (with the ones they had before): the tickets that left them
    /// are read again, so the fix versions shown next to their commits are current too, and a
    /// highlighted fix version follows its tickets.
    private func ticketsMoved(_ before: [String: [String]], connection jira: JiraConnection) async {
        let store = JiraStore.shared
        var left: Set<String> = []
        for (id, keys) in before {
            let now = store.cachedTickets(inFixVersionID: id, connection: jira) ?? []
            left.formUnion(Set(keys).subtracting(now))
            releaseTicketsChanged(id, keys: now)
        }
        if !left.isEmpty { await store.refresh(Array(left), connection: jira, timeout: 30) }
        rebuildJiraReports()
    }

    /// A fix version's tickets came again: when they're the ones highlighted, the highlight follows
    /// them without moving the selection.
    private func releaseTicketsChanged(_ id: String, keys: [String]) {
        guard highlightedRelease == id, case .tickets(let title, let old, let image, let follows) = highlight else { return }
        highlightBase = Set(keys)
        let refreshed = withChildren(Set(keys))
        guard refreshed != old else { return }
        highlight = .tickets(title: title, keys: refreshed, systemImage: image, followsSidebar: follows)
        // Nothing matched before, so nothing was selected: go to the first match now.
        applyHighlight(jump: matchRows.isEmpty)
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
        refineHighlight(base: base, failureNote: String(localized: "Couldn't ask Jira for the epic's tickets")) {
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
        highlightProgress = String(localized: "Loading \(keys.count) tickets…")
        highlightLoadTask = Task { [weak self] in
            await JiraStore.shared.ensure(keys, connection: jira)
            guard let self, !Task.isCancelled else { return }
            let matching = Set(keys.filter { key in
                guard let issue = JiraStore.shared.issue(key, connection: jira) else { return false }
                return filter.matches(JiraStore.shared.category(of: issue, connection: jira))
            })
            let unsettled = keys.filter { !JiraStore.shared.isSettled($0, connection: jira) }.count
            self.setHighlight(.tickets(title: filter.title, keys: matching))
            if unsettled > 0 {
                self.highlightNote = String(localized: "\(unsettled) statuses still loading", comment: "Ticket statuses Jira hasn't sent yet")
            }
        }
    }

    /// Highlights the commits of every ticket in a fix version and of their sub-tasks, as listed
    /// by Jira: by id for the versions GitTree listed, by name for one typed in.
    func highlightFixVersion(_ name: String, id: String? = nil, fromSidebar: Bool = false) {
        guard let jira else { return }
        let title = String(localized: "Fix version \(name)", comment: "A highlight: the commits of a Jira fix version's tickets")
        if let id, let keys = JiraStore.shared.cachedTickets(inFixVersionID: id, connection: jira) {
            // What Jira said last time shows right away; a fresh list follows when it's due.
            setHighlight(.tickets(title: title, keys: withChildren(Set(keys)), systemImage: "shippingbox", followsSidebar: fromSidebar),
                         base: Set(keys))
            highlightedRelease = id
            refineHighlight(base: [], failureNote: String(localized: "Couldn't ask Jira for the fix version's tickets")) {
                try await JiraStore.shared.tickets(inFixVersion: id, isID: true, connection: jira).map(\.key)
            }
            return
        }
        cancelHighlightLoad()
        highlightProgress = String(localized: "Loading fix version \(name)…")
        highlightLoadTask = Task { [weak self] in
            do {
                let issues = try await JiraStore.shared.tickets(inFixVersion: id ?? name, isID: id != nil, connection: jira)
                guard let self, !Task.isCancelled else { return }
                let keys = Set(issues.map(\.key))
                self.setHighlight(.tickets(title: title, keys: self.withChildren(keys), systemImage: "shippingbox", followsSidebar: fromSidebar),
                                  base: keys)
                self.highlightedRelease = id
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.cancelHighlightLoad()
                self.highlightNote = String(localized: "Couldn't load fix version \(name): \(error.localizedDescription)")
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
        highlightedRelease = nil
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
        highlightedRelease = nil
        highlightGeneration += 1
        if !searchText.isEmpty { searchText = "" }
        applyHighlight(jump: jump)
    }

    /// Widens the current ticket highlight to what Jira lists (an epic's or a fix version's
    /// tickets) when it answers, without moving the selection; a newer highlight cancels it.
    private func refineHighlight(base: Set<String>, failureNote: String, _ load: @escaping @MainActor () async throws -> [String]) {
        let generation = highlightGeneration
        highlightRefining = true
        highlightLoadTask = Task { [weak self] in
            let loaded: [String]
            do {
                loaded = try await load()
            } catch {
                guard let self, !Task.isCancelled, self.highlightGeneration == generation else { return }
                self.highlightRefining = false
                self.highlightNote = failureNote
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
        case .notDone: String(localized: "Tickets Not Done")
        case .inProgress: String(localized: "Tickets In Progress")
        case .toDo: String(localized: "Tickets To Do")
        }
    }

    /// By the ticket's status category, its project's Definition of Done counting as done.
    func matches(_ category: JiraIssue.Category) -> Bool {
        switch self {
        case .notDone: category != .done
        case .inProgress: category == .inProgress
        case .toDo: category == .toDo
        }
    }
}
