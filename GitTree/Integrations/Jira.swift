import AppKit
import Foundation
import Observation

/// A ticket's status and details, as shown next to commits that mention it.
struct JiraIssue: Sendable, Hashable, Codable {
    enum Category: String, Sendable, Codable {
        case toDo = "new", inProgress = "indeterminate", done = "done", unknown

        var color: NSColor {
            switch self {
            case .toDo, .unknown: .systemGray
            case .inProgress: .systemBlue
            case .done: .systemGreen
            }
        }
    }

    let key: String
    let summary: String
    let status: String
    let category: Category
    let type: String?
    let assignee: String?
    let fixVersions: [String]
    /// Where its type sits in Jira's hierarchy: 1 for epics, 0 for stories, tasks and bugs, -1 for
    /// sub-tasks. Nil for tickets cached before GitTree read parents; those are asked for again.
    var level: Int?
    /// The ticket it belongs to: its epic, or for a sub-task the story or task above it.
    var parent: JiraLink?

    var color: NSColor { category.color }

    /// Read together with its parent, so its epic is known (or known to be none).
    var knowsParent: Bool { level != nil }

    var isEpic: Bool { (level ?? 0) >= 1 }

    /// The ticket as a link, standing for its own epic when it is one.
    var link: JiraLink {
        JiraLink(key: key, summary: summary, status: status, category: category, type: type, level: level ?? 0)
    }
}

/// A ticket another one points to (its parent), with what Jira includes about it.
struct JiraLink: Sendable, Hashable, Codable {
    let key: String
    let summary: String
    let status: String
    let category: JiraIssue.Category
    let type: String?
    /// 1 for epics, 0 for stories and tasks.
    let level: Int

    var isEpic: Bool { level >= 1 }
    var color: NSColor { category.color }
}

/// Where a ticket's epic stands: found, none, still loading, or the ticket isn't in Jira.
enum EpicLookup: Hashable, Sendable {
    case epic(JiraLink)
    case none
    case pending
    case notInJira
}

/// An unreleased fix version of a Jira project: a release the team is working toward.
struct JiraVersion: Sendable, Hashable, Codable, Identifiable {
    /// How many of its tickets are in each status category.
    struct Progress: Sendable, Hashable, Codable {
        let toDo: Int
        let inProgress: Int
        let done: Int

        var total: Int { toDo + inProgress + done }
    }

    let id: String
    let name: String
    /// The project it belongs to, like PROJ.
    let project: String
    let details: String?
    /// `2026-10-13`, as Jira writes it.
    let releaseDate: String?
    let overdue: Bool
    let progress: Progress?

