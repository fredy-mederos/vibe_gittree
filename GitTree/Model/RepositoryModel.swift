import Foundation
import Observation

/// One repository's history, shared by every window that shows it. Loads with git, reloads when
/// the repository changes on disk, and fetches on request.
@MainActor @Observable final class RepositoryModel {
    enum LoadStatus: Equatable {
        case idle, loading, loaded, failed(String)
    }

    let id: UUID
    private(set) var repository: Repository
    private(set) var graph: CommitGraph?
    /// The unscoped layout, kept so switching between repositories and back is instant.
    private(set) var allLayout: GraphLayout?
    private(set) var status: LoadStatus = .idle
    private(set) var isFetching = false
    private(set) var fetchError: String?
    private(set) var hosting: HostingService?
    /// Increments every time `graph` is replaced.
    private(set) var generation = 0
    /// Pull requests from GitHub, when the repository is hosted there and `gh` is set up.
    private(set) var pullRequests: PullRequestIndex?
    private(set) var pullRequestProblem: String?
    /// Increments when pull requests or ticket statuses change, so visible rows redraw.
    private(set) var annotationVersion = 0
    /// Timelines of the pull requests selected so far, by number.
    private(set) var timelines: [Int: PullRequestTimeline] = [:]
    /// The pull request whose timeline is loading.
    private(set) var timelineLoading: Int?
    private(set) var timelineProblems: [Int: String] = [:]

    /// Uncommitted changes, for a repository with a working tree; nil before the first look and
    /// for bare repositories (Vibe GitTree's clones among them).
    private(set) var workingTree: WorkingTreeStatus?
    /// Whether `allLayout` has the row for uncommitted changes; windows lay out their history again
    /// when it flips.
    private(set) var hasUncommittedChanges = false
    /// Stashes, newest first.
    private(set) var stashes: [StashEntry] = []
    /// Increments every time the working tree is looked at, so diffs of uncommitted changes reload.
    private(set) var workingTreeVersion = 0
    /// A commit, stash or staging change under way ("Committing…"), and why the last one failed.
    private(set) var changeInProgress: String?
    private(set) var changeError: String?

    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineFailedAt: [Int: Date] = [:]
    @ObservationIgnored private var ticketIndexCache: (graph: CommitGraph, index: TicketIndex)?
    @ObservationIgnored private var pullRequestTask: Task<Void, Never>?
    @ObservationIgnored private var pullRequestsLoadedAt: Date?
    /// When the last full list of pull requests came; refreshes in between ask only for recent changes.
    @ObservationIgnored private var pullRequestsFullAt: Date?
    @ObservationIgnored private var pullRequestRetryAt: Date?
    @ObservationIgnored private var pullRequestBackoff: TimeInterval = 5 * 60
    @ObservationIgnored private var defaultBranchTask: Task<Void, Never>?
    @ObservationIgnored private var defaultBranchRetryAt: Date?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadDebounce: Task<Void, Never>?
    @ObservationIgnored private var watcher: GitDirectoryWatcher?
    @ObservationIgnored private var detailsCache: [ObjectID: CommitDetails] = [:]
    @ObservationIgnored private var searchIndexCache: (graph: CommitGraph, index: SearchIndex)?
    @ObservationIgnored private var didAutoFetch = false
    @ObservationIgnored private var didDetectHosting = false

    /// This worktree's own git folder, where a merge or rebase leaves its marks.
    @ObservationIgnored private var gitDirectory: URL?
    /// Found out when `git status` fails: a bare repository has no working tree to look at.
    @ObservationIgnored private var isBare = false
    @ObservationIgnored private var workingTreeWatcher: WorkingTreeWatcher?
    @ObservationIgnored private var ignoredPaths: IgnoredPaths?
    @ObservationIgnored private var ignoredPathsAt = Date.distantPast
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var statusDebounce: Task<Void, Never>?
    @ObservationIgnored private var statusPending = false
    @ObservationIgnored private var lastStatusStart = Date.distantPast
    /// Files changed while no window showed the repository; it looks again when one does.
    @ObservationIgnored private var workingTreeIsStale = false
    /// Diff windows of uncommitted changes open: while there are any, the working tree is looked
    /// at even when no repository window shows the repository.
    @ObservationIgnored private var workingTreeViewers = 0
    /// Every look at the working tree is numbered, so an older answer can't replace a newer one.
    @ObservationIgnored private var statusSequence = 0
    @ObservationIgnored private var appliedStatusSequence = 0
    @ObservationIgnored private var relayoutTask: Task<Void, Never>?
    @ObservationIgnored private var stashTask: Task<Void, Never>?
    @ObservationIgnored private var stashDetailsCache: [ObjectID: StashDetails] = [:]

