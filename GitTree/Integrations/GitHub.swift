import Foundation

struct PullRequest: Identifiable, Hashable, Sendable, Codable {
    enum State: String, Sendable, Codable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    enum Checks: String, Sendable, Codable {
        case passing, failing, pending
    }

    let number: Int
    let title: String
    let state: State
    let isDraft: Bool
    let head: String
    let base: String
    let url: URL
    let mergeCommit: ObjectID?
    let author: String?
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED, for open pull requests.
    var reviewDecision: String?
    var checks: Checks?

    var id: Int { number }

    var stateTitle: String {
        if state == .open && isDraft { return String(localized: "Draft", comment: "A pull request's state") }
        switch state {
        case .open: return String(localized: "Open", comment: "A pull request's state")
        case .merged: return String(localized: "Merged", comment: "A pull request's state, or the event when it was merged")
        case .closed: return String(localized: "Closed", comment: "A pull request's state, or the event when it was closed")
        }
    }

    var reviewTitle: String? {
        switch reviewDecision {
        case "APPROVED": String(localized: "Approved")
        case "CHANGES_REQUESTED": String(localized: "Changes requested")
        case "REVIEW_REQUIRED": String(localized: "Review required")
        default: nil
        }
    }

    var isApproved: Bool { reviewDecision == "APPROVED" }

    /// One mark for the two things a pull request waits on, CI and review.
    enum Readiness {
        /// CI passed and the pull request is approved: a filled check.
        case ready
        /// CI passed, still waiting for approval: an outlined check.
        case checksPassed
        case checksRunning
        case checksFailing

        var symbol: String {
            switch self {
            case .ready: "checkmark.circle.fill"
            case .checksPassed: "checkmark.circle"
            case .checksRunning: "clock.fill"
            case .checksFailing: "xmark.circle.fill"
            }
        }

        var explanation: String {
            switch self {
            case .ready: String(localized: "Checks passed and approved")
            case .checksPassed: String(localized: "Checks passed, waiting for approval")
            case .checksRunning: String(localized: "Checks running")
            case .checksFailing: String(localized: "Checks failed")
            }
        }
    }

    var readiness: Readiness? {
        switch checks {
        case .failing: return .checksFailing
        case .pending: return .checksRunning
        case .passing: return isApproved ? .ready : .checksPassed
        case nil: return isApproved ? .ready : nil
        }
    }
}

extension PullRequest {
    /// The pull request's branch in the graph: the local one, or else the remote one.
    func ref(in graph: CommitGraph) -> GitRef? {
        graph.refs.first { $0.kind == .local && $0.name == head }
            ?? graph.refs.first { $0.kind == .remote && $0.remoteParts?.branch == head }
    }
}

/// Pull requests of one GitHub repository, indexed the ways the graph needs them, plus stacks:
/// open pull requests whose base branch is another open pull request's branch.
struct PullRequestIndex: Sendable {
    let all: [PullRequest]
    let byNumber: [Int: PullRequest]
    let byMergeCommit: [ObjectID: PullRequest]
    /// All stacks of open pull requests, newest first, each ordered bottom to top.
    private(set) var stacks: [[PullRequest]] = []
    private let byHead: [String: [PullRequest]]
    private let openByHead: [String: PullRequest]
    private let openChildren: [String: [PullRequest]]
    /// Open pull requests others can be stacked on, by head branch.
    private let stackParents: [String: PullRequest]

    /// develop, main, release branches and the like.
    static func isLongLived(_ branch: String) -> Bool {
        let name = branch.lowercased()
        let trunks: Set<String> = ["main", "master", "develop", "development", "dev", "trunk", "staging", "stage",
                                   "production", "prod", "next"]
        return trunks.contains(name)
            || ["release/", "release-", "release_", "releases/", "hotfix/", "rc/"].contains { name.hasPrefix($0) }
    }

