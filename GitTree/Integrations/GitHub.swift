import Foundation

struct PullRequest: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    enum Checks: Sendable {
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
        if state == .open && isDraft { return "Draft" }
        switch state {
        case .open: return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    var reviewTitle: String? {
        switch reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
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
            case .ready: "Checks passed and approved"
            case .checksPassed: "Checks passed, waiting for approval"
            case .checksRunning: "Checks running"
            case .checksFailing: "Checks failed"
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
        while let parent = openByHead[root.base], !seen.contains(parent.number) {
            seen.insert(parent.number)
            root = parent
        }
        var ordered: [PullRequest] = []
        var visited: Set<Int> = []
        func walk(_ node: PullRequest) {
            guard visited.insert(node.number).inserted else { return }
            ordered.append(node)
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

    /// Two `gh` calls: the most recent pull requests in any state, then reviews and checks for the
    /// open ones. `repository` is `owner/name`.
    static func pullRequests(repository: String) async throws -> PullRequestIndex {
        guard let gh = executableURL else {
            throw CommandError(command: "gh", status: 127, output: "Install the GitHub CLI (brew install gh) and run `gh auth login` to see pull requests.")
        }
        let listed = try await ProcessRunner.run(
            gh,
            ["pr", "list", "--repo", repository, "--state", "all", "--limit", "400",
             "--json", "number,title,state,isDraft,headRefName,baseRefName,url,mergeCommit,author"],
            environment: Git.environment, timeout: 30
        )
        let open = try await ProcessRunner.run(
            gh,
            ["pr", "list", "--repo", repository, "--state", "open", "--limit", "200",
             "--json", "number,reviewDecision,statusCheckRollup"],
            environment: Git.environment, timeout: 30
        )
        return try await Task.detached(priority: .utility) {
            try decode(listed: listed, open: open)
        }.value
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

    private static func decode(listed: Data, open: Data) throws -> PullRequestIndex {
        let decoder = JSONDecoder()
        let details = Dictionary(
            try decoder.decode([OpenPullRequest].self, from: open).map { ($0.number, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pullRequests = try decoder.decode([ListedPullRequest].self, from: listed).map { item -> PullRequest in
            let detail = details[item.number]
            return PullRequest(
                number: item.number, title: item.title, state: PullRequest.State(rawValue: item.state) ?? .closed,
                isDraft: item.isDraft, head: item.headRefName, base: item.baseRefName, url: item.url,
                mergeCommit: item.mergeCommit.flatMap { ObjectID(hex: $0.oid) }, author: item.author?.login,
                reviewDecision: detail?.reviewDecision.flatMap { $0.isEmpty ? nil : $0 },
                checks: detail?.statusCheckRollup.flatMap(summarize)
            )
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
