import AppKit
import Foundation
import Observation

/// A ticket's status and details, as shown next to commits that mention it.
struct JiraIssue: Sendable, Hashable, Codable {
    enum Category: String, Sendable, Codable {
        case toDo = "new", inProgress = "indeterminate", done = "done", unknown
    }

    let key: String
    let summary: String
    let status: String
    let category: Category
    let type: String?
    let assignee: String?
    let fixVersions: [String]

    var color: NSColor {
        switch category {
        case .toDo, .unknown: .systemGray
        case .inProgress: .systemBlue
        case .done: .systemGreen
        }
    }
}

/// The Jira site GitTree talks to. The API token lives in the keychain, never in preferences.
struct JiraConnection: Sendable, Equatable {
    let baseURL: URL
    let email: String
    let token: String

    var host: String { baseURL.host ?? "" }

    func browseURL(_ key: String) -> URL {
        baseURL.appending(path: "browse/\(key)")
    }
}

enum JiraSettings {
    static let siteKey = "jiraSite"
    static let emailKey = "jiraEmail"
    static let keychainService = "GitTree Jira API token"

    /// `https://example.atlassian.net`, accepting a bare host too.
    static func normalizedSite(_ site: String) -> URL? {
        var text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static var connection: JiraConnection? {
        let defaults = UserDefaults.standard
        #if DEBUG
        // Test runs point GitTree at a local mock server with throwaway credentials.
        if let site = defaults.string(forKey: "GTJiraSite"), let url = normalizedSite(site) {
            return JiraConnection(baseURL: url, email: defaults.string(forKey: "GTJiraEmail") ?? "test@example.com",
                                  token: defaults.string(forKey: "GTJiraToken") ?? "test-token")
        }
        #endif
        guard let url = normalizedSite(defaults.string(forKey: siteKey) ?? ""),
              let email = defaults.string(forKey: emailKey)?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
              let host = url.host, let token = Keychain.password(service: keychainService, account: host), !token.isEmpty
        else { return nil }
        return JiraConnection(baseURL: url, email: email, token: token)
    }

    static func save(site: String, email: String, token: String?) {
        let defaults = UserDefaults.standard
        defaults.set(site.trimmingCharacters(in: .whitespacesAndNewlines), forKey: siteKey)
        defaults.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: emailKey)
        if let token, let host = normalizedSite(site)?.host {
            Keychain.setPassword(token, service: keychainService, account: host)
        }
        Task { @MainActor in JiraStore.shared.connectionChanged() }
    }

    /// Where a ticket key links: the repository's own issue link, or the configured Jira site.
    @MainActor static func issueURL(for key: String, in repository: Repository) -> URL? {
        repository.issueURL(for: key) ?? JiraStore.shared.configuredConnection.map { $0.browseURL(key) }
    }
}

/// `jira-cache.json`: statuses per Jira site, so relaunching doesn't ask Jira for everything again.
struct JiraCacheFile: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let issue: JiraIssue
        let fetchedAt: Date
    }

    struct Site: Codable, Sendable {
        var issues: [String: Entry] = [:]
        var unknown: [String: Date] = [:]
    }

    var sites: [String: Site] = [:]

    private static var url: URL { AppPaths.dataDirectory.appendingPathComponent("jira-cache.json") }

    /// Entries older than a month are dropped so the file stays small.
    static func load() -> JiraCacheFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var file = try? decoder.decode(JiraCacheFile.self, from: data) else {
            return JiraCacheFile()
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        file.sites = file.sites.mapValues { site in
            Site(issues: site.issues.filter { $0.value.fetchedAt > cutoff }, unknown: site.unknown.filter { $0.value > cutoff })
        }
        return file
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

enum JiraError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case badQuery
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Jira didn't accept the email and API token. Check them in Settings."
        case .rateLimited: "Jira asked GitTree to slow down."
        case .badQuery: "Jira couldn't find some of the tickets."
        case .server(let status): "Jira answered with an error (\(status))."
        }
    }
}

