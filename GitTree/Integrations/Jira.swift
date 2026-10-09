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

/// A Jira site and the account GitTree uses there, ready for requests.
struct JiraConnection: Sendable, Hashable {
    let profileID: UUID
    let baseURL: URL
    let email: String
    let token: String

    var host: String { baseURL.host ?? "" }

    func browseURL(_ key: String) -> URL {
        baseURL.appending(path: "browse/\(key)")
    }
}

/// A Jira site and account set up in Settings › Jira. Each repository picks one, or none. The API
/// token lives in the keychain, never in preferences.
struct JiraProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var site: String
    var email: String

    var baseURL: URL? { JiraProfiles.normalizedSite(site) }
    var host: String? { baseURL?.host }
}

/// Where profiles are kept: `jira-profiles.json` in Application Support for the list and the
/// default for new repositories, the keychain (under each profile's id) for API tokens.
enum JiraProfiles {
    struct Saved: Codable {
        var profiles: [JiraProfile] = []
        var defaultProfileID: UUID?
    }

    /// Set once the single Jira connection of earlier versions became a profile, until repositories
    /// that used it are assigned to it.
    static let pendingAssignmentKey = "jiraProfileToAssign"
    static let keychainService = "GitTree Jira API token"

    private static var url: URL { AppPaths.dataDirectory.appendingPathComponent("jira-profiles.json") }

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

    static func load() -> Saved {
        if let data = try? Data(contentsOf: url) {
            return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
        }
        return migrateLegacySettings()
    }