    init(repository: Repository) {
        id = repository.id
        self.repository = repository
        if repository.kind == .remote, let url = repository.remoteURL {
            hosting = HostingService(remoteURL: url)
        }
        // Last session's pull requests show right away; a refresh follows under the usual limits.
        if let cached = PullRequestCache.load(repositoryID: repository.id),
           Date().timeIntervalSince(cached.loadedAt) < 7 * 24 * 60 * 60 {
            pullRequests = PullRequestIndex(cached.pullRequests)
            pullRequestsLoadedAt = cached.loadedAt
            pullRequestsFullAt = cached.fullAt
        }
    }

    var isBusy: Bool { status == .loading || isFetching }

    /// Local repositories with a working tree (not bare ones, nor Vibe GitTree's clones).
    var hasWorkingTree: Bool { repository.kind == .local && !isBare }

    /// The branch the graph draws as its trunk (see `MainBranch`).
    var mainBranch: String? {
        graph.flatMap(repository.effectiveMainBranch(in:))
    }

    func update(repository: Repository) {
        let prefixesChanged = repository.customTicketPrefixes != self.repository.customTicketPrefixes
        let ticketsChanged = repository.jiraProfileID != self.repository.jiraProfileID
            || repository.issueURLTemplate != self.repository.issueURLTemplate
        let mainBranch = self.mainBranch
        self.repository = repository
        // A different Jira: the Ticket column shows or hides and rows redraw.
        if ticketsChanged { annotationVersion += 1 }
        // Ticket keys are found while loading; new prefixes need a reload.
        if prefixesChanged, status != .idle {
            reload()
        } else if self.mainBranch != mainBranch {
            // Another main branch, picked or named by GitHub.
            layOutAgainIfNeeded()
        }
    }

    func loadIfNeeded() {
        guard status == .idle else { return }
        reload()
    }

