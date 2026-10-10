import Foundation

/// Which commits mention each ticket (the first key in a subject), across the whole history.
/// Merges are left out; they repeat their branch's work.
struct TicketIndex: Sendable {
    /// Ticket key → commits that mention it, newest first.
    let commits: [String: [Int32]]

    init(graph: CommitGraph) {
        var commits: [String: [Int32]] = [:]
        if graph.ticketRegex != nil {
            for index in 0..<graph.count where !graph.isMerge(Int32(index)) {
                if let key = graph.ticketKey(in: graph.subjects[index]) {
                    commits[key, default: []].append(Int32(index))
                }
            }
        }
        self.commits = commits
    }

    /// The tickets below each ticket, as far as Jira has told: the sub-tasks of a story or task
    /// and the stories and tasks of an epic, for tickets mentioned in this history and the stories
    /// and tasks above them (which may have no commits of their own).
    @MainActor func children(connection: JiraConnection) -> [String: [String]] {
        let store = JiraStore.shared
        var children: [String: Set<String>] = [:]
        for key in commits.keys {
            guard let parent = store.issue(key, connection: connection)?.parent?.key else { continue }
            children[parent, default: []].insert(key)
            if let above = store.issue(parent, connection: connection)?.parent?.key {
                children[above, default: []].insert(parent)
            }
        }
        return children.mapValues { Array($0) }
    }
}

/// A ticket mentioned in the latest commits, and how many of them mention it.
struct RecentTicket: Identifiable, Sendable {
    let key: String
    var commits: Int
    /// Its newest commit's date.
    let latest: Date

    var id: String { key }

    /// Tickets in the latest `limit` commits of a layout (merges left out), newest first.
    static func find(in layout: GraphLayout, limit: Int) -> [RecentTicket] {
        let graph = layout.graph
        var order: [String] = []
        var found: [String: RecentTicket] = [:]
        var looked = 0
        for row in 0..<layout.rowCount where looked < limit {
            let commit = layout.rows[row]
            guard !graph.isMerge(commit) else { continue }
            looked += 1
            guard let key = graph.ticketKey(in: graph.subjects[Int(commit)]) else { continue }
            if found[key] == nil {
                order.append(key)
                found[key] = RecentTicket(key: key, commits: 0, latest: graph.date(of: commit))
            }
            found[key]?.commits += 1
        }
        return order.compactMap { found[$0] }
    }
}

/// Recent work grouped by Jira epic: the tickets in the latest commits, each under its epic (a
/// sub-task's epic is the one above its story or task). Epics that are live (in Jira's done
/// category, like Done or Released; a Definition of Done doesn't count) are left out with their
/// tickets, even ones that aren't live yet.
struct EpicReport: Sendable {
    struct Group: Identifiable, Sendable {
        /// The epic's key; empty for tickets without an epic.
        let id: String
        let epic: JiraLink?
        /// Newest first.
        let tickets: [RecentTicket]
        let commits: Int
        /// How far all of the epic's stories and tasks are, once Jira has listed them.
        var progress: TicketProgress?

        var latest: Date { tickets.first?.latest ?? .distantPast }
    }

    /// Epics by their latest commit, newest first; tickets without an epic last.
    let groups: [Group]
    /// Tickets whose epic isn't known yet.
    let pending: Int
    /// Tickets Jira doesn't know, or this account can't see.
    let notInJira: Int
    /// Epics left out because they're live.
    let liveEpics: Int
    let ticketCount: Int
    let commitLimit: Int

    @MainActor static func build(_ tickets: [RecentTicket], commitLimit: Int, connection: JiraConnection) -> EpicReport {
        let store = JiraStore.shared
        var epics: [String: JiraLink] = [:]
        var members: [String: [RecentTicket]] = [:]
        var order: [String] = []
        var pending = 0
        var notInJira = 0
        for ticket in tickets {
            let group: String
            switch store.epic(of: ticket.key, connection: connection) {
            case .epic(let epic):
                group = epic.key
                // The epic's own ticket, when it was read, is the freshest copy of its status.
                epics[epic.key] = epics[epic.key] ?? store.issue(epic.key, connection: connection)?.link ?? epic
            case .none:
                group = ""
            case .pending:
                pending += 1
                continue
            case .notInJira:
                notInJira += 1
                continue
            }
            // Tickets come newest first, so groups are ordered by their latest commit.
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(ticket)
        }
        let live = Set(epics.values.filter { $0.category == .done }.map(\.key))
        var groups = order.filter { !$0.isEmpty && !live.contains($0) }.map { key in
            Group(id: key, epic: epics[key], tickets: members[key] ?? [], commits: (members[key] ?? []).reduce(0) { $0 + $1.commits },
                  progress: store.cachedChildren(ofEpic: key, connection: connection).map { store.progress(of: $0, connection: connection) })
        }
        if let loose = members[""] {
            groups.append(Group(id: "", epic: nil, tickets: loose, commits: loose.reduce(0) { $0 + $1.commits }))
        }
        return EpicReport(groups: groups, pending: pending, notInJira: notInJira, liveEpics: live.count, ticketCount: tickets.count,
                          commitLimit: commitLimit)
    }
}

/// The unreleased fix versions of the repository's Jira projects: first those its tickets use,
/// then the others (another platform's, say).
struct ReleaseReport: Sendable {
    let used: [JiraVersion]
    let other: [JiraVersion]

    var all: [JiraVersion] { used + other }

    func version(id: String) -> JiraVersion? {
        all.first { $0.id == id }
    }

    @MainActor static func build(projects: [String], index: TicketIndex, connection: JiraConnection) -> ReleaseReport {
        let store = JiraStore.shared
        let versions = store.unreleasedVersions(projects: projects, connection: connection).map { version in
            // With a Definition of Done, its tickets are counted here once they're listed, since
            // Jira only counts by status category.
            guard store.hasDefinitionOfDone(project: version.project, connection: connection),
                  let keys = store.cachedTickets(inFixVersionID: version.id, connection: connection) else { return version }
            var counted = version
            counted.progress = store.progress(of: keys, connection: connection)
            return counted
        }
        guard !versions.isEmpty else { return ReleaseReport(used: [], other: []) }
        var names: Set<String> = []
        for key in index.commits.keys {
            if let issue = store.issue(key, connection: connection) { names.formUnion(issue.fixVersions) }
        }
        return ReleaseReport(used: versions.filter { names.contains($0.name) }, other: versions.filter { !names.contains($0.name) })
    }
}

/// A ticket listed under a fix version: what Jira says about it and the commits in this history
/// that mention it or its sub-tasks.
struct TicketSummary: Identifiable, Sendable {
    let key: String
    let issue: JiraIssue?
    let commits: Int
    let latest: Date?

    var id: String { key }

    /// Tickets with commits here first, newest first, then the rest by key, newest first.
    @MainActor static func list(_ keys: [String], index: TicketIndex, children: [String: [String]], graph: CommitGraph,
                                connection: JiraConnection) -> [TicketSummary] {
        keys.map { key in
            let mentioning = ([key] + (children[key] ?? [])).flatMap { index.commits[$0] ?? [] }
            // Commit indexes grow with age, so the smallest is the newest.
            return TicketSummary(key: key, issue: JiraStore.shared.issue(key, connection: connection), commits: mentioning.count,
                                 latest: mentioning.min().map { graph.date(of: $0) })
        }
        .sorted { a, b in
            switch (a.latest, b.latest) {
            case let (left?, right?): return left == right ? a.key.compare(b.key, options: .numeric) == .orderedDescending : left > right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.key.compare(b.key, options: .numeric) == .orderedDescending
            }
        }
    }
}