    init(_ pullRequests: [PullRequest]) {
        all = pullRequests
        byNumber = Dictionary(pullRequests.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var mergeCommits: [ObjectID: PullRequest] = [:]
        var heads: [String: [PullRequest]] = [:]
        var openHeads: [String: PullRequest] = [:]
        var children: [String: [PullRequest]] = [:]
        for pullRequest in pullRequests.sorted(by: { $0.number > $1.number }) {
            if let commit = pullRequest.mergeCommit { mergeCommits[commit] = pullRequest }
            heads[pullRequest.head, default: []].append(pullRequest)
            if pullRequest.state == .open {
                if openHeads[pullRequest.head] == nil { openHeads[pullRequest.head] = pullRequest }
                children[pullRequest.base, default: []].append(pullRequest)
            }
        }
        byMergeCommit = mergeCommits
        byHead = heads
        openByHead = openHeads
        openChildren = children.mapValues { $0.sorted { $0.number < $1.number } }
        // A pull request from a long-lived branch (a release PR from develop to main) or one that
        // many others are based on is a trunk, not the bottom of a stack.
        stackParents = openHeads.filter { head, _ in
            !Self.isLongLived(head) && (children[head]?.count ?? 0) < 5
        }

        var found: [[PullRequest]] = []
        var covered: Set<Int> = []
        for pullRequest in pullRequests where pullRequest.state == .open && !covered.contains(pullRequest.number) {
            let stack = stack(containing: pullRequest)
            guard !stack.isEmpty else { continue }
            covered.formUnion(stack.map(\.number))
            found.append(stack)
        }
        stacks = found.sorted { ($0.map(\.number).max() ?? 0) > ($1.map(\.number).max() ?? 0) }
    }

    /// Every pull request opened from a branch, newest first.
    func pullRequests(forBranch branch: String) -> [PullRequest] {
        byHead[branch] ?? []
    }

    func openPullRequest(forBranch branch: String) -> PullRequest? {
        openByHead[branch]
    }

    /// The stack a pull request belongs to, from the bottom (based on a regular branch) to the top.
    /// Empty when it isn't stacked.
    func stack(containing pullRequest: PullRequest) -> [PullRequest] {
        guard pullRequest.state == .open else { return [] }
        var root = pullRequest
        var seen: Set<Int> = [root.number]
        while let parent = stackParents[root.base], !seen.contains(parent.number) {
            seen.insert(parent.number)
            root = parent
        }
        var ordered: [PullRequest] = []
        var visited: Set<Int> = []
        func walk(_ node: PullRequest) {
            guard visited.insert(node.number).inserted else { return }
            ordered.append(node)
            guard stackParents[node.head] != nil else { return }
            for child in openChildren[node.head] ?? [] { walk(child) }
        }
        walk(root)
        return ordered.count > 1 ? ordered : []
    }
}

/// Reads pull requests with the GitHub CLI (`gh`), which already handles sign-in.
enum GitHubCLI {
    static var executableURL: URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Two `gh` calls: pull requests in any state, then reviews and checks for the open ones.
    /// Without `previous` it's a full list, the latest 400 (four pages, so four API requests);
    /// with it, only the 100 updated most recently (two requests), merged into `previous`.
    /// `repository` is `owner/name`.
    static func pullRequests(repository: String, mergingInto previous: [PullRequest]? = nil) async throws -> PullRequestIndex {
        guard let gh = executableURL else {
            throw CommandError(command: "gh", status: 127, output: String(localized: "Install the GitHub CLI (brew install gh) and run `gh auth login` to see pull requests."))
        }
        let range = previous == nil
            ? ["--state", "all", "--limit", "400"]
            : ["--state", "all", "--limit", "100", "--search", "sort:updated-desc"]
        let listed = try await ProcessRunner.run(
            gh,
            ["pr", "list", "--repo", repository] + range
                + ["--json", "number,title,state,isDraft,headRefName,baseRefName,url,mergeCommit,author"],
            environment: Git.environment, timeout: 30
        )
        let open = try await ProcessRunner.run(
            gh,
            ["pr", "list", "--repo", repository, "--state", "open", "--limit", "200",
             "--json", "number,reviewDecision,statusCheckRollup"],
            environment: Git.environment, timeout: 30
        )
        return try await Task.detached(priority: .utility) {
            try decode(listed: listed, open: open, previous: previous)
        }.value
    }