    /// The release date as a day in the local calendar.
    var releaseDay: Date? {
        let parts = releaseDate?.split(separator: "-").compactMap { Int($0) } ?? []
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Soonest release date first, then versions without a date, by name.
    static func soonestFirst(_ a: JiraVersion, _ b: JiraVersion) -> Bool {
        switch (a.releaseDate, b.releaseDate) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// The JQL behind the ticket lists GitTree asks Jira for.
enum JiraQuery {
    static func fixVersion(id: String) -> String {
        "fixVersion = \(id) ORDER BY key DESC"
    }

    static func fixVersion(named name: String) -> String {
        "fixVersion = \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\" ORDER BY key DESC"
    }

    /// An epic, its tickets and their sub-tasks.
    static func epic(_ key: String) -> String {
        "parentEpic = \(key) ORDER BY key DESC"
    }

    /// For sites without `parentEpic`: tickets whose parent is one of these.
    static func children(of keys: [String]) -> String {
        "parent in (\(keys.joined(separator: ","))) ORDER BY key DESC"
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

    /// A fix version's page in Jira.
    func versionURL(_ version: JiraVersion) -> URL {
        baseURL.appending(path: "projects/\(version.project)/versions/\(version.id)")
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
        #if DEBUG
        // Test runs use a throwaway data folder; the real settings and keychain stay untouched.
        if defaults.string(forKey: "GTDataDirectory") != nil {
            save(Saved())
            return Saved()
        }
        #endif
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

/// `jira-cache.json`: statuses and unreleased fix versions per Jira profile, so relaunching doesn't
/// ask Jira for everything again.
struct JiraCacheFile: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let issue: JiraIssue
        let fetchedAt: Date
    }

    struct VersionList: Codable, Sendable {
        let versions: [JiraVersion]
        let fetchedAt: Date
    }

    struct Site: Codable, Sendable {
        var issues: [String: Entry] = [:]
        var unknown: [String: Date] = [:]
        /// Unreleased fix versions by project key.
        var versions: [String: VersionList]?
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
            Site(issues: site.issues.filter { $0.value.fetchedAt > cutoff }, unknown: site.unknown.filter { $0.value > cutoff },
                 versions: site.versions?.filter { $0.value.fetchedAt > cutoff })
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

    private static func request(_ connection: JiraConnection, path: String, query: [URLQueryItem] = [], method: String = "GET",
                                body: Data? = nil) -> URLRequest {
        var url = connection.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
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

    /// `parent` brings the epic (or, for a sub-task, its story or task) along with each ticket.
    private static let fields = ["summary", "status", "issuetype", "assignee", "fixVersions", "parent"]

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

    /// One page (up to 100 tickets) of a JQL query, and the token for the next page when there is one.
    static func searchPage(_ jql: String, pageToken: String?, connection: JiraConnection) async throws
        -> (issues: [JiraIssue], nextPageToken: String?) {
        var body: [String: Any] = ["jql": jql, "fields": fields, "maxResults": 100]
        if let pageToken { body["nextPageToken"] = pageToken }
        let data = try JSONSerialization.data(withJSONObject: body)
        let (response, urlResponse) = try await session.data(for: request(connection, path: "rest/api/3/search/jql", method: "POST", body: data))
        try check(urlResponse)
        let page = try decode(response)
        let info = try? JSONDecoder().decode(PageInfo.self, from: response)
        return (page, page.isEmpty || info?.isLast == true ? nil : info?.nextPageToken)
    }

    private struct PageInfo: Decodable {
        let nextPageToken: String?
        let isLast: Bool?
    }

    /// One page (up to 100) of a project's unreleased, unarchived fix versions, with how many of
    /// their tickets are in each status category.
    static func unreleasedVersions(project: String, startAt: Int, connection: JiraConnection) async throws
        -> (versions: [JiraVersion], isLast: Bool) {
        let query = [
            URLQueryItem(name: "status", value: "unreleased"),
            URLQueryItem(name: "expand", value: "issuesstatus"),
            URLQueryItem(name: "orderBy", value: "releaseDate"),
            URLQueryItem(name: "maxResults", value: "100"),
            URLQueryItem(name: "startAt", value: String(startAt)),
        ]
        let (data, response) = try await session.data(for: request(connection, path: "rest/api/3/project/\(project)/version", query: query))
        try check(response)
        struct Page: Decodable {
            struct Version: Decodable {
                struct Counts: Decodable {
                    let unmapped: Int?
                    let toDo: Int?
                    let inProgress: Int?
                    let done: Int?
                }
                let id: String
                let name: String
                let description: String?
                let archived: Bool?
                let released: Bool?
                let releaseDate: String?
                let overdue: Bool?
                let issuesStatusForFixVersion: Counts?
            }
            let values: [Version]
            let isLast: Bool?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let versions = page.values.filter { $0.released != true && $0.archived != true }.map { version in
            JiraVersion(
                id: version.id, name: version.name, project: project,
                details: version.description.flatMap { $0.isEmpty ? nil : $0 }, releaseDate: version.releaseDate,
                overdue: version.overdue ?? false,
                progress: version.issuesStatusForFixVersion.map { counts in
                    JiraVersion.Progress(toDo: (counts.toDo ?? 0) + (counts.unmapped ?? 0), inProgress: counts.inProgress ?? 0,
                                         done: counts.done ?? 0)
                }
            )
        }
        return (versions, page.isLast ?? true)
    }

    private struct SearchResponse: Decodable {
        struct Issue: Decodable {
            struct Fields: Decodable {
                struct Status: Decodable {
                    struct Category: Decodable { let key: String }
                    let name: String
                    let statusCategory: Category?
                }
                struct IssueType: Decodable {
                    let name: String
                    let subtask: Bool?
                    let hierarchyLevel: Int?
                }
                struct Named: Decodable { let name: String }
                struct Person: Decodable { let displayName: String }
                struct Parent: Decodable {
                    struct ParentFields: Decodable {
                        let summary: String?
                        let status: Status?
                        let issuetype: IssueType?
                    }
                    let key: String
                    let fields: ParentFields?
                }
                let summary: String?
                let status: Status?
                let issuetype: IssueType?
                let assignee: Person?
                let fixVersions: [Named]?
                let parent: Parent?
            }
            let key: String
            let fields: Fields
        }
        let issues: [Issue]
    }

    private static func category(_ status: SearchResponse.Issue.Fields.Status?) -> JiraIssue.Category {
        status?.statusCategory.flatMap { JiraIssue.Category(rawValue: $0.key) } ?? .unknown
    }

    /// 1 for epics, 0 for stories, tasks and bugs, -1 for sub-tasks; from the type's name when the
    /// site doesn't say.
    private static func level(_ type: SearchResponse.Issue.Fields.IssueType?) -> Int {
        guard let type else { return 0 }
        if let level = type.hierarchyLevel { return level }
        if type.subtask == true { return -1 }
        return type.name.caseInsensitiveCompare("Epic") == .orderedSame ? 1 : 0
    }

    private static func decode(_ data: Data) throws -> [JiraIssue] {
        try JSONDecoder().decode(SearchResponse.self, from: data).issues.map { issue in
            let fields = issue.fields
            return JiraIssue(
                key: issue.key,
                summary: fields.summary ?? "",
                status: fields.status?.name ?? "Unknown",
                category: category(fields.status),
                type: fields.issuetype?.name,
                assignee: fields.assignee?.displayName,
                fixVersions: fields.fixVersions?.map(\.name) ?? [],
                level: level(fields.issuetype),
                parent: fields.parent.map { parent in
                    JiraLink(key: parent.key, summary: parent.fields?.summary ?? "", status: parent.fields?.status?.name ?? "Unknown",
                             category: category(parent.fields?.status), type: parent.fields?.issuetype?.name,
                             level: level(parent.fields?.issuetype))
                }
            )
        }
    }
}

/// Ticket statuses for the whole app, fetched politely: only keys that aren't cached, in batches of
/// up to 50, one request at a time across every Jira profile (ticket lists and fix versions take
/// their turn too), after a short pause so scrolling doesn't fire requests, at most 20 requests a
/// minute, backing off on errors, and stopping for a profile whose credentials Jira rejects.
/// Editing profiles drops everything sent or queued with the old credentials.
@MainActor @Observable final class JiraStore {
    static let shared = JiraStore()

    /// Increments when statuses, ticket lists or fix versions arrive, so what shows them redraws.
    private(set) var version = 0
    /// The Jira sites and accounts set up in Settings.
    private(set) var profiles: [JiraProfile]
    /// Why a profile's requests failed or stopped.
    private(set) var problems: [UUID: String] = [:]

    /// The profile new repositories start with.
    var defaultProfileID: UUID? {
        didSet { saveProfiles() }
    }

    private struct ProfileCache {
        var issues: [String: (issue: JiraIssue, fetchedAt: Date)] = [:]
        var unknown: [String: Date] = [:]
        var versions: [String: (versions: [JiraVersion], fetchedAt: Date)] = [:]
    }

    private struct Pending {
        let key: String
        let connection: JiraConnection
    }

    /// Statuses per profile (what that account sees), kept across relaunches in `jira-cache.json`.
    @ObservationIgnored private var caches: [UUID: ProfileCache] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Pending] = []
    /// `profile key` of everything queued or being fetched.
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Lets one request through at a time, whatever it's for.
    @ObservationIgnored private let gate = SerialGate()
    @ObservationIgnored private var pausedUntil: Date?
    @ObservationIgnored private var backoff: TimeInterval = 30
    @ObservationIgnored private var recentRequests: [Date] = []
    @ObservationIgnored private var unauthorized: Set<UUID> = []
    /// Increments when profiles change; answers to requests sent before are ignored.
    @ObservationIgnored private var generation = 0
    /// Sites without the bulk-fetch endpoint get JQL search, where one unknown key fails the whole
    /// query; their batches shrink after a failure (one request per flush, paced like the rest).
    @ObservationIgnored private var searchOnlySites: Set<String> = []
    @ObservationIgnored private var searchBatchSize: [String: Int] = [:]
    /// Sites where `parentEpic` isn't understood; epics are asked for level by level there.
    @ObservationIgnored private var noParentEpicSites: Set<String> = []
    /// Connections built from profiles, so the keychain is read once per profile.
    @ObservationIgnored private var connections: [UUID: JiraConnection?] = [:]
    /// Tickets of recently asked queries (a fix version's, an epic's), and the requests under way,
    /// so asking again soon doesn't go back to Jira.
    @ObservationIgnored private var listResults: [String: (keys: [String], fetchedAt: Date)] = [:]
    @ObservationIgnored private var listRequests: [String: Task<[JiraIssue], Error>] = [:]
    @ObservationIgnored private var versionRequests: Set<String> = []
    /// Projects Jira didn't list versions for (not a project there, or not visible to the account).
    @ObservationIgnored private var versionFailures: [String: Date] = [:]
    @ObservationIgnored private var knownFixVersionsCache: [UUID: (version: Int, values: [String])] = [:]

    /// A cached status is shown right away and asked for again only after an hour, when on screen;
    /// a done ticket's only after a day, since done work rarely changes.
    private static let freshFor: TimeInterval = 60 * 60
    private static let doneFreshFor: TimeInterval = 24 * 60 * 60
    /// Keys Jira doesn't know are not asked about again for a day.
    private static let missingFor: TimeInterval = 24 * 60 * 60
    private static let listFreshFor: TimeInterval = 10 * 60
    private static let versionsFreshFor: TimeInterval = 60 * 60

    /// Whether a cached ticket is due to be asked for again when it's needed.
    private static func isStale(_ issue: JiraIssue, fetchedAt: Date) -> Bool {
        !issue.knowsParent || Date().timeIntervalSince(fetchedAt) >= (issue.category == .done ? doneFreshFor : freshFor)
    }
    private static let batchSize = 50
    private static let requestsPerMinute = 20
    /// The longest GitTree waits when Jira says to slow down; editing a profile ends the wait.
    private static let longestPause: TimeInterval = 10 * 60

    private init() {
        let saved = JiraProfiles.load()
        profiles = saved.profiles
        defaultProfileID = saved.defaultProfileID
        for (key, cache) in JiraCacheFile.load().sites {
            guard let id = UUID(uuidString: key) else { continue }  // caches of earlier versions were per site
            caches[id] = ProfileCache(issues: cache.issues.mapValues { ($0.issue, $0.fetchedAt) }, unknown: cache.unknown,
                                      versions: (cache.versions ?? [:]).mapValues { ($0.versions, $0.fetchedAt) })
        }
    }

    private static func id(_ connection: JiraConnection, _ key: String) -> String { "\(connection.profileID) \(key)" }

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

    /// Whether a connection still matches its profile's current settings; a view may hold one made
    /// before the profile was edited.
    private func isCurrent(_ connection: JiraConnection) -> Bool {
        #if DEBUG
        if let mock = Self.mockConnection { return connection == mock }
        #endif
        return profile(id: connection.profileID).flatMap(self.connection(for:)) == connection
    }

    /// Adds or updates a profile. A non-empty token replaces the saved one.
    func save(_ profile: JiraProfile, token: String?) {
        var saved = profile
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.site = saved.site.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.email = saved.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty { JiraProfiles.setToken(token, for: saved.id) }
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) {
            // Another site or account sees other tickets: start over.
            if profiles[index].host != saved.host || profiles[index].email != saved.email { caches[saved.id] = nil }
            profiles[index] = saved
        } else {
            profiles.append(saved)
        }
        saveProfiles()
        profilesChanged()
    }

    /// Removes a profile, its token and its cached statuses. Repositories that used it have no Jira
    /// until another is picked.
    func remove(profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        JiraProfiles.setToken("", for: profileID)
        caches[profileID] = nil
        if defaultProfileID == profileID { defaultProfileID = nil }
        saveProfiles()
        profilesChanged()
        scheduleSave()
    }

    private func saveProfiles() {
        JiraProfiles.save(JiraProfiles.Saved(profiles: profiles, defaultProfileID: defaultProfileID))
    }

    /// Credentials changed: drop what was queued or sent with the old ones (their answers are
    /// ignored), forget rejected accounts and unknown tickets, and end any pause.
    private func profilesChanged() {
        generation += 1
        connections = [:]
        unauthorized = []
        problems = [:]
        pausedUntil = nil
        backoff = 30
        flushTask?.cancel()
        flushTask = nil
        caches = caches.mapValues { ProfileCache(issues: $0.issues, unknown: [:], versions: $0.versions) }
        queue.removeAll()
        queued.removeAll()
        searchOnlySites = []
        searchBatchSize = [:]
        noParentEpicSites = []
        listResults = [:]
        listRequests = [:]
        versionRequests = []
        versionFailures = [:]
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
        caches[connection.profileID]?.issues[key]?.issue
    }

    /// Jira answered without this key: it doesn't exist or this account can't see it.
    func isMissing(_ key: String, connection: JiraConnection) -> Bool {
        guard let cache = caches[connection.profileID] else { return false }
        return cache.unknown[key] != nil && cache.issues[key] == nil
    }

    /// Whether a status is known or Jira said it doesn't know the key.
    func isSettled(_ key: String, connection: JiraConnection) -> Bool {
        issue(key, connection: connection) != nil || isMissing(key, connection: connection)
    }

    /// Fix versions seen in a profile's cached tickets, newest first ("2.12", "2.11"…).
    func knownFixVersions(for connection: JiraConnection) -> [String] {
        if let cached = knownFixVersionsCache[connection.profileID], cached.version == version { return cached.values }
        let issues = caches[connection.profileID]?.issues.values.map(\.issue) ?? []
        let values = Set(issues.flatMap(\.fixVersions)).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        knownFixVersionsCache[connection.profileID] = (version, values)
        return values
    }

    /// The epic a ticket belongs to: the ticket itself when it's an epic, its parent, or for a
    /// sub-task its parent's parent. `.pending` until the tickets involved have been read.
    func epic(of key: String, connection: JiraConnection) -> EpicLookup {
        guard let issue = issue(key, connection: connection) else {
            return isMissing(key, connection: connection) ? .notInJira : .pending
        }
        guard issue.knowsParent else { return .pending }
        if issue.isEpic { return .epic(issue.link) }
        guard let parent = issue.parent else { return .none }
        if parent.isEpic { return .epic(parent) }
        guard let above = self.issue(parent.key, connection: connection) else {
            return isMissing(parent.key, connection: connection) ? .none : .pending
        }
        guard above.knowsParent else { return .pending }
        if above.isEpic { return .epic(above.link) }
        if let epic = above.parent, epic.isEpic { return .epic(epic) }
        return .none
    }

    /// The stories and tasks above these tickets that still need reading before their epics are
    /// known (a sub-task's epic is its parent's parent).
    func parentsToRead(of keys: [String], connection: JiraConnection) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for key in keys {
            guard let parent = issue(key, connection: connection)?.parent, !parent.isEpic,
                  issue(parent.key, connection: connection)?.knowsParent != true,
                  !isMissing(parent.key, connection: connection),
                  seen.insert(parent.key).inserted else { continue }
            result.append(parent.key)
        }
        return result
    }

    /// Makes sure these tickets' statuses are known, through the usual queue (batched, paced,
    /// cached), and waits up to 30 seconds for them.
    func ensure(_ keys: [String], connection: JiraConnection) async {
        let ids = enqueue(keys, connection: connection) { fetchedAt, issue in Self.isStale(issue, fetchedAt: fetchedAt) }
        await wait(for: ids, connection: connection, timeout: 30)
    }

    /// Makes sure these tickets have been read with their parents, so their epics are known. Only
    /// tickets Jira hasn't answered about yet are asked for (statuses already cached are used
    /// however old), through the usual queue; waits for them up to `timeout` seconds.
    func ensureKnown(_ keys: [String], connection: JiraConnection, timeout: TimeInterval = 120) async {
        let ids = enqueue(keys, connection: connection) { _, issue in !issue.knowsParent }
        await wait(for: ids, connection: connection, timeout: timeout)
    }

    /// Asks Jira again about these tickets however recently they were read (the Epics section's
    /// Refresh), and waits for the answers up to `timeout` seconds.
    func refresh(_ keys: [String], connection: JiraConnection, timeout: TimeInterval = 120) async {
        let ids = enqueue(keys, connection: connection) { _, _ in true }
        await wait(for: ids, connection: connection, timeout: timeout)
    }

    /// Repository › Refresh Ticket Statuses: keeps showing what's cached, but asks Jira again for
    /// the tickets on screen, and for fix versions and ticket lists when they're next shown.
    func markAllStale() {
        caches = caches.mapValues { cache in
            ProfileCache(issues: cache.issues.mapValues { ($0.issue, Date.distantPast) }, unknown: [:],
                         versions: cache.versions.mapValues { ($0.versions, Date.distantPast) })
        }
        listResults = [:]
        versionFailures = [:]
        version += 1
    }

    /// Asks for these keys' statuses (the ones on screen, ahead of everything else waiting), at
    /// most `limit` new ones in the order given; cached, queued and known-missing keys are skipped.
    func request(_ keys: [String], connection: JiraConnection, limit: Int = .max) {
        enqueue(keys, connection: connection, first: true, limit: limit) { fetchedAt, issue in
            Self.isStale(issue, fetchedAt: fetchedAt)
        }
    }

    /// Queues the keys that aren't cached, or whose cached status `isStale` says to ask for again,
    /// at most `limit` of them. Queued, in-flight and recently unknown keys are skipped. Returns
    /// the ids to wait for.
    @discardableResult
    private func enqueue(_ keys: [String], connection: JiraConnection, first: Bool = false, limit: Int = .max,
                         isStale: (_ fetchedAt: Date, _ issue: JiraIssue) -> Bool) -> [String] {
        guard isCurrent(connection), !unauthorized.contains(connection.profileID) else { return [] }
        let now = Date()
        let cache = caches[connection.profileID]
        var waiting: [String] = []
        var added: [Pending] = []
        for key in keys {
            let id = Self.id(connection, key)
            if queued.contains(id) || inFlightKeys.contains(id) {
                waiting.append(id)
                continue
            }
            guard added.count < limit else { continue }
            if let cached = cache?.issues[key], !isStale(cached.fetchedAt, cached.issue) { continue }
            if let missing = cache?.unknown[key], now.timeIntervalSince(missing) < Self.missingFor { continue }
            added.append(Pending(key: key, connection: connection))
            queued.insert(id)
            waiting.append(id)
        }
        queue = first ? added + queue : queue + added
        scheduleFlush(after: 0.6)
        return waiting
    }

    private func wait(for ids: [String], connection: JiraConnection, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ids.allSatisfy({ !queued.contains($0) && !inFlightKeys.contains($0) }) { return }
            if unauthorized.contains(connection.profileID) || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: Ticket lists

    /// The tickets in a fix version, by its Jira id (or by name when that's all there is), cached
    /// for ten minutes.
    func tickets(inFixVersion version: String, isID: Bool, connection: JiraConnection) async throws -> [JiraIssue] {
        try await list(isID ? JiraQuery.fixVersion(id: version) : JiraQuery.fixVersion(named: version), connection: connection)
    }

    /// The keys of a fix version's tickets as last asked, however long ago; nil before the first answer.
    func cachedTickets(inFixVersionID id: String, connection: JiraConnection) -> [String]? {
        listResults[Self.id(connection, JiraQuery.fixVersion(id: id))]?.keys
    }

    /// An epic's tickets and their sub-tasks. Sites that don't understand `parentEpic` get the
    /// epic's children and then theirs.
    func tickets(inEpic key: String, connection: JiraConnection) async throws -> [JiraIssue] {
        if !noParentEpicSites.contains(connection.host) {
            do {
                return try await list(JiraQuery.epic(key), connection: connection)
            } catch JiraError.badQuery {
                noParentEpicSites.insert(connection.host)
            }
        }
        let children = try await list(JiraQuery.children(of: [key]), connection: connection)
        let parents = children.filter { $0.level == 0 }.map(\.key).prefix(100)
        guard !parents.isEmpty else { return children }
        let subtasks = try await list(JiraQuery.children(of: Array(parents)), connection: connection)
        return children + subtasks
    }

    /// Tickets matching a query, asked of Jira a page of 100 at a time (at most five pages) and
    /// cached like the rest. Asking for the same again within ten minutes, or while it's loading,
    /// doesn't send another request.
    private func list(_ jql: String, connection: JiraConnection) async throws -> [JiraIssue] {
        guard isCurrent(connection), !unauthorized.contains(connection.profileID) else { throw JiraError.unauthorized }
        let id = Self.id(connection, jql)
        if let result = listResults[id], Date().timeIntervalSince(result.fetchedAt) < Self.listFreshFor {
            let cached = result.keys.compactMap { issue($0, connection: connection) }
            if cached.count == result.keys.count { return cached }
        }
        if let running = listRequests[id] { return try await running.value }
        let request = Task { [weak self] () throws -> [JiraIssue] in
            var collected: [JiraIssue] = []
            var pageToken: String?
            var pages = 0
            repeat {
                guard let self else { throw CancellationError() }
                let token = pageToken
                let page = try await self.send(connection) { try await JiraClient.searchPage(jql, pageToken: token, connection: connection) }
                collected += page.issues
                pageToken = page.nextPageToken
                pages += 1
            } while pageToken != nil && pages < 5
            return collected
        }
        listRequests[id] = request
        let sentIn = generation
        do {
            let issues = try await request.value
            if listRequests[id] == request { listRequests[id] = nil }
            guard sentIn == generation else { return issues }
            let now = Date()
            for issue in issues { caches[connection.profileID, default: ProfileCache()].issues[issue.key] = (issue, now) }
            listResults[id] = (issues.map(\.key), now)
            problems[connection.profileID] = nil
            version += 1
            scheduleSave()
            return issues
        } catch {
            if listRequests[id] == request { listRequests[id] = nil }
            // A query Jira doesn't understand (an unknown fix version, say) isn't a reason to pause.
            if sentIn == generation, !(error is CancellationError) {
                if case JiraError.badQuery = error {} else { recordFailure(error, connection: connection) }
            }
            throw error
        }
    }

    // MARK: Fix versions

    /// The unreleased fix versions of these projects as last fetched, soonest release first.
    func unreleasedVersions(projects: [String], connection: JiraConnection) -> [JiraVersion] {
        let lists = caches[connection.profileID]?.versions ?? [:]
        var seen: Set<String> = []
        return projects.flatMap { lists[$0]?.versions ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: JiraVersion.soonestFirst)
    }

    /// Asks Jira for the projects' unreleased fix versions, unless they were fetched in the last
    /// hour (or Jira didn't know the project today): one request per project, paced like every other.
    func refreshVersions(projects: [String], connection: JiraConnection, force: Bool = false) {
        guard isCurrent(connection), !unauthorized.contains(connection.profileID) else { return }
        let now = Date()
        for project in projects {
            let id = Self.id(connection, "versions \(project)")
            if !force, let list = caches[connection.profileID]?.versions[project],
               now.timeIntervalSince(list.fetchedAt) < Self.versionsFreshFor { continue }
            if let failed = versionFailures[id], now.timeIntervalSince(failed) < Self.missingFor { continue }
            guard versionRequests.insert(id).inserted else { continue }
            let sentIn = generation
            Task { [weak self] in
                guard let self else { return }
                defer { if sentIn == self.generation { self.versionRequests.remove(id) } }
                do {
                    var versions: [JiraVersion] = []
                    var pages = 0
                    var isLast = false
                    while !isLast && pages < 3 {
                        let startAt = pages * 100
                        let page = try await self.send(connection) {
                            try await JiraClient.unreleasedVersions(project: project, startAt: startAt, connection: connection)
                        }
                        versions += page.versions
                        isLast = page.isLast
                        pages += 1
                    }
                    guard sentIn == self.generation else { return }
                    self.caches[connection.profileID, default: ProfileCache()].versions[project] = (versions, Date())
                    self.version += 1
                    self.scheduleSave()
                } catch JiraError.server(404), JiraError.badQuery {
                    // Not a project on this site (a ticket prefix that only looks like one).
                    if sentIn == self.generation { self.versionFailures[id] = Date() }
                } catch {
                    if sentIn == self.generation, !(error is CancellationError) { self.recordFailure(error, connection: connection) }
                }
            }
        }
    }

    // MARK: Requests

    /// How long until another request fits in the per-minute budget and any pause is over.
    private func budgetWait() -> TimeInterval {
        var wait: TimeInterval = 0
        if let pausedUntil { wait = max(wait, pausedUntil.timeIntervalSinceNow) }
        let minuteAgo = Date().addingTimeInterval(-60)
        recentRequests.removeAll { $0 < minuteAgo }
        if recentRequests.count >= Self.requestsPerMinute, let oldest = recentRequests.first {
            wait = max(wait, oldest.timeIntervalSinceNow + 60)
        }
        return wait
    }

    /// Sends one request when it's its turn: one at a time across every profile, within the
    /// per-minute budget, and after any pause Jira asked for. Waiting looks again every few
    /// seconds, so editing a profile ends a pause; a request whose credentials changed or were
    /// rejected meanwhile isn't sent.
    private func send<T: Sendable>(_ connection: JiraConnection, _ work: @Sendable () async throws -> T) async throws -> T {
        await gate.enter()
        defer { gate.leave() }
        var wait = budgetWait()
        while wait > 0 {
            try await Task.sleep(for: .seconds(min(wait, 5)))
            wait = budgetWait()
        }
        guard isCurrent(connection), !unauthorized.contains(connection.profileID) else { throw CancellationError() }
        recentRequests.append(Date())
        return try await work()
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard !queue.isEmpty, !inFlight, flushTask == nil else { return }
        let wait = max(delay, budgetWait())
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    /// Sends one request: up to 50 queued keys of the same profile (fewer on sites where JQL
    /// search had trouble with unknown keys).
    private func flush() async {
        guard !inFlight, let connection = queue.first?.connection else { return }
        let limit = searchOnlySites.contains(connection.host) ? (searchBatchSize[connection.host] ?? Self.batchSize) : Self.batchSize
        var batch: [String] = []
        var rest: [Pending] = []
        for pending in queue {
            if pending.connection == connection && batch.count < limit {
                batch.append(pending.key)
            } else {
                rest.append(pending)
            }
        }
        queue = rest
        let ids = batch.map { Self.id(connection, $0) }
        ids.forEach { queued.remove($0) }
        inFlightKeys.formUnion(ids)
        inFlight = true
        await fetch(batch, connection: connection)
        inFlightKeys.subtract(ids)
        inFlight = false
        version += 1
        scheduleSave()
        scheduleFlush(after: 1)
    }

    /// One request: bulk fetch, which skips unknown keys, or JQL search on sites without it.
    /// Unknown keys are remembered so they're not asked for again soon.
    private func fetch(_ keys: [String], connection: JiraConnection) async {
        let host = connection.host
        let sentIn = generation
        do {
            var found: [JiraIssue]?
            if !searchOnlySites.contains(host) {
                found = try await send(connection) { try await JiraClient.bulkFetch(keys, connection: connection) }
                guard sentIn == generation else { return }
                if found == nil { searchOnlySites.insert(host) }
            }
            if found == nil {
                found = try await send(connection) { try await JiraClient.search(keys, connection: connection) }
                guard sentIn == generation else { return }
                searchBatchSize[host] = min(Self.batchSize, (searchBatchSize[host] ?? Self.batchSize) * 2)
            }
            let received = found ?? []
            let now = Date()
            for issue in received { caches[connection.profileID, default: ProfileCache()].issues[issue.key] = (issue, now) }
            let foundKeys = Set(received.map(\.key))
            for key in keys where !foundKeys.contains(key) { caches[connection.profileID, default: ProfileCache()].unknown[key] = now }
            problems[connection.profileID] = nil
            backoff = 30
        } catch JiraError.badQuery {
            // JQL search rejects the whole query for one unknown key. A single key is unknown;
            // otherwise the keys go back to the front of the queue and the next requests take half.
            guard sentIn == generation else { return }
            if keys.count == 1 {
                caches[connection.profileID, default: ProfileCache()].unknown[keys[0]] = Date()
            } else {
                searchBatchSize[host] = max(1, keys.count / 2)
                putBack(keys, connection: connection, atFront: true)
            }
        } catch {
            guard sentIn == generation else { return }
            recordFailure(error, connection: connection)
            if case JiraError.unauthorized = error { return }
            // Not sent: its credentials were rejected meanwhile. Asking again would fail the same way.
            if error is CancellationError { return }
            putBack(keys, connection: connection, atFront: false)
        }
    }

    /// A rejected token stops that profile's requests; a rate limit or another error pauses all of them.
    private func recordFailure(_ error: Error, connection: JiraConnection) {
        switch error {
        case JiraError.unauthorized:
            unauthorized.insert(connection.profileID)
            problems[connection.profileID] = JiraError.unauthorized.localizedDescription
            for pending in queue where pending.connection.profileID == connection.profileID {
                queued.remove(Self.id(pending.connection, pending.key))
            }
            queue.removeAll { $0.connection.profileID == connection.profileID }
        case JiraError.rateLimited(let retryAfter):
            pausedUntil = Date().addingTimeInterval(min(max(retryAfter, 5), Self.longestPause))
        case is CancellationError:
            break
        default:
            problems[connection.profileID] = error.localizedDescription
            pausedUntil = Date().addingTimeInterval(backoff)
            backoff = min(backoff * 2, 15 * 60)
        }
    }

    private func putBack(_ keys: [String], connection: JiraConnection, atFront: Bool) {
        var pending: [Pending] = []
        for key in keys {
            let id = Self.id(connection, key)
            guard !queued.contains(id) else { continue }
            pending.append(Pending(key: key, connection: connection))
            queued.insert(id)
        }
        queue = atFront ? pending + queue : queue + pending
    }

    // MARK: Cache on disk

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            var file = JiraCacheFile()
            for (id, cache) in self.caches {
                file.sites[id.uuidString] = JiraCacheFile.Site(
                    issues: cache.issues.mapValues { JiraCacheFile.Entry(issue: $0.issue, fetchedAt: $0.fetchedAt) },
                    unknown: cache.unknown,
                    versions: cache.versions.mapValues { JiraCacheFile.VersionList(versions: $0.versions, fetchedAt: $0.fetchedAt) }
                )
            }
            await Task.detached(priority: .utility) { file.save() }.value
        }
    }
}