    static func save(_ saved: Saved) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func token(for id: UUID) -> String? {
        #if DEBUG
        if let tokens = testTokens { return tokens[id.uuidString].flatMap { $0.isEmpty ? nil : $0 } }
        #endif
        return Keychain.password(service: keychainService, account: id.uuidString).flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func setToken(_ token: String, for id: UUID) -> Bool {
        #if DEBUG
        if var tokens = testTokens {
            tokens[id.uuidString] = token.isEmpty ? nil : token
            try? JSONEncoder().encode(tokens).write(to: testTokensURL, options: .atomic)
            return true
        }
        #endif
        return Keychain.setPassword(token, service: keychainService, account: id.uuidString)
    }

    #if DEBUG
    /// Test runs (`-GTDataDirectory`) keep tokens in their throwaway folder, never in the keychain.
    private static var testTokensURL: URL { AppPaths.dataDirectory.appendingPathComponent("test-tokens.json") }

    private static var testTokens: [String: String]? {
        guard UserDefaults.standard.string(forKey: "GTDataDirectory") != nil else { return nil }
        guard let data = try? Data(contentsOf: testTokensURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    #endif

    /// Earlier versions had one Jira connection (site and email in preferences, the token in the
    /// keychain under the site's host). It becomes the first profile, the default for new
    /// repositories, and is assigned to the repositories that used it (see `RepositoryLibrary`).
    private static func migrateLegacySettings() -> Saved {
        let defaults = UserDefaults.standard
        guard let site = defaults.string(forKey: "jiraSite"), let url = normalizedSite(site), let host = url.host else {
            save(Saved())
            return Saved()
        }
        let email = defaults.string(forKey: "jiraEmail")?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = host.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? host
        let profile = JiraProfile(id: UUID(), name: name, site: site, email: email)
        if let token = Keychain.password(service: keychainService, account: host), !token.isEmpty,
           setToken(token, for: profile.id) {
            Keychain.setPassword("", service: keychainService, account: host)
        }
        let saved = Saved(profiles: [profile], defaultProfileID: profile.id)
        save(saved)
        defaults.set(profile.id.uuidString, forKey: pendingAssignmentKey)
        defaults.removeObject(forKey: "jiraSite")
        defaults.removeObject(forKey: "jiraEmail")
        return saved
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
/// up to 50, one request at a time across every Jira site, after a short pause so scrolling doesn't
/// fire requests, at most 20 requests a minute, backing off on errors, and stopping for a profile
/// whose credentials Jira rejects.
@MainActor @Observable final class JiraStore {
    static let shared = JiraStore()

    /// Increments when statuses arrive, so visible rows redraw.
    private(set) var version = 0
    /// The Jira sites and accounts set up in Settings.
    private(set) var profiles: [JiraProfile]
    /// Why a profile's requests failed or stopped.
    private(set) var problems: [UUID: String] = [:]

    /// The profile new repositories start with.
    var defaultProfileID: UUID? {
        didSet { saveProfiles() }
    }

    private struct SiteCache {
        var issues: [String: (issue: JiraIssue, fetchedAt: Date)] = [:]
        var unknown: [String: Date] = [:]
    }

    private struct Pending {
        let key: String
        let connection: JiraConnection
    }

    /// Statuses per Jira host. They survive relaunches in `jira-cache.json`.
    @ObservationIgnored private var sites: [String: SiteCache] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Pending] = []
    /// `host key` of everything queued or being fetched.
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pausedUntil: Date?
    @ObservationIgnored private var backoff: TimeInterval = 30
    @ObservationIgnored private var recentRequests: [Date] = []
    @ObservationIgnored private var unauthorized: Set<UUID> = []
    /// Sites without the bulk-fetch endpoint; they get JQL search instead.
    @ObservationIgnored private var searchOnlySites: Set<String> = []
    /// Connections built from profiles, so the keychain is read once per profile.
    @ObservationIgnored private var connections: [UUID: JiraConnection?] = [:]
    /// Tickets of recently asked fix versions, and the requests under way, so asking again soon
    /// doesn't go back to Jira.
    @ObservationIgnored private var fixVersionResults: [String: (keys: [String], fetchedAt: Date)] = [:]
    @ObservationIgnored private var fixVersionRequests: [String: Task<[JiraIssue], Error>] = [:]

    /// A cached status is shown right away and asked for again only after an hour, when on screen.
    private static let freshFor: TimeInterval = 60 * 60
    /// Keys Jira doesn't know are not asked about again for a day.
    private static let missingFor: TimeInterval = 24 * 60 * 60
    private static let fixVersionFreshFor: TimeInterval = 10 * 60
    private static let batchSize = 50
    private static let requestsPerMinute = 20

    private init() {
        let saved = JiraProfiles.load()
        profiles = saved.profiles
        defaultProfileID = saved.defaultProfileID
        sites = JiraCacheFile.load().sites.mapValues { site in
            SiteCache(issues: site.issues.mapValues { ($0.issue, $0.fetchedAt) }, unknown: site.unknown)
        }
    }

    private static func id(_ host: String, _ key: String) -> String { "\(host) \(key)" }

    // MARK: Profiles

    func profile(id: UUID?) -> JiraProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The Jira a repository's tickets live in, or nil when it has none (or its profile is incomplete).
    func connection(for repository: Repository) -> JiraConnection? {
        #if DEBUG
        if let mock = Self.mockConnection { return mock }
        #endif
        return profile(id: repository.jiraProfileID).flatMap(connection(for:))
    }

    func connection(for profile: JiraProfile) -> JiraConnection? {
        if let cached = connections[profile.id] { return cached }
        var connection: JiraConnection?
        if let url = profile.baseURL, !profile.email.trimmingCharacters(in: .whitespaces).isEmpty,
           let token = JiraProfiles.token(for: profile.id) {
            connection = JiraConnection(profileID: profile.id, baseURL: url, email: profile.email.trimmingCharacters(in: .whitespaces), token: token)
        }
        connections[profile.id] = .some(connection)
        return connection
    }

    /// Adds or updates a profile. A non-empty token replaces the saved one.
    func save(_ profile: JiraProfile, token: String?) {
        var saved = profile
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.site = saved.site.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.email = saved.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty { JiraProfiles.setToken(token, for: saved.id) }
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
            profiles[index] = saved
        } else {
            profiles.append(saved)
        }
        saveProfiles()
        profilesChanged()
    }

    /// Removes a profile and its token. Repositories that used it have no Jira until another is picked.
    func remove(profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        JiraProfiles.setToken("", for: profileID)
        if defaultProfileID == profileID { defaultProfileID = nil }
        saveProfiles()
        profilesChanged()
    }

    private func saveProfiles() {
        JiraProfiles.save(JiraProfiles.Saved(profiles: profiles, defaultProfileID: defaultProfileID))
    }

    /// Credentials changed: forget rejected accounts and unknown tickets (another account may see
    /// them), and drop queued requests made with the old credentials.
    private func profilesChanged() {
        connections = [:]
        unauthorized = []
        problems = [:]
        pausedUntil = nil
        backoff = 30
        sites = sites.mapValues { SiteCache(issues: $0.issues, unknown: [:]) }
        queue.removeAll()
        queued.removeAll()
        fixVersionResults = [:]
        version += 1
    }

    func problem(for connection: JiraConnection?) -> String? {
        connection.flatMap { problems[$0.profileID] }
    }

    #if DEBUG
    /// Test runs point every repository at a local mock server with throwaway credentials:
    /// `-GTJiraSite http://127.0.0.1:8899`.
    private static let mockConnection: JiraConnection? = {
        let defaults = UserDefaults.standard
        guard let site = defaults.string(forKey: "GTJiraSite"), let url = JiraProfiles.normalizedSite(site) else { return nil }
        return JiraConnection(profileID: UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!, baseURL: url,
                              email: defaults.string(forKey: "GTJiraEmail") ?? "test@example.com",
                              token: defaults.string(forKey: "GTJiraToken") ?? "test-token")
    }()
    #endif

    // MARK: Statuses

    func issue(_ key: String, connection: JiraConnection) -> JiraIssue? {
        sites[connection.host]?.issues[key]?.issue
    }

    /// Jira answered without this key: it doesn't exist or isn't visible to this account.
    func isMissing(_ key: String, connection: JiraConnection) -> Bool {
        guard let site = sites[connection.host] else { return false }
        return site.unknown[key] != nil && site.issues[key] == nil
    }

    /// Fix versions seen in a site's cached tickets, newest first ("2.12", "2.11"…).
    func knownFixVersions(for connection: JiraConnection) -> [String] {
        guard let issues = sites[connection.host]?.issues else { return [] }
        let versions = Set(issues.values.flatMap(\.issue.fixVersions))
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// Makes sure these tickets' statuses are known, through the usual queue (batched, paced,
    /// cached), and waits up to 30 seconds for them.
    func ensure(_ keys: [String], connection: JiraConnection) async {
        request(keys, connection: connection)
        let ids = keys.map { Self.id(connection.host, $0) }
        for _ in 0..<100 {
            if ids.allSatisfy({ !queued.contains($0) && !inFlightKeys.contains($0) }) { return }
            if unauthorized.contains(connection.profileID) { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The tickets in a fix version, asked of Jira directly (a few requests) and cached like the
    /// rest. Asking for the same version again within ten minutes, or while it's loading, doesn't
    /// send another request.
    func issues(inFixVersion fixVersion: String, connection: JiraConnection) async throws -> [JiraIssue] {
        let id = Self.id(connection.host, fixVersion)
        if let result = fixVersionResults[id], Date().timeIntervalSince(result.fetchedAt) < Self.fixVersionFreshFor {
            let cached = result.keys.compactMap { issue($0, connection: connection) }
            if cached.count == result.keys.count { return cached }
        }
        if let running = fixVersionRequests[id] { return try await running.value }
        let request = Task { try await JiraClient.issues(inFixVersion: fixVersion, connection: connection) }
        fixVersionRequests[id] = request
        recentRequests.append(Date())
        defer { fixVersionRequests[id] = nil }
        let found = try await request.value
        let now = Date()
        for issue in found { sites[connection.host, default: SiteCache()].issues[issue.key] = (issue, now) }
        fixVersionResults[id] = (found.map(\.key), now)
        version += 1
        scheduleSave()
        return found
    }

    /// Repository › Refresh Ticket Statuses: keeps showing what's cached, but asks Jira again for
    /// the tickets on screen.
    func markAllStale() {
        sites = sites.mapValues { site in
            SiteCache(issues: site.issues.mapValues { ($0.issue, Date.distantPast) }, unknown: [:])
        }
        fixVersionResults = [:]
        version += 1
    }

    /// Asks for these keys' statuses; cached, queued and known-missing keys are skipped.
    func request(_ keys: [String], connection: JiraConnection) {
        guard !unauthorized.contains(connection.profileID) else { return }
        let now = Date()
        let site = sites[connection.host]
        for key in keys {
            let id = Self.id(connection.host, key)
            guard !queued.contains(id), !inFlightKeys.contains(id) else { continue }
            if let cached = site?.issues[key], now.timeIntervalSince(cached.fetchedAt) < Self.freshFor { continue }
            if let missing = site?.unknown[key], now.timeIntervalSince(missing) < Self.missingFor { continue }
            queue.append(Pending(key: key, connection: connection))
            queued.insert(id)
        }
        scheduleFlush(after: 0.6)
    }

    // MARK: Requests

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

    /// Sends one batch: up to 50 queued keys of the same Jira site and account.
    private func flush() async {
        guard !inFlight, let connection = queue.first?.connection else { return }
        var batch: [String] = []
        var rest: [Pending] = []
        for pending in queue {
            if pending.connection == connection && batch.count < Self.batchSize {
                batch.append(pending.key)
            } else {
                rest.append(pending)
            }
        }
        queue = rest
        let ids = batch.map { Self.id(connection.host, $0) }
        ids.forEach { queued.remove($0) }
        inFlightKeys.formUnion(ids)
        inFlight = true
        await fetch(batch, connection: connection, depth: 0)
        inFlightKeys.subtract(ids)
        inFlight = false
        version += 1
        scheduleSave()
        scheduleFlush(after: 1)
    }

    /// One request with bulk fetch, which skips unknown keys. Sites without it fall back to JQL
    /// search, where an unknown key fails the query and the batch is split (at most six levels deep)
    /// to find it. Unknown keys are remembered so they're not asked for again soon.
    private func fetch(_ keys: [String], connection: JiraConnection, depth: Int) async {
        let host = connection.host
        recentRequests.append(Date())
        do {
            var found: [JiraIssue]?
            if !searchOnlySites.contains(host) {
                found = try await JiraClient.bulkFetch(keys, connection: connection)
                if found == nil { searchOnlySites.insert(host) }
            }
            if found == nil {
                found = try await JiraClient.search(keys, connection: connection)
            }
            let received = found ?? []
            let now = Date()
            for issue in received { sites[host, default: SiteCache()].issues[issue.key] = (issue, now) }
            let foundKeys = Set(received.map(\.key))
            for key in keys where !foundKeys.contains(key) { sites[host, default: SiteCache()].unknown[key] = now }
            problems[connection.profileID] = nil
            backoff = 30
        } catch JiraError.badQuery {
            guard keys.count > 1, depth < 6 else {
                let now = Date()
                for key in keys { sites[host, default: SiteCache()].unknown[key] = now }
                return
            }
            let half = keys.count / 2
            await fetch(Array(keys[..<half]), connection: connection, depth: depth + 1)
            await fetch(Array(keys[half...]), connection: connection, depth: depth + 1)
        } catch JiraError.unauthorized {
            unauthorized.insert(connection.profileID)
            problems[connection.profileID] = JiraError.unauthorized.localizedDescription
            for pending in queue where pending.connection.profileID == connection.profileID {
                queued.remove(Self.id(pending.connection.host, pending.key))
            }
            queue.removeAll { $0.connection.profileID == connection.profileID }
        } catch JiraError.rateLimited(let retryAfter) {
            pause(for: retryAfter, putBack: keys, connection: connection)
        } catch {
            problems[connection.profileID] = error.localizedDescription
            pause(for: backoff, putBack: keys, connection: connection)
            backoff = min(backoff * 2, 15 * 60)
        }
    }

    private func pause(for seconds: TimeInterval, putBack keys: [String], connection: JiraConnection) {
        pausedUntil = Date().addingTimeInterval(seconds)
        for key in keys {
            let id = Self.id(connection.host, key)
            guard !queued.contains(id) else { continue }
            queue.append(Pending(key: key, connection: connection))
            queued.insert(id)
        }
    }

    // MARK: Cache on disk

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            var file = JiraCacheFile()
            for (host, site) in self.sites {
                file.sites[host] = JiraCacheFile.Site(
                    issues: site.issues.mapValues { JiraCacheFile.Entry(issue: $0.issue, fetchedAt: $0.fetchedAt) },
                    unknown: site.unknown
                )
            }
            await Task.detached(priority: .utility) { file.save() }.value
        }
    }
}