    /// The repository's default branch (develop, main…): one `gh` call. `repository` is `owner/name`.
    static func defaultBranch(repository: String) async throws -> String {
        guard let gh = executableURL else {
            throw CommandError(command: "gh", status: 127, output: String(localized: "Install the GitHub CLI (brew install gh) and run `gh auth login`."))
        }
        let output = try await ProcessRunner.run(
            gh, ["repo", "view", repository, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
            environment: Git.environment, timeout: 30
        )
        let name = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CommandError(command: "gh repo view", status: 1, output: String(localized: "GitHub didn't name a default branch.")) }
        return name
    }

    private struct ListedPullRequest: Decodable {
        struct Commit: Decodable { let oid: String }
        struct Author: Decodable { let login: String }
        let number: Int
        let title: String
        let state: String
        let isDraft: Bool
        let headRefName: String
        let baseRefName: String
        let url: URL
        let mergeCommit: Commit?
        let author: Author?
    }

    private struct OpenPullRequest: Decodable {
        struct Check: Decodable {
            let status: String?
            let conclusion: String?
            let state: String?
        }
        let number: Int
        let reviewDecision: String?
        let statusCheckRollup: [Check]?
    }

    private static func decode(listed: Data, open: Data, previous: [PullRequest]?) throws -> PullRequestIndex {
        let decoder = JSONDecoder()
        let openDetails = try decoder.decode([OpenPullRequest].self, from: open)
        let details = Dictionary(openDetails.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var pullRequests = try decoder.decode([ListedPullRequest].self, from: listed).map { item -> PullRequest in
            PullRequest(
                number: item.number, title: item.title, state: PullRequest.State(rawValue: item.state) ?? .closed,
                isDraft: item.isDraft, head: item.headRefName, base: item.baseRefName, url: item.url,
                mergeCommit: item.mergeCommit.flatMap { ObjectID(hex: $0.oid) }, author: item.author?.login
            )
        }
        if let previous {
            // Anything that changed since the last refresh is among the ones updated most recently;
            // the rest is as it was. One listed as open that isn't open anymore (merged or closed
            // while more than 100 others changed) is left out until the next full list says how it ended.
            let updated = Set(pullRequests.map(\.number))
            let openComplete = openDetails.count < 200
            pullRequests += previous.filter { pullRequest in
                !updated.contains(pullRequest.number)
                    && !(openComplete && pullRequest.state == .open && details[pullRequest.number] == nil)
            }
            // About as many as a full list: the newest 400, and every open one.
            pullRequests.sort { $0.number > $1.number }
            pullRequests = pullRequests.enumerated().filter { $0.offset < 400 || $0.element.state == .open }.map(\.element)
        }
        for index in pullRequests.indices {
            let detail = pullRequests[index].state == .open ? details[pullRequests[index].number] : nil
            pullRequests[index].reviewDecision = detail?.reviewDecision.flatMap { $0.isEmpty ? nil : $0 }
            pullRequests[index].checks = detail?.statusCheckRollup.flatMap(summarize)
        }
        return PullRequestIndex(pullRequests)
    }

    /// One state for all of a pull request's checks: any failure wins, then anything still running.
    private static func summarize(_ checks: [OpenPullRequest.Check]) -> PullRequest.Checks? {
        guard !checks.isEmpty else { return nil }
        let failing: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        var pending = false
        for check in checks {
            if let conclusion = check.conclusion, failing.contains(conclusion) { return .failing }
            if let state = check.state, failing.contains(state) { return .failing }
            if let status = check.status, status != "COMPLETED" { pending = true }
            if check.state == "PENDING" || check.state == "EXPECTED" { pending = true }
        }
        return pending ? .pending : .passing
    }
}

/// What happened to a pull request, oldest first: opened, commits added, reviews asked for and
/// given, and merged or closed.
struct PullRequestTimeline: Sendable {
    struct Event: Identifiable, Sendable {
        enum Kind: Sendable, Equatable {
            /// With the commits it was opened with.
            case opened(commits: Int, draft: Bool)
            /// Commits added in one go (close together in time; GitHub doesn't say when they were pushed).
            case commits(Int)
            case forcePushed
            case reviewRequested([String])
            case approved
            case changesRequested
            case commented
            case dismissed
            case readyForReview
            case convertedToDraft
            case merged
            case closed
            case reopened
        }