    func reload() {
        loadTask?.cancel()
        if graph == nil { status = .loading }
        let directory = repository.directory
        let ticketPrefixes = repository.customTicketPrefixes
        // The working tree is looked at along with the history, so the history is laid out once,
        // with its row for uncommitted changes when there are any.
        let looksAtWorkingTree = hasWorkingTree
        let gitDirectory = gitDirectory
        statusSequence += 1
        let sequence = statusSequence
        loadTask = Task { [weak self] in
            do {
                #if DEBUG
                let started = ContinuousClock.now
                #endif
                async let loadedStatus = looksAtWorkingTree ? Self.loadWorkingTree(in: directory, gitDirectory: gitDirectory) : nil
                let graph = try await GraphLoader.load(repositoryAt: directory, ticketPrefixes: ticketPrefixes)
                let workingTree = await loadedStatus
                let dirty = workingTree?.isClean == false
                let mainBranch = self?.repository.effectiveMainBranch(in: graph)
                let layout = await Task.detached(priority: .userInitiated) {
                    LaneLayoutEngine.layout(graph: graph, scope: .all, workingTree: dirty, mainBranch: mainBranch)
                }.value
                #if DEBUG
                NSLog("GitTree: loaded %d commits and %d refs in %@", graph.count, graph.refs.count,
                      (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))
                #endif
                guard !Task.isCancelled, let self else { return }
                self.graph = graph
                self.allLayout = layout
                self.hasUncommittedChanges = dirty
                self.status = .loaded
                if looksAtWorkingTree { self.apply(workingTree, sequence: sequence, directory: directory) }
                self.generation += 1
                self.didLoad()
            } catch {
                guard !Task.isCancelled, let self else { return }
                if self.graph == nil { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        fetchError = nil
        let arguments = repository.kind == .remote
            ? ["fetch", "--prune", "--tags", "origin"]
            : ["fetch", "--all", "--prune"]
        do {
            _ = try await Git.run(arguments, in: repository.directory, timeout: 300)
            RepositoryLibrary.shared.markFetched(id)
        } catch {
            fetchError = error.localizedDescription
        }
        isFetching = false
        reload()
        refreshPullRequests(force: true)
    }

    func details(for commit: Int32, in graph: CommitGraph) async -> CommitDetails? {
        let id = graph.ids[Int(commit)]
        if let cached = detailsCache[id] { return cached }
        let parent = graph.parents(commit).first.flatMap { $0 >= 0 ? graph.ids[Int($0)] : nil }
        guard let details = try? await CommitDetailsLoader.load(
            commit: id, firstParent: parent, in: repository.directory, detectRenames: repository.kind == .local
        ) else { return nil }
        detailsCache[id] = details
        return details
    }

    func containment(of commit: Int32, in graph: CommitGraph) async -> Containment {
        let pattern = repository.effectiveReleaseTagPattern
        return await Task.detached(priority: .userInitiated) {
            Containment.compute(commit: commit, graph: graph, releasePattern: pattern)
        }.value
    }

    func searchIndex(for graph: CommitGraph) async -> SearchIndex {
        if let cached = searchIndexCache, cached.graph === graph { return cached.index }
        let index = await Task.detached(priority: .userInitiated) { SearchIndex(graph: graph) }.value
        searchIndexCache = (graph, index)
        return index
    }

    func ticketIndex(for graph: CommitGraph) async -> TicketIndex {
        if let cached = ticketIndexCache, cached.graph === graph { return cached.index }
        let index = await Task.detached(priority: .userInitiated) { TicketIndex(graph: graph) }.value
        ticketIndexCache = (graph, index)
        return index
    }

    /// Loads a pull request's timeline with `gh` when it's selected: after a short pause (so
    /// arrowing through the list doesn't ask for every row), one call at a time with the other
    /// `gh` calls, and not again for five minutes while it's open (merged and closed ones don't
    /// change). After a failure it waits a minute before trying that pull request again.
    func loadTimeline(for pullRequest: PullRequest) {
        guard let hosting, hosting.provider == .github else { return }
        let number = pullRequest.number
        if let cached = timelines[number], pullRequest.state != .open || Date().timeIntervalSince(cached.loadedAt) < 5 * 60 { return }
        if let failed = timelineFailedAt[number], Date().timeIntervalSince(failed) < 60 { return }
        timelineTask?.cancel()
        timelineLoading = number
        let repositoryPath = hosting.path
        timelineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await GitHubCLI.gate.enter()
            guard !Task.isCancelled else {
                GitHubCLI.gate.leave()
                return
            }
            let result: Result<PullRequestTimeline, Error>
            do {
                result = .success(try await GitHubCLI.timeline(repository: repositoryPath, number: number))
            } catch {
                result = .failure(error)
            }
            GitHubCLI.gate.leave()
            guard let self else { return }
            if self.timelineLoading == number { self.timelineLoading = nil }
            switch result {
            case .success(let timeline):
                self.timelines[number] = timeline
                self.timelineProblems[number] = nil
                self.timelineFailedAt[number] = nil
            case .failure(let error):
                self.timelineProblems[number] = error.localizedDescription
                self.timelineFailedAt[number] = Date()
            }
        }
    }

    /// Loads pull requests with `gh`, carefully: only for a repository a window shows (or when the
    /// user asks with Fetch), one refresh at a time across the app, at most every five minutes
    /// (every 30 seconds after Fetch), with a 30-second timeout and growing waits after failures,
    /// so reloads, repeated clicks and quick switching never pile up requests. Between full lists
    /// (every six hours, or on Fetch) a refresh asks only for the pull requests updated most recently.
    func refreshPullRequests(force: Bool = false) {
        guard let hosting, hosting.provider == .github, pullRequestTask == nil else { return }
        guard force || WindowState.isShowing(id) else { return }
        let now = Date()
        if let loaded = pullRequestsLoadedAt, now.timeIntervalSince(loaded) < (force ? 30 : 5 * 60) { return }
        if !force, let retry = pullRequestRetryAt, now < retry { return }
        let full = force || pullRequests == nil || pullRequestsFullAt.map { now.timeIntervalSince($0) > 6 * 60 * 60 } ?? true
        let previous = full ? nil : pullRequests?.all
        let repositoryPath = hosting.path
        let id = id
        pullRequestTask = Task { [weak self] in
            await GitHubCLI.gate.enter()
            // By the time it's this repository's turn, its window may have moved on.
            guard force || WindowState.isShowing(id) else {
                GitHubCLI.gate.leave()
                self?.pullRequestTask = nil
                return
            }
            let result: Result<PullRequestIndex, Error>
            do {
                result = .success(try await GitHubCLI.pullRequests(repository: repositoryPath, mergingInto: previous))
            } catch {
                result = .failure(error)
            }
            GitHubCLI.gate.leave()
            guard let self else { return }
            self.pullRequestTask = nil
            switch result {
            case .success(let index):
                self.pullRequests = index
                if full { self.pullRequestsFullAt = Date() }
                let cache = PullRequestCache(loadedAt: Date(), pullRequests: index.all, fullAt: self.pullRequestsFullAt)
                let repositoryID = self.id
                Task.detached(priority: .utility) { cache.save(repositoryID: repositoryID) }
                self.pullRequestProblem = nil
                self.pullRequestsLoadedAt = Date()
                self.pullRequestRetryAt = nil
                self.pullRequestBackoff = 5 * 60
                self.annotationVersion += 1
            case .failure(let error):
                self.pullRequestProblem = error.localizedDescription
                self.pullRequestRetryAt = Date().addingTimeInterval(self.pullRequestBackoff)
                self.pullRequestBackoff = min(self.pullRequestBackoff * 2, 60 * 60)
            }
        }
    }

    /// Ticket statuses arrived from Jira; redraw.
    func annotationsChanged() {
        annotationVersion += 1
    }

    /// Asks GitHub for the repository's default branch, which picks the main branch: at most once a
    /// day (the answer is kept in the library), one `gh` call at a time with the others, only for a
    /// repository a window shows, and an hour after a failure. Meanwhile the one git noted when
    /// cloning stands in.
    func refreshDefaultBranch() {
        guard let hosting, hosting.provider == .github, defaultBranchTask == nil, WindowState.isShowing(id) else { return }
        let now = Date()
        if let checked = repository.defaultBranchCheckedAt, now.timeIntervalSince(checked) < 24 * 60 * 60 { return }
        if let retry = defaultBranchRetryAt, now < retry { return }
        let repositoryPath = hosting.path
        let id = id
        defaultBranchTask = Task { [weak self] in
            await GitHubCLI.gate.enter()
            guard WindowState.isShowing(id) else {
                GitHubCLI.gate.leave()
                self?.defaultBranchTask = nil
                return
            }
            let name = try? await GitHubCLI.defaultBranch(repository: repositoryPath)
            GitHubCLI.gate.leave()
            guard let self else { return }
            self.defaultBranchTask = nil
            if let name {
                RepositoryLibrary.shared.recordDefaultBranch(name, for: id)
            } else {
                self.defaultBranchRetryAt = Date().addingTimeInterval(60 * 60)
            }
        }
    }

    private func didLoad() {
        if repository.kind == .local && watcher == nil { startWatching() }
        refreshStashes()
        if hosting == nil && !didDetectHosting {
            didDetectHosting = true
            Task { await detectHosting() }
        } else {
            refreshPullRequests()
            refreshDefaultBranch()
        }
        if repository.kind == .remote && !didAutoFetch && AppSettings.fetchRemotesOnOpen {
            didAutoFetch = true
            let stale = repository.lastFetchedAt.map { Date().timeIntervalSince($0) > 10 * 60 } ?? true
            if stale { Task { await fetch() } }
        }
    }

    private func startWatching() {
        let directory = repository.directory
        Task { [weak self] in
            guard let raw = try? await Git.string(["rev-parse", "--git-common-dir"], in: directory), let self else { return }
            let commonDirectory = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : directory.appendingPathComponent(raw)
            self.watcher = GitDirectoryWatcher(directory: commonDirectory.standardizedFileURL) { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A reload looks at the working tree and the stashes too.
                    if change.contains(.refs) {
                        self.scheduleReloadFromDisk()
                        return
                    }
                    if change.contains(.index) { self.scheduleWorkingTreeRefresh() }
                    if change.contains(.stash) { self.refreshStashes() }
                }
            }
            guard self.hasWorkingTree else { return }
            let gitDirectory = await WorkingTreeLoader.gitDirectory(of: directory)
            self.gitDirectory = gitDirectory
            self.workingTreeWatcher = WorkingTreeWatcher(directory: directory) { [weak self] paths, everything in
                MainActor.assumeIsolated { self?.workingTreeFilesChanged(paths, everything: everything) }
            }
            // The first look didn't know where to find a merge or rebase under way.
            if gitDirectory != nil { self.refreshWorkingTree() }
        }
    }

    private func scheduleReloadFromDisk() {
        guard !isFetching else { return }
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: Working tree

    /// The working tree's status, or nil when git couldn't tell (then a bare repository is noted).
    private static func loadWorkingTree(in directory: URL, gitDirectory: URL?) async -> WorkingTreeStatus? {
        try? await WorkingTreeLoader.status(in: directory, gitDirectory: gitDirectory)
    }

    /// Files in the working tree changed: unless they're all in places git ignores (a build
    /// folder, say), the status is looked at again shortly.
    private func workingTreeFilesChanged(_ paths: [String], everything: Bool) {
        if paths.contains(where: { $0 == ".gitignore" || $0.hasSuffix("/.gitignore") }) { ignoredPaths = nil }
        if !everything, let ignoredPaths, !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty && ignoredPaths.contains($0) }) { return }
        scheduleWorkingTreeRefresh(fromFileEvents: true)
    }

