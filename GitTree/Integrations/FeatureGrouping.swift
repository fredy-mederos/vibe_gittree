import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A commit as the feature grouping sees it.
struct FeatureCommit: Sendable {
    let id: ObjectID
    let subject: String
    let author: String
    let date: Date
}

/// Commits that belong to one piece of work: one ticket, or the commits of a term that have no ticket.
struct FeatureGroup: Identifiable, Sendable {
    let id: String
    var name: String
    /// The term this work belongs to, like Search or Tech Debt.
    var area: String
    let ticket: String?
    let commits: [FeatureCommit]

    var latest: Date { commits.map(\.date).max() ?? .distantPast }
    var earliest: Date { commits.map(\.date).min() ?? .distantPast }
    var authors: [String] {
        var seen: [String] = []
        for commit in commits where !seen.contains(commit.author) { seen.append(commit.author) }
        return seen
    }
}

struct FeatureReport: Sendable {
    let groups: [FeatureGroup]
    let commitCount: Int
    let usedAI: Bool
    /// Why the on-device model wasn't used, when it wasn't.
    let note: String?
    /// Terms newest first, each with its features newest first. Built once, with ties broken by
    /// name, so the sidebar's order never shifts between redraws.
    let areas: [(name: String, groups: [FeatureGroup])]

    init(groups: [FeatureGroup], commitCount: Int, usedAI: Bool, note: String?) {
        self.groups = groups
        self.commitCount = commitCount
        self.usedAI = usedAI
        self.note = note
        areas = Dictionary(grouping: groups, by: \.area)
            .map { name, members in
                (name: name, groups: members.sorted { ($0.latest, $1.id) > ($1.latest, $0.id) })
            }
            .sorted { lhs, rhs in
                let left = lhs.groups.first?.latest ?? .distantPast
                let right = rhs.groups.first?.latest ?? .distantPast
                return left == right ? lhs.name < rhs.name : left > right
            }
    }
}

// MARK: - Terms

/// What the team calls its features and areas, learned from commit messages and saved per repository:
/// the terms seen so far and which term each ticket or commit belongs to. Later runs reuse it, so
/// only new work needs figuring out, and the same work always lands under the same term.
struct FeatureCatalog: Codable, Sendable {
    struct Term: Codable, Sendable {
        var name: String
        var uses: Int
        /// The term was suggested by the on-device model rather than written in a commit.
        var suggested: Bool
        var example: String
    }

    /// Normalized key → term.
    var terms: [String: Term] = [:]
    /// `ticket:PROJ-123` or `commit:<hash>` → normalized term key.
    var assignments: [String: String] = [:]

    static func url(for repositoryID: UUID) -> URL {
        AppPaths.dataDirectory.appendingPathComponent("Features", isDirectory: true).appendingPathComponent("\(repositoryID.uuidString).json")
    }

    static func load(repositoryID: UUID) -> FeatureCatalog {
        guard let data = try? Data(contentsOf: url(for: repositoryID)),
              let catalog = try? JSONDecoder().decode(FeatureCatalog.self, from: data) else { return FeatureCatalog() }
        return catalog
    }