enum JiraClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    private static func request(_ connection: JiraConnection, path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: connection.baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let credentials = Data("\(connection.email):\(connection.token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw JiraError.server(0) }
        switch http.statusCode {
        case 200..<300: return
        case 400: throw JiraError.badQuery
        case 401, 403: throw JiraError.unauthorized
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw JiraError.rateLimited(retryAfter: wait)
        default: throw JiraError.server(http.statusCode)
        }
    }

    /// The signed-in user's name, to confirm the connection works.
    static func myself(_ connection: JiraConnection) async throws -> String {
        let (data, response) = try await session.data(for: request(connection, path: "rest/api/3/myself"))
        try check(response)
        struct Myself: Decodable { let displayName: String }
        return try JSONDecoder().decode(Myself.self, from: data).displayName
    }

    private static let fields = ["summary", "status", "issuetype", "assignee", "fixVersions"]

    /// Bulk fetch: up to 100 keys in one request; keys that don't exist are simply left out instead
    /// of failing the whole request. Returns nil when the site doesn't offer it (then use `search`).
    static func bulkFetch(_ keys: [String], connection: JiraConnection) async throws -> [JiraIssue]? {
        let body: [String: Any] = ["issueIdsOrKeys": keys, "fields": fields]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (response, urlResponse) = try await session.data(for: request(connection, path: "rest/api/3/issue/bulkfetch", method: "POST", body: data))
        if (urlResponse as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(urlResponse)
        return try decode(response)
    }

    /// JQL search; one unknown key makes Jira reject the whole query.
    static func search(_ keys: [String], connection: JiraConnection) async throws -> [JiraIssue] {
        let body: [String: Any] = [
            "jql": "key in (\(keys.joined(separator: ",")))",
            "fields": fields,
            "maxResults": keys.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (response, urlResponse) = try await session.data(for: request(connection, path: "rest/api/3/search/jql", method: "POST", body: data))
        try check(urlResponse)
        return try decode(response)
    }

    /// The tickets in a fix version, a page of 100 at a time, at most `limit` (a handful of requests).
    static func issues(inFixVersion version: String, connection: JiraConnection, limit: Int = 500) async throws -> [JiraIssue] {
        var collected: [JiraIssue] = []
        var pageToken: String?
        let escaped = version.replacingOccurrences(of: "\"", with: "\\\"")
        repeat {
            var body: [String: Any] = [
                "jql": "fixVersion = \"\(escaped)\" ORDER BY key DESC",
                "fields": fields,
                "maxResults": 100,
            ]
            if let pageToken { body["nextPageToken"] = pageToken }
            let data = try JSONSerialization.data(withJSONObject: body)
            let (response, urlResponse) = try await session.data(for: request(connection, path: "rest/api/3/search/jql", method: "POST", body: data))
            try check(urlResponse)
            collected += try decode(response)
            pageToken = (try? JSONDecoder().decode(PageInfo.self, from: response))?.nextPageToken
        } while pageToken != nil && collected.count < limit
        return collected
    }

    private struct PageInfo: Decodable {
        let nextPageToken: String?
    }

    private struct SearchResponse: Decodable {
        struct Issue: Decodable {
            struct Fields: Decodable {
                struct Status: Decodable {
                    struct Category: Decodable { let key: String }
                    let name: String
                    let statusCategory: Category?
                }
                struct Named: Decodable { let name: String }
                struct Person: Decodable { let displayName: String }
                let summary: String?
                let status: Status?
                let issuetype: Named?
                let assignee: Person?
                let fixVersions: [Named]?
            }
            let key: String
            let fields: Fields
        }
        let issues: [Issue]
    }

    private static func decode(_ data: Data) throws -> [JiraIssue] {
        try JSONDecoder().decode(SearchResponse.self, from: data).issues.map { issue in
            JiraIssue(
                key: issue.key,
                summary: issue.fields.summary ?? "",
                status: issue.fields.status?.name ?? "Unknown",
                category: issue.fields.status?.statusCategory.flatMap { JiraIssue.Category(rawValue: $0.key) } ?? .unknown,
                type: issue.fields.issuetype?.name,
                assignee: issue.fields.assignee?.displayName,
                fixVersions: issue.fields.fixVersions?.map(\.name) ?? []
            )
        }
    }
}

/// Ticket statuses for the whole app, fetched politely: only keys that aren't cached, in batches of
/// up to 50, one request at a time, after a short pause so scrolling doesn't fire requests, at most
/// 20 requests a minute, backing off on errors and stopping entirely on bad credentials.
@MainActor @Observable final class JiraStore {
    static let shared = JiraStore()

    /// Increments when statuses arrive, so visible rows redraw.
    private(set) var version = 0
    private(set) var problem: String?

    @ObservationIgnored private var issues: [String: (issue: JiraIssue, fetchedAt: Date)] = [:]
    @ObservationIgnored private var unknown: [String: Date] = [:]
    /// Statuses survive relaunches: everything is saved per Jira site in Application Support.
    @ObservationIgnored private var cacheFile = JiraCacheFile.load()
    @ObservationIgnored private var cacheHost: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pausedUntil: Date?
    @ObservationIgnored private var backoff: TimeInterval = 30
    @ObservationIgnored private var recentRequests: [Date] = []
    @ObservationIgnored private var unauthorized = false
    @ObservationIgnored private var connection: JiraConnection?
    /// Sites without the bulk-fetch endpoint; they get JQL search instead.
    @ObservationIgnored private var searchOnlySites: Set<String> = []

    /// A cached status is shown right away and asked for again only after an hour, when on screen.
    private static let freshFor: TimeInterval = 60 * 60
    /// Keys Jira doesn't know are not asked about again for a day.
    private static let missingFor: TimeInterval = 24 * 60 * 60
    private static let batchSize = 50
    private static let requestsPerMinute = 20

    @ObservationIgnored private var cachedConnection: JiraConnection??

    func issue(_ key: String) -> JiraIssue? {
        loadCacheForConfiguredSite()
        return issues[key]?.issue
    }

    /// Jira answered without this key: it doesn't exist or isn't visible to this account.
    func isMissing(_ key: String) -> Bool {
        loadCacheForConfiguredSite()
        return unknown[key] != nil && issues[key] == nil
    }

    /// Repository › Refresh Ticket Statuses: keeps showing what's cached, but asks Jira again for
    /// the tickets on screen.
    /// Fix versions seen in cached tickets, newest first ("2.12", "2.11"…).
    var knownFixVersions: [String] {
        loadCacheForConfiguredSite()
        let versions = Set(issues.values.flatMap(\.issue.fixVersions))
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Makes sure these tickets' statuses are known, through the usual queue (batched, paced,
    /// cached), and waits up to 30 seconds for them.
    func ensure(_ keys: [String], connection: JiraConnection) async {
        request(keys, connection: connection)
        for _ in 0..<100 {
            if keys.allSatisfy({ !queued.contains($0) && !inFlightKeys.contains($0) }) { return }
            if unauthorized { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The tickets in a fix version, asked of Jira directly (a few requests) and cached like the rest.
    func issues(inFixVersion fixVersion: String, connection: JiraConnection) async throws -> [JiraIssue] {
        useCache(for: connection.host)
        recentRequests.append(Date())
        let found = try await JiraClient.issues(inFixVersion: fixVersion, connection: connection)
        let now = Date()
        for issue in found { issues[issue.key] = (issue, now) }
        version += 1
        scheduleSave()
        return found
    }

    func markAllStale() {
        for key in issues.keys { issues[key]?.fetchedAt = .distantPast }
        unknown = [:]
        version += 1
    }

    // MARK: Cache on disk

    private func loadCacheForConfiguredSite() {
        if cacheHost == nil, let host = configuredConnection?.host { useCache(for: host) }
    }

    private func useCache(for host: String) {
        guard host != cacheHost else { return }
        storeCurrentSite()
        cacheHost = host
        let site = cacheFile.sites[host] ?? JiraCacheFile.Site()
        issues = site.issues.mapValues { ($0.issue, $0.fetchedAt) }
        unknown = site.unknown
    }

    private func storeCurrentSite() {
        guard let host = cacheHost else { return }
        cacheFile.sites[host] = JiraCacheFile.Site(
            issues: issues.mapValues { JiraCacheFile.Entry(issue: $0.issue, fetchedAt: $0.fetchedAt) },
            unknown: unknown
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.storeCurrentSite()
            let file = self.cacheFile
            await Task.detached(priority: .utility) { file.save() }.value
        }
    }

    /// The configured connection, read from preferences and the keychain once until settings change.
    var configuredConnection: JiraConnection? {
        if let cachedConnection { return cachedConnection }
        let connection = JiraSettings.connection
        cachedConnection = .some(connection)
        return connection
    }

    func connection(for repository: Repository) -> JiraConnection? {
        guard let connection = configuredConnection else { return nil }
        guard let template = repository.issueURLTemplate?.trimmingCharacters(in: .whitespaces), !template.isEmpty else {
            return connection
        }
        return URL(string: template.replacingOccurrences(of: "{key}", with: "KEY-1"))?.host == connection.host ? connection : nil
    }

    /// Asks for these keys' statuses; cached, queued and known-missing keys are skipped.
    func request(_ keys: [String], connection: JiraConnection) {
        if self.connection != connection {
            self.connection = connection
            unauthorized = false
            problem = nil
        }
        guard !unauthorized else { return }
        useCache(for: connection.host)
        let now = Date()
        for key in keys where !queued.contains(key) && !inFlightKeys.contains(key) {
            if let cached = issues[key], now.timeIntervalSince(cached.fetchedAt) < Self.freshFor { continue }
            if let missing = unknown[key], now.timeIntervalSince(missing) < Self.missingFor { continue }
            queue.append(key)
            queued.insert(key)
        }
        scheduleFlush(after: 0.6)
    }

    func connectionChanged() {
        cachedConnection = nil
        // Statuses stay cached per site; a different account may see tickets this one couldn't.
        unknown = [:]
        unauthorized = false
        problem = nil
        pausedUntil = nil
        backoff = 30
        connection = nil
        version += 1
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard !queue.isEmpty, !inFlight, flushTask == nil else { return }
        var wait = delay
        if let pausedUntil { wait = max(wait, pausedUntil.timeIntervalSinceNow) }
        let minuteAgo = Date().addingTimeInterval(-60)
        recentRequests.removeAll { $0 < minuteAgo }
        if recentRequests.count >= Self.requestsPerMinute, let oldest = recentRequests.first {
            wait = max(wait, oldest.timeIntervalSinceNow + 60)
        }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        guard !inFlight, !unauthorized, let connection, !queue.isEmpty else { return }
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)
        batch.forEach { queued.remove($0) }
        inFlightKeys.formUnion(batch)
        inFlight = true
        await fetch(batch, connection: connection, depth: 0)
        inFlightKeys.subtract(batch)
        inFlight = false
        version += 1
        scheduleSave()
        scheduleFlush(after: 1)
    }

    /// One request with bulk fetch, which skips unknown keys. Sites without it fall back to JQL
    /// search, where an unknown key fails the query and the batch is split (at most six levels deep)
    /// to find it. Unknown keys are remembered so they're not asked for again soon.
    private func fetch(_ keys: [String], connection: JiraConnection, depth: Int) async {
        recentRequests.append(Date())
        do {
            var found: [JiraIssue]?
            if !searchOnlySites.contains(connection.host) {
                found = try await JiraClient.bulkFetch(keys, connection: connection)
                if found == nil { searchOnlySites.insert(connection.host) }
            }
            if found == nil {
                found = try await JiraClient.search(keys, connection: connection)
            }
            let received = found ?? []
            let now = Date()
            for issue in received { issues[issue.key] = (issue, now) }
            let foundKeys = Set(received.map(\.key))
            for key in keys where !foundKeys.contains(key) { unknown[key] = now }
            problem = nil
            backoff = 30
        } catch JiraError.badQuery {
            guard keys.count > 1, depth < 6 else {
                keys.forEach { unknown[$0] = Date() }
                return
            }
            let half = keys.count / 2
            await fetch(Array(keys[..<half]), connection: connection, depth: depth + 1)
            await fetch(Array(keys[half...]), connection: connection, depth: depth + 1)
        } catch JiraError.unauthorized {
            unauthorized = true
            problem = JiraError.unauthorized.localizedDescription
            queue.removeAll()
            queued.removeAll()
        } catch JiraError.rateLimited(let retryAfter) {
            pause(for: retryAfter, putBack: keys)
        } catch {
            problem = error.localizedDescription
            pause(for: backoff, putBack: keys)
            backoff = min(backoff * 2, 15 * 60)
        }
    }

    private func pause(for seconds: TimeInterval, putBack keys: [String]) {
        pausedUntil = Date().addingTimeInterval(seconds)
        for key in keys where !queued.contains(key) {
            queue.append(key)
            queued.insert(key)
        }
    }
}