    /// Looks at the working tree again after a short pause, at most about once a second, and
    /// only for a repository a window shows (the others look when they're shown again).
    func scheduleWorkingTreeRefresh(fromFileEvents: Bool = false) {
        guard hasWorkingTree, graph != nil else { return }
        guard WindowState.isShowing(id) || workingTreeViewers > 0 else {
            workingTreeIsStale = true
            return
        }
        statusDebounce?.cancel()
        let wait = max(0.25, 1 - Date().timeIntervalSince(lastStatusStart))
        statusDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refreshWorkingTree(fromFileEvents: fromFileEvents)
        }
    }

    /// Shown again after files changed out of sight: look at them now.
    func refreshWorkingTreeIfStale() {
        guard workingTreeIsStale else { return }
        refreshWorkingTree()
    }

    /// A diff window of uncommitted changes opened (restored at launch, say): the repository is
    /// read if it wasn't, and its working tree followed until `endWatchingWorkingTree()`.
    func beginWatchingWorkingTree() {
        workingTreeViewers += 1
        if graph == nil {
            loadIfNeeded()
        } else {
            refreshWorkingTreeIfStale()
        }
    }

    func endWatchingWorkingTree() {
        workingTreeViewers = max(0, workingTreeViewers - 1)
    }

    /// Asks git for the working tree's status, one look at a time; a change during a look brings
    /// another right after.
    func refreshWorkingTree(fromFileEvents: Bool = false) {
        guard hasWorkingTree else { return }
        guard statusTask == nil else {
            statusPending = true
            return
        }
        workingTreeIsStale = false
        lastStatusStart = Date()
        statusSequence += 1
        let sequence = statusSequence
        let directory = repository.directory
        let gitDirectory = gitDirectory
        let before = workingTree
        let needsIgnoredPaths = ignoredPaths == nil
        statusTask = Task { [weak self] in
            let status = await Self.loadWorkingTree(in: directory, gitDirectory: gitDirectory)
            let ignored = needsIgnoredPaths ? await WorkingTreeLoader.ignoredPaths(in: directory) : nil
            guard let self else { return }
            self.statusTask = nil
            if let ignored {
                self.ignoredPaths = ignored
                self.ignoredPathsAt = Date()
            }
            self.apply(status, sequence: sequence, directory: directory)
            // Files changed but git sees nothing new: likely a folder it ignores that didn't exist
            // when it was last asked about them (a first build). Ask again, at most every half minute.
            if fromFileEvents, status != nil, status == before, Date().timeIntervalSince(self.ignoredPathsAt) > 30 {
                self.ignoredPaths = nil
            }
            if self.statusPending {
                self.statusPending = false
                self.scheduleWorkingTreeRefresh()
            }
        }
    }

    /// Takes a look's answer unless a newer one came first, and lays the history out again when
    /// the row for uncommitted changes comes or goes.
    private func apply(_ status: WorkingTreeStatus?, sequence: Int, directory: URL) {
        if sequence > appliedStatusSequence {
            appliedStatusSequence = sequence
            if let status {
                if status != workingTree { workingTree = status }
                workingTreeVersion += 1
            } else {
                // No answer: a bare repository has no working tree; anything else keeps the last answer.
                Task { [weak self] in
                    let inside = try? await Git.string(["rev-parse", "--is-inside-work-tree"], in: directory)
                    guard let self, inside != "true" else { return }
                    self.isBare = true
                    self.workingTree = nil
                    self.workingTreeWatcher = nil
                    self.layOutAgainIfNeeded()
                }
            }
        }
        // A newer answer may have come during a reload, which laid the history out for an older one.
        layOutAgainIfNeeded()
    }

    /// Lays `allLayout` out again when it no longer matches: the row for uncommitted changes comes or
    /// goes with the working tree, or the main branch changed.
    private func layOutAgainIfNeeded() {
        let dirty = workingTree?.isClean == false
        let mainBranch = mainBranch
        guard let graph else {
            hasUncommittedChanges = dirty
            return
        }
        if dirty == hasUncommittedChanges, allLayout?.mainBranch == mainBranch {
            // A layout for an older answer may still be on its way.
            relayoutTask?.cancel()
            relayoutTask = nil
            return
        }
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            let layout = await Task.detached(priority: .userInitiated) {
                LaneLayoutEngine.layout(graph: graph, scope: .all, workingTree: dirty, mainBranch: mainBranch)
            }.value
            guard !Task.isCancelled, let self, self.graph === graph else { return }
            self.allLayout = layout
            self.hasUncommittedChanges = dirty
        }
    }

    func refreshStashes() {
        guard hasWorkingTree else { return }
        stashTask?.cancel()
        let directory = repository.directory
        stashTask = Task { [weak self] in
            let list = await StashLoader.list(in: directory)
            guard !Task.isCancelled, let self else { return }
            if list != self.stashes { self.stashes = list }
        }
    }

    func stashDetails(_ stash: StashEntry) async -> StashDetails? {
        if let cached = stashDetailsCache[stash.id] { return cached }
        guard let details = try? await StashLoader.details(of: stash, in: repository.directory) else { return nil }
        stashDetailsCache[stash.id] = details
        return details
    }

    // MARK: Changing the repository

    /// Whether this repository can be changed from Vibe GitTree: it has a working tree and
    /// Settings › General › Allow commits and stashes is on.
    var allowsChanges: Bool { hasWorkingTree && AppSettings.allowsChanges }

    /// Runs a change the user clicked for, one at a time, then looks at the working tree and the
    /// stashes again (the history reloads by itself when refs move). Returns whether it worked.
    @discardableResult
    private func perform(_ title: String, _ action: @escaping @Sendable (URL) async throws -> Void) async -> Bool {
        guard allowsChanges, changeInProgress == nil else { return false }
        changeInProgress = title
        changeError = nil
        let directory = repository.directory
        do {
            try await action(directory)
        } catch {
            changeError = error.localizedDescription
        }
        changeInProgress = nil
        refreshWorkingTree()
        refreshStashes()
        return changeError == nil
    }

    /// The paths a change touches: a staged rename's old path too, so unstaging it puts the old file back.
    private static func paths(of changes: [WorkingChange]) -> [String] {
        var paths: [String] = []
        for change in changes {
            paths.append(change.path)
            if let oldPath = change.oldPath { paths.append(oldPath) }
        }
        return paths
    }

    func stage(_ changes: [WorkingChange]) async {
        let paths = Self.paths(of: changes)
        guard !paths.isEmpty else { return }
        await perform(String(localized: "Staging…")) { try await WorkingTreeActions.stage(paths, in: $0) }
    }

    func unstage(_ changes: [WorkingChange]) async {
        let paths = Self.paths(of: changes)
        guard !paths.isEmpty else { return }
        await perform(String(localized: "Unstaging…")) { try await WorkingTreeActions.unstage(paths, in: $0) }
    }

    func stageAll() async {
        await perform(String(localized: "Staging…")) { try await WorkingTreeActions.stageAll(in: $0) }
    }

    func unstageAll() async {
        await perform(String(localized: "Unstaging…")) { try await WorkingTreeActions.unstageAll(in: $0) }
    }

    /// Commits what's staged; the history shows the new commit right away.
    func commit(message: String) async -> Bool {
        let committed = await perform(String(localized: "Committing…")) { try await WorkingTreeActions.commit(message: message, in: $0) }
        if committed { reload() }
        return committed
    }

    /// Stashes these files' changes (every file's when nil), new files included.
    func stash(_ changes: [WorkingChange]?, message: String) async -> Bool {
        let paths = changes.map(Self.paths(of:))
        // No files would mean every file to `git stash push`.
        if paths?.isEmpty == true { return false }
        return await perform(String(localized: "Stashing…")) { try await WorkingTreeActions.stash(paths, message: message, in: $0) }
    }

    func applyStash(_ stash: StashEntry) async -> Bool {
        let id = stash.id
        return await perform(String(localized: "Applying \(stash.name)…")) { try await WorkingTreeActions.apply(id, in: $0) }
    }

    func popStash(_ stash: StashEntry) async -> Bool {
        let id = stash.id
        return await perform(String(localized: "Popping \(stash.name)…")) { try await WorkingTreeActions.pop(id, in: $0) }
    }

    func dropStash(_ stash: StashEntry) async -> Bool {
        let id = stash.id
        return await perform(String(localized: "Dropping \(stash.name)…")) { try await WorkingTreeActions.drop(id, in: $0) }
    }

    func dismissChangeError() {
        changeError = nil
    }

    private func detectHosting() async {
        let directory = repository.directory
        var remote = try? await Git.string(["remote", "get-url", "origin"], in: directory)
        if remote?.isEmpty ?? true,
           let names = try? await Git.string(["remote"], in: directory),
           let first = names.split(separator: "\n").first {
            remote = try? await Git.string(["remote", "get-url", String(first)], in: directory)
        }
        if let remote, !remote.isEmpty {
            RepositoryLibrary.shared.recordOrigin(remote, for: id)
            hosting = HostingService(remoteURL: remote)
            refreshPullRequests()
            refreshDefaultBranch()
        }
    }
}

/// Keeps one `RepositoryModel` per repository so windows share loaded history.
@MainActor final class RepositoryModelStore {
    static let shared = RepositoryModelStore()

    private var models: [UUID: RepositoryModel] = [:]

    func model(for repository: Repository) -> RepositoryModel {
        if let existing = models[repository.id] { return existing }
        let model = RepositoryModel(repository: repository)
        models[repository.id] = model
        return model
    }

    func existingModel(id: UUID) -> RepositoryModel? {
        models[id]
    }

    func discard(id: UUID) {
        models[id] = nil
    }
}