        let id: Int
        let date: Date
        let kind: Kind
        let actor: String?
    }

    let number: Int
    let createdAt: Date
    /// When it was merged or closed; nil while it's open.
    let endedAt: Date?
    let state: PullRequest.State
    let events: [Event]
    /// When GitTree asked GitHub.
    let loadedAt: Date

    /// "Merged after 21 hours, approved after 20 hours".
    var summary: String {
        var parts: [String] = []
        switch state {
        case .merged: parts.append(String(localized: "Merged after \(Self.duration(from: createdAt, to: endedAt ?? loadedAt))", comment: "A pull request: Merged after 21 hours"))
        case .closed: parts.append(String(localized: "Closed after \(Self.duration(from: createdAt, to: endedAt ?? loadedAt))", comment: "A pull request: Closed after 3 days"))
        case .open: parts.append(String(localized: "Open for \(Self.duration(from: createdAt, to: Date()))", comment: "A pull request: Open for 5 hours"))
        }
        if let approval = events.first(where: { $0.kind == .approved }) {
            parts.append(String(localized: "approved after \(Self.duration(from: createdAt, to: approval.date))",
                                comment: "After a comma: Merged after 21 hours, approved after 20 hours"))
        }
        return parts.joined(separator: ", ")
    }

    /// "12 minutes", "5 hours", "3 days".
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        switch seconds {
        case ..<(90 * 60): return String(localized: "\(max(1, Int(seconds / 60))) minutes", comment: "A duration")
        case ..<(36 * 3600): return String(localized: "\(Int((seconds / 3600).rounded())) hours", comment: "A duration")
        default: return String(localized: "\(Int((seconds / 86_400).rounded())) days", comment: "A duration")
        }
    }
}

extension GitHubCLI {
    private static let timelineQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          createdAt state isDraft mergedAt closedAt
          author { login }
          commits(last: 100) { nodes { commit { committedDate } } }
          timelineItems(last: 100, itemTypes: [HEAD_REF_FORCE_PUSHED_EVENT, PULL_REQUEST_REVIEW, READY_FOR_REVIEW_EVENT, \
    CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT]) {
            nodes {
              __typename
              ... on HeadRefForcePushedEvent { createdAt actor { login } }
              ... on PullRequestReview { state submittedAt author { __typename login } }
              ... on ReadyForReviewEvent { createdAt actor { login } }
              ... on ConvertToDraftEvent { createdAt actor { login } }
              ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } }
              ... on MergedEvent { createdAt actor { login } }
              ... on ClosedEvent { createdAt actor { login } }
              ... on ReopenedEvent { createdAt actor { login } }
            }
          }
        }
      }
    }
    """

    /// One `gh api graphql` call for a pull request's timeline. `repository` is `owner/name`.
    static func timeline(repository: String, number: Int) async throws -> PullRequestTimeline {
        guard let gh = executableURL else {
            throw CommandError(command: "gh", status: 127, output: String(localized: "Install the GitHub CLI (brew install gh) and run `gh auth login` to see pull request timelines."))
        }
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw CommandError(command: "gh", status: 1, output: String(localized: "\(repository) isn't a GitHub repository.")) }
        let output = try await ProcessRunner.run(
            gh,
            ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)", "-f", "query=\(timelineQuery)"],
            environment: Git.environment, timeout: 30
        )
        return try await Task.detached(priority: .utility) {
            try decodeTimeline(output, number: number)
        }.value
    }

    private struct TimelineResponse: Decodable {
        struct Actor: Decodable {
            let login: String?
            let name: String?
            let kind: String?

            enum CodingKeys: String, CodingKey {
                case login, name
                case kind = "__typename"
            }
        }
        struct Item: Decodable {
            let kind: String
            let createdAt: Date?
            let submittedAt: Date?
            let state: String?
            let actor: Actor?
            let author: Actor?
            let requestedReviewer: Actor?

            enum CodingKeys: String, CodingKey {
                case kind = "__typename"
                case createdAt, submittedAt, state, actor, author, requestedReviewer
            }
        }
        struct Commit: Decodable {
            struct Inner: Decodable { let committedDate: Date }
            let commit: Inner
        }
        struct Nodes<Node: Decodable>: Decodable { let nodes: [Node?] }
        struct PullRequestData: Decodable {
            let createdAt: Date
            let state: String
            let isDraft: Bool
            let mergedAt: Date?
            let closedAt: Date?
            let author: Actor?
            let commits: Nodes<Commit>
            let timelineItems: Nodes<Item>
        }
        struct Repository: Decodable { let pullRequest: PullRequestData? }
        struct Payload: Decodable { let repository: Repository? }
        struct Problem: Decodable { let message: String }
        let data: Payload?
        let errors: [Problem]?
    }

    private static func decodeTimeline(_ data: Data, number: Int) throws -> PullRequestTimeline {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(TimelineResponse.self, from: data)
        guard let pullRequest = response.data?.repository?.pullRequest else {
            throw CommandError(command: "gh api", status: 1, output: response.errors?.first?.message ?? String(localized: "GitHub didn't return pull request #\(String(number))."))
        }
        let created = pullRequest.createdAt
        let items = pullRequest.timelineItems.nodes.compactMap { $0 }
        var events: [(date: Date, kind: PullRequestTimeline.Event.Kind, actor: String?)] = []

        // Opened as a draft when the first draft change made it ready (or it's still a draft).
        let firstDraftChange = items.first { $0.kind == "ReadyForReviewEvent" || $0.kind == "ConvertToDraftEvent" }
        let openedAsDraft = firstDraftChange.map { $0.kind == "ReadyForReviewEvent" } ?? pullRequest.isDraft

        // Commits made before it was opened came with it; later ones are grouped when they're
        // within ten minutes of each other, roughly one push each.
        let commitDates = pullRequest.commits.nodes.compactMap { $0?.commit.committedDate }.sorted()
        let initial = commitDates.filter { $0 <= created.addingTimeInterval(60) }.count
        events.append((created, .opened(commits: initial, draft: openedAsDraft), pullRequest.author?.login))
        var run: [Date] = []
        func endRun() {
            if let last = run.last { events.append((last, .commits(run.count), nil)) }
            run = []
        }
        for date in commitDates.dropFirst(initial) {
            if let last = run.last, date.timeIntervalSince(last) > 10 * 60 { endRun() }
            run.append(date)
        }
        endRun()

        let mergedAt = pullRequest.mergedAt
        for item in items {
            guard let date = item.createdAt ?? item.submittedAt else { continue }
            let actor = item.actor?.login ?? item.author?.login
            switch item.kind {
            case "PullRequestReview":
                switch item.state {
                case "APPROVED": events.append((date, .approved, actor))
                case "CHANGES_REQUESTED": events.append((date, .changesRequested, actor))
                // Bots comment on every pull request; their notes aren't part of its story.
                case "COMMENTED" where item.author?.kind != "Bot": events.append((date, .commented, actor))
                case "DISMISSED": events.append((date, .dismissed, actor))
                default: break
                }
            case "ReviewRequestedEvent":
                let reviewer = item.requestedReviewer?.login ?? item.requestedReviewer?.name ?? String(localized: "someone", comment: "A reviewer GitHub doesn't name")
                // Code owners are asked together; one line for all of them.
                if let last = events.last, case .reviewRequested(let names) = last.kind, date.timeIntervalSince(last.date) < 60 {
                    events[events.count - 1] = (last.date, .reviewRequested(names + [reviewer]), nil)
                } else {
                    events.append((date, .reviewRequested([reviewer]), nil))
                }
            case "HeadRefForcePushedEvent": events.append((date, .forcePushed, actor))
            case "ReadyForReviewEvent": events.append((date, .readyForReview, actor))
            case "ConvertToDraftEvent": events.append((date, .convertedToDraft, actor))
            case "MergedEvent": events.append((date, .merged, actor))
            case "ClosedEvent":
                // Merging closes it too.
                if let mergedAt, abs(date.timeIntervalSince(mergedAt)) < 10 { continue }
                events.append((date, .closed, actor))
            case "ReopenedEvent": events.append((date, .reopened, actor))
            default: break
            }
        }

        let state = PullRequest.State(rawValue: pullRequest.state) ?? .closed
        let ordered = events.enumerated().sorted { a, b in
            a.element.date == b.element.date ? a.offset < b.offset : a.element.date < b.element.date
        }
        return PullRequestTimeline(
            number: number, createdAt: created,
            endedAt: state == .merged ? mergedAt : (state == .closed ? pullRequest.closedAt : nil),
            state: state,
            events: ordered.enumerated().map { PullRequestTimeline.Event(id: $0.offset, date: $0.element.element.date,
                                                                         kind: $0.element.element.kind, actor: $0.element.element.actor) },
            loadedAt: Date()
        )
    }
}

/// `PullRequests/<repository>.json`: the last pull requests seen, so they show right away after a
/// relaunch while a fresh copy loads under the usual limits.
struct PullRequestCache: Codable, Sendable {
    let loadedAt: Date
    let pullRequests: [PullRequest]
    /// When the last full list (rather than only recently updated ones) was fetched.
    var fullAt: Date?

    private static func url(for repositoryID: UUID) -> URL {
        AppPaths.dataDirectory.appendingPathComponent("PullRequests", isDirectory: true)
            .appendingPathComponent("\(repositoryID.uuidString).json")
    }

    static func load(repositoryID: UUID) -> PullRequestCache? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(for: repositoryID)) else { return nil }
        return try? decoder.decode(PullRequestCache.self, from: data)
    }

    func save(repositoryID: UUID) {
        let url = Self.url(for: repositoryID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Lets one task through at a time, in the order they asked. `gh` refreshes of every repository go
/// through `GitHubCLI.gate`, so switching quickly between repositories never runs them in parallel.
@MainActor final class SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension GitHubCLI {
    @MainActor static let gate = SerialGate()
}

/// The commits pull requests bring: those on each one's branch that aren't on the branch it's
/// based on. When the base branch isn't in the graph, long-lived branches (develop, main…) stand in
/// for it. At most `limit` commits per pull request.
enum PullRequestCommits {
    static func commits(of pullRequests: [PullRequest], in graph: CommitGraph, limit: Int = 2_000) -> Set<ObjectID> {
        var result: Set<ObjectID> = []
        for pullRequest in pullRequests {
            guard let head = pullRequest.ref(in: graph) else { continue }
            var bases = graph.refs.filter { ref in
                ref.kind != .tag && (ref.kind == .local ? ref.name : ref.remoteParts?.branch) == pullRequest.base
            }
            if bases.isEmpty {
                bases = graph.refs.filter { ref in
                    guard ref.kind != .tag, let branch = ref.kind == .local ? ref.name : ref.remoteParts?.branch else { return false }
                    return PullRequestIndex.isLongLived(branch)
                }
            }
            var onBase = [Bool](repeating: false, count: graph.count)
            var stack = bases.map(\.commit)
            while let commit = stack.popLast() {
                guard commit >= 0, !onBase[Int(commit)] else { continue }
                onBase[Int(commit)] = true
                stack.append(contentsOf: graph.parents(commit))
            }
            var seen = Set<Int32>()
            var queue = [head.commit]
            var found = 0
            while let commit = queue.popLast(), found < limit {
                guard commit >= 0, !onBase[Int(commit)], seen.insert(commit).inserted else { continue }
                result.insert(graph.ids[Int(commit)])
                found += 1
                queue.append(contentsOf: graph.parents(commit))
            }
        }
        return result
    }
}