    func save(repositoryID: UUID) {
        let url = Self.url(for: repositoryID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    static func forget(repositoryID: UUID) {
        try? FileManager.default.removeItem(at: url(for: repositoryID))
    }

    static func key(_ term: String) -> String {
        term.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    mutating func record(_ term: String, example: String, suggested: Bool = false) -> String {
        let key = Self.key(term)
        if var existing = terms[key] {
            existing.uses += 1
            terms[key] = existing
        } else {
            terms[key] = Term(name: term, uses: 1, suggested: suggested, example: String(example.prefix(90)))
        }
        return key
    }
}

/// Finds the terms a commit message uses for its feature: bracketed tags (`[Search]`, `[Tech Debt]`)
/// and scope prefixes (`github-pr: …`, `Chat prototype: …`, `feat(search): …`). Type tags such as
/// `[Bug]` or `[New]` are not features and are skipped.
enum TermExtractor {
    private static let ignored: Set<String> = [
        "bug", "bugs", "bugfix", "fix", "fixes", "hotfix", "new", "ref", "refactor", "refactoring", "imp", "improvement",
        "wip", "android", "ios", "test", "tests", "chore", "feat", "feature", "pr media", "merge", "minor", "cleanup",
        "docs", "doc", "style", "build", "release", "revert", "temp", "todo", "skip ci", "ci skip", "skip-ci",
        "no ci", "draft", "do not merge", "dnm",
    ]

    static func terms(in subject: String, ticketRegex: NSRegularExpression?) -> [String] {
        var found: [String] = []
        func add(_ raw: Substring) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-_")))
            let key = FeatureCatalog.key(term)
            guard term.count >= 2, !ignored.contains(key), term.rangeOfCharacter(from: .letters) != nil,
                  !found.contains(where: { FeatureCatalog.key($0) == key }) else { return }
            if let ticketRegex, ticketRegex.firstMatch(in: term, range: NSRange(term.startIndex..., in: term)) != nil { return }
            found.append(term)
        }

        for match in subject.matches(of: #/\[([^\[\]]{2,32})\]/#) {
            add(match.1)
        }

        var rest = subject
        if let ticketRegex, let match = ticketRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let range = Range(match.range, in: rest), range.lowerBound == rest.startIndex {
            rest = String(rest[range.upperBound...])
        }
        rest = rest.replacingOccurrences(of: #"^\s*(\[[^\]]*\]\s*)*[:\-–]?\s*"#, with: "", options: .regularExpression)
        if let scope = rest.firstMatch(of: #/^[a-z]+\(([^)]{2,30})\)!?:\s/#) {
            add(scope.1)
        } else if let prefix = rest.firstMatch(of: #/^([A-Za-z][A-Za-z0-9\-_ ]{1,28}?):\s/#),
                  prefix.1.split(separator: " ").count <= 3 {
            add(prefix.1)
        }
        return found
    }
}

// MARK: - Grouping

/// Groups recent commits into features by the terms the team writes in commit messages:
/// 1. every commit's terms are extracted and counted;
/// 2. each ticket takes the most common term among its commits, so untagged commits of a tagged
///    ticket (like "PROJ-123 PR media") follow their ticket;
/// 3. tickets and commits without a term reuse what earlier runs saved;
/// 4. only what's left goes to Apple's on-device model, which picks an existing term or suggests a
///    new one; the answers are saved too. Commit messages never leave the Mac.
enum FeatureGrouper {
    private struct Item {
        let key: String
        let ticket: String?
        let commits: [FeatureCommit]
        var termKey: String?
    }

    static func analyze(_ commits: [FeatureCommit], ticketRegex: NSRegularExpression?, repositoryID: UUID,
                        progress: @MainActor @escaping (String) -> Void,
                        update: @MainActor @escaping (FeatureReport) -> Void) async {
        var catalog = FeatureCatalog.load(repositoryID: repositoryID)
        // Uses count this run's work, so the terms shown to the model are the ones in use now.
        catalog.terms = catalog.terms.mapValues { term in
            var term = term
            term.uses = 0
            return term
        }

        // Tickets and loose commits, newest first.
        var items: [Item] = []
        var ticketIndex: [String: Int] = [:]
        for commit in commits {
            let range = NSRange(commit.subject.startIndex..., in: commit.subject)
            if let match = ticketRegex?.firstMatch(in: commit.subject, range: range),
               let keyRange = Range(match.range, in: commit.subject) {
                let ticket = String(commit.subject[keyRange])
                if let index = ticketIndex[ticket] {
                    items[index] = Item(key: items[index].key, ticket: ticket, commits: items[index].commits + [commit])
                } else {
                    ticketIndex[ticket] = items.count
                    items.append(Item(key: "ticket:\(ticket)", ticket: ticket, commits: [commit]))
                }
            } else {
                items.append(Item(key: "commit:\(commit.id.hex)", ticket: nil, commits: [commit]))
            }
        }

        // 1–2. Terms written in the commits; a ticket takes its most common one.
        for index in items.indices {
            var counts: [String: (term: String, count: Int, example: String)] = [:]
            for commit in items[index].commits {
                for term in TermExtractor.terms(in: commit.subject, ticketRegex: ticketRegex) {
                    let key = FeatureCatalog.key(term)
                    counts[key] = (counts[key]?.term ?? term, (counts[key]?.count ?? 0) + 1, commit.subject)
                }
            }
            // Ties go to the term this work had before, then alphabetically, so it doesn't move
            // between areas from one run to the next.
            let saved = catalog.assignments[items[index].key]
            let best = counts.min { a, b in
                if a.value.count != b.value.count { return a.value.count > b.value.count }
                if (a.key == saved) != (b.key == saved) { return a.key == saved }
                return a.key < b.key
            }
            if let best {
                items[index].termKey = catalog.record(best.value.term, example: best.value.example)
                catalog.assignments[items[index].key] = items[index].termKey
            } else if let saved, catalog.terms[saved] != nil {
                // 3. Learned in an earlier run.
                items[index].termKey = saved
                catalog.terms[saved]?.uses += 1
            }
        }
        catalog.save(repositoryID: repositoryID)
        await update(report(items, catalog: catalog, commitCount: commits.count, usedAI: false, note: nil))

        // 4. The rest goes to the on-device model.
        let unassigned = items.indices.filter { items[$0].termKey == nil }
        guard !unassigned.isEmpty else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                let batches = stride(from: 0, to: unassigned.count, by: 15).map { Array(unassigned[$0..<min($0 + 15, unassigned.count)]) }
                for (number, batch) in batches.enumerated() {
                    await progress(String(localized: "Matching work to terms… \(number + 1) of \(batches.count)", comment: "Batches of commits sent to Apple's on-device model"))
                    let answers = await OnDeviceTermMatcher.assign(batch.map { items[$0] }, catalog: catalog, ticketRegex: ticketRegex)
                    for (offset, answer) in answers {
                        guard offset < batch.count, let term = answer else { continue }
                        let index = batch[offset]
                        let key = catalog.record(term, example: items[index].commits.first?.subject ?? "", suggested: true)
                        items[index].termKey = key
                        catalog.assignments[items[index].key] = key
                    }
                    catalog.save(repositoryID: repositoryID)
                    await update(report(items, catalog: catalog, commitCount: commits.count, usedAI: true, note: nil))
                }
                return
            case .unavailable(let reason):
                await update(report(items, catalog: catalog, commitCount: commits.count, usedAI: false, note: describe(reason)))
                return
            }
        }
        #endif
        await update(report(items, catalog: catalog, commitCount: commits.count, usedAI: false,
                            note: String(localized: "Matching work without a term needs macOS 26 or later with Apple Intelligence.")))
    }

    /// Tickets become features named after their most descriptive commit; commits without a ticket
    /// are gathered per term.
    private static func report(_ items: [Item], catalog: FeatureCatalog, commitCount: Int, usedAI: Bool, note: String?) -> FeatureReport {
        var groups: [FeatureGroup] = []
        var loose: [String: [FeatureCommit]] = [:]
        for item in items {
            let area = item.termKey.flatMap { catalog.terms[$0]?.name } ?? String(localized: "Other", comment: "The Features group for work without a term")
            if let ticket = item.ticket {
                groups.append(FeatureGroup(id: ticket, name: featureName(item.commits, ticket: ticket), area: area,
                                           ticket: ticket, commits: item.commits))
            } else {
                loose[area, default: []].append(contentsOf: item.commits)
            }
        }
        for (area, commits) in loose {
            groups.append(FeatureGroup(id: "loose-\(area)", name: commits.count == 1 ? cleanedSubject(commits[0].subject, removing: "") : String(localized: "Without a ticket"),
                                       area: area, ticket: nil, commits: commits))
        }
        return FeatureReport(groups: groups, commitCount: commitCount, usedAI: usedAI, note: note)
    }

    /// The oldest commit that says something (not "PR media", "Merge…", "WIP"), cleaned of keys and tags.
    static func featureName(_ commits: [FeatureCommit], ticket: String) -> String {
        let trivial = ["pr media", "merge", "wip", "fix lint", "lint", "format", "review fixes", "address review"]
        let named = commits.sorted { $0.date < $1.date }.map { cleanedSubject($0.subject, removing: ticket) }
        return named.first { name in
            let lower = name.lowercased()
            return name.count >= 12 && !trivial.contains { lower.hasPrefix($0) }
        } ?? named.first ?? ticket
    }

    static func cleanedSubject(_ subject: String, removing key: String) -> String {
        var text = key.isEmpty ? subject : subject.replacingOccurrences(of: key, with: "")
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(#\d+\)"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—|").union(.whitespaces))
        return text.isEmpty ? (key.isEmpty ? subject : key) : String(text.prefix(80))
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return String(localized: "Turn on Apple Intelligence in System Settings to sort work that has no term; until then it's under Other.")
        case .deviceNotEligible:
            return String(localized: "This Mac can't run Apple's on-device model, so work without a term stays under Other.")
        case .modelNotReady:
            return String(localized: "Apple's on-device model is still downloading; work without a term is under Other for now.")
        @unknown default:
            return String(localized: "Apple's on-device model isn't available, so work without a term stays under Other.")
        }
    }

    @available(macOS 26.0, *)
    private enum OnDeviceTermMatcher {
        static let instructions = """
        You file software work under the terms a team uses for its features and product areas. \
        Prefer an existing term whenever one fits. Only suggest a new term when none fits; keep it to \
        1 to 3 words, in the style of the existing terms. Never invent details.
        """

        /// Returns, per item offset in the batch, the chosen term (nil if the model skipped it).
        static func assign(_ items: [Item], catalog: FeatureCatalog, ticketRegex: NSRegularExpression?) async -> [Int: String?] {
            let known = catalog.terms.values
                .sorted { $0.uses > $1.uses }
                .prefix(40)
                .map { "- \($0.name) (e.g. \(String($0.example.prefix(70))))" }
                .joined(separator: "\n")
            let list = items.enumerated().map { offset, item -> String in
                let subjects = item.commits.prefix(3).map { "    " + String($0.subject.prefix(80)) }.joined(separator: "\n")
                return "\(offset + 1). \(item.ticket ?? "no ticket")\n\(subjects)"
            }.joined(separator: "\n")
            let prompt = """
            Existing terms:
            \(known.isEmpty ? "(none yet)" : known)

            File each of these under a term:
            \(list)
            """
            guard let answer = try? await LanguageModelSession(instructions: instructions)
                .respond(to: prompt, generating: GeneratedTermAssignments.self,
                         options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 600))
                .content.items else { return [:] }
            // Placeholders aren't terms; that work stays under Other.
            let placeholders: Set<String> = ["unknown", "other", "others", "misc", "miscellaneous", "general", "none", "n/a", "na", "various"]
            var result: [Int: String?] = [:]
            for entry in answer where entry.item >= 1 && entry.item <= items.count {
                let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
                result[entry.item - 1] = term.isEmpty || placeholders.contains(FeatureCatalog.key(term)) ? nil : term
            }
            return result
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedTermAssignments {
    @Guide(description: "One entry per numbered item, in the order given")
    var items: [GeneratedTermAssignment]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedTermAssignment {
    @Guide(description: "The item's number as given")
    var item: Int
    @Guide(description: "An existing term, spelled exactly as listed, or a new term of 1 to 3 words")
    var term: String
}
#endif
