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

    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineFailedAt: [Int: Date] = [:]
    @ObservationIgnored private var ticketIndexCache: (graph: CommitGraph, index: TicketIndex)?
    @ObservationIgnored private var pullRequestTask: Task<Void, Never>?
    @ObservationIgnored private var pullRequestsLoadedAt: Date?
    @ObservationIgnored private var pullRequestRetryAt: Date?
    @ObservationIgnored private var pullRequestBackoff: TimeInterval = 5 * 60

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadDebounce: Task<Void, Never>?
    @ObservationIgnored private var watcher: GitDirectoryWatcher?
    @ObservationIgnored private var detailsCache: [ObjectID: CommitDetails] = [:]
    @ObservationIgnored private var searchIndexCache: (graph: CommitGraph, index: SearchIndex)?
    @ObservationIgnored private var didAutoFetch = false
    @ObservationIgnored private var didDetectHosting = false

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
        }
    }

    var isBusy: Bool { status == .loading || isFetching }

    func update(repository: Repository) {
        let prefixesChanged = repository.customTicketPrefixes != self.repository.customTicketPrefixes
        let ticketsChanged = repository.jiraProfileID != self.repository.jiraProfileID
            || repository.issueURLTemplate != self.repository.issueURLTemplate
        self.repository = repository
        // A different Jira: the Ticket column shows or hides and rows redraw.
        if ticketsChanged { annotationVersion += 1 }
        // Ticket keys are found while loading; new prefixes need a reload.
        if prefixesChanged, status != .idle { reload() }
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
        loadTask = Task { [weak self] in
            do {
                #if DEBUG
                let started = ContinuousClock.now
                #endif
                let graph = try await GraphLoader.load(repositoryAt: directory, ticketPrefixes: ticketPrefixes)
                let layout = await Task.detached(priority: .userInitiated) {
                    LaneLayoutEngine.layout(graph: graph, scope: .all)
                }.value
                #if DEBUG
                NSLog("GitTree: loaded %d commits and %d refs in %@", graph.count, graph.refs.count,
                      (ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))
                #endif
                guard !Task.isCancelled, let self else { return }
                self.graph = graph
                self.allLayout = layout
                self.status = .loaded
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
    /// so reloads, repeated clicks and quick switching never pile up requests.
    func refreshPullRequests(force: Bool = false) {
        guard let hosting, hosting.provider == .github, pullRequestTask == nil else { return }
        guard force || WindowState.isShowing(id) else { return }
        let now = Date()
        if let loaded = pullRequestsLoadedAt, now.timeIntervalSince(loaded) < (force ? 30 : 5 * 60) { return }
        if !force, let retry = pullRequestRetryAt, now < retry { return }
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
                result = .success(try await GitHubCLI.pullRequests(repository: repositoryPath))
            } catch {
                result = .failure(error)
            }
            GitHubCLI.gate.leave()
            guard let self else { return }
            self.pullRequestTask = nil
            switch result {
            case .success(let index):
                self.pullRequests = index
                let cache = PullRequestCache(loadedAt: Date(), pullRequests: index.all)
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

    private func didLoad() {
        if repository.kind == .local && watcher == nil { startWatching() }
        if hosting == nil && !didDetectHosting {
            didDetectHosting = true
            Task { await detectHosting() }
        } else {
            refreshPullRequests()
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
            let gitDirectory = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : directory.appendingPathComponent(raw)
            self.watcher = GitDirectoryWatcher(directory: gitDirectory.standardizedFileURL) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReloadFromDisk() }
            }
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
