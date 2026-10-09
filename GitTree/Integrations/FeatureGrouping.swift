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

/// Commits that belong to one piece of work: one ticket, or a cluster of related commits without one.
struct FeatureGroup: Identifiable, Sendable {
    let id: String
    var name: String
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

    /// Areas newest first, each with its groups newest first.
    var areas: [(name: String, groups: [FeatureGroup])] {
        Dictionary(grouping: groups, by: \.area)
            .map { (name: $0.key, groups: $0.value.sorted { $0.latest > $1.latest }) }
            .sorted { ($0.groups.first?.latest ?? .distantPast) > ($1.groups.first?.latest ?? .distantPast) }
    }
}

/// Groups recent commits into features. Ticket keys do the grouping; Apple's on-device model, when
/// available, names each group, gives it a product area, and clusters commits without a ticket.
/// Commit messages never leave the Mac.
enum FeatureGrouper {
    /// Groups right away by ticket, then, when the on-device model is available, improves names and
    /// areas one batch at a time, handing each improved report to `update` so the sidebar fills in
    /// progressively instead of waiting for the slowest batch.
    static func analyze(_ commits: [FeatureCommit], ticketRegex: NSRegularExpression?,
                        progress: @MainActor @escaping (String) -> Void,
                        update: @MainActor @escaping (FeatureReport) -> Void) async {
        let byTicket = groupByTicket(commits, ticketRegex: ticketRegex)
        let initial = byTicket.groups + fallbackClusters(byTicket.loose)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                await update(FeatureReport(groups: initial, commitCount: commits.count, usedAI: false, note: nil))
                await OnDeviceNamer.name(byTicket.groups, loose: byTicket.loose, commitCount: commits.count,
                                         progress: progress, update: update)
                return
            case .unavailable(let reason):
                await update(FeatureReport(groups: initial, commitCount: commits.count, usedAI: false, note: describe(reason)))
                return
            }
        }
        #endif
        await update(FeatureReport(groups: initial, commitCount: commits.count, usedAI: false,
                                   note: "Naming features needs macOS 26 or later with Apple Intelligence."))
    }

    /// One group per ticket key, named after its first commit and filed under its most common
    /// bracketed tag ([Watchlist], [Tech Debt]…).
    static func groupByTicket(_ commits: [FeatureCommit], ticketRegex: NSRegularExpression?) -> (groups: [FeatureGroup], loose: [FeatureCommit]) {
        var byTicket: [String: [FeatureCommit]] = [:]
        var order: [String] = []
        var loose: [FeatureCommit] = []
        for commit in commits {
            let range = NSRange(commit.subject.startIndex..., in: commit.subject)
            if let match = ticketRegex?.firstMatch(in: commit.subject, range: range),
               let keyRange = Range(match.range, in: commit.subject) {
                let key = String(commit.subject[keyRange])
                if byTicket[key] == nil { order.append(key) }
                byTicket[key, default: []].append(commit)
            } else {
                loose.append(commit)
            }
        }
        let groups = order.map { key -> FeatureGroup in
            let members = byTicket[key] ?? []
            let oldest = members.min { $0.date < $1.date } ?? members[0]
            return FeatureGroup(id: key, name: cleanedSubject(oldest.subject, removing: key),
                                area: commonTag(members) ?? "Other", ticket: key, commits: members)
        }
        return (groups, loose)
    }

    /// Without the model, commits without a ticket share one group per bracketed tag.
    static func fallbackClusters(_ loose: [FeatureCommit]) -> [FeatureGroup] {
        guard !loose.isEmpty else { return [] }
        let byTag = Dictionary(grouping: loose) { commonTag([$0]) ?? "Without a ticket" }
        return byTag.map { tag, members in
            FeatureGroup(id: "loose-\(tag)", name: tag == "Without a ticket" ? tag : "\(tag) work",
                         area: tag == "Without a ticket" ? "Other" : tag, ticket: nil, commits: members)
        }
    }

    static func cleanedSubject(_ subject: String, removing key: String) -> String {
        var text = subject.replacingOccurrences(of: key, with: "")
        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(#\d+\)"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—|").union(.whitespaces))
        return text.isEmpty ? key : String(text.prefix(80))
    }

    /// The most common `[Tag]` in the subjects, if any.
    static func commonTag(_ commits: [FeatureCommit]) -> String? {
        var counts: [String: Int] = [:]
        for commit in commits {
            for match in commit.subject.matches(of: #/\[([^\]]{2,24})\]/#) {
                counts[String(match.1).trimmingCharacters(in: .whitespaces), default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to name features; until then they're grouped by ticket."
        case .deviceNotEligible:
            return "This Mac can't run Apple's on-device model, so features are grouped by ticket only."
        case .modelNotReady:
            return "Apple's on-device model is still downloading; features are grouped by ticket for now."
        @unknown default:
            return "Apple's on-device model isn't available, so features are grouped by ticket only."
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedTicketNames {
    @Guide(description: "One entry per ticket, in the order given")
    var tickets: [GeneratedTicketName]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedTicketName {
    @Guide(description: "The ticket key exactly as given, like ABC-123")
    var key: String
    @Guide(description: "What the work does, in 2 to 6 words, title case, without the ticket key")
    var name: String
    @Guide(description: "The product area or theme, 1 to 3 words, like Watchlist, Checkout or Build tooling")
    var area: String
}

@available(macOS 26.0, *)
@Generable
struct GeneratedClusters {
    @Guide(description: "Groups of related commits; every commit number appears in exactly one group")
    var groups: [GeneratedCluster]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedCluster {
    @Guide(description: "What these commits do together, in 2 to 6 words, title case")
    var name: String
    @Guide(description: "The product area or theme, 1 to 3 words")
    var area: String
    @Guide(description: "The numbers of the commits in this group")
    var commits: [Int]
}

/// Talks to the on-device model in small batches (its context is small), one fresh session per
/// batch. A batch that fails keeps its ticket-based names.
@available(macOS 26.0, *)
private enum OnDeviceNamer {
    static let instructions = """
    You organize git commit messages from one software repository into product features. \
    Be concise and literal: reuse the commit messages' own words and product names. Never invent details.
    """

    static func name(_ ticketGroups: [FeatureGroup], loose: [FeatureCommit], commitCount: Int,
                     progress: @MainActor @escaping (String) -> Void,
                     update: @MainActor @escaping (FeatureReport) -> Void) async {
        var groups = ticketGroups
        var clusters: [FeatureGroup] = []
        var clustered: Set<Int> = []
        func report(final: Bool) -> FeatureReport {
            let leftovers = loose.enumerated().filter { !clustered.contains($0.offset) }.map(\.element)
            var all = groups + clusters + FeatureGrouper.fallbackClusters(leftovers)
            normalizeAreas(&all)
            return FeatureReport(groups: all, commitCount: commitCount, usedAI: final, note: nil)
        }

        // Small batches: the on-device model is quick per request but slow on long outputs.
        let ticketBatches = stride(from: 0, to: groups.count, by: 8).map { Array($0..<min($0 + 8, groups.count)) }
        let looseBatches = stride(from: 0, to: loose.count, by: 30).map { Array(loose[$0..<min($0 + 30, loose.count)]) }
        let total = ticketBatches.count + looseBatches.count
        var done = 0
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 700)

        for batch in ticketBatches {
            await progress("Naming features… \(done + 1) of \(total)")
            let prompt = batch.map { index -> String in
                let group = groups[index]
                let subjects = representativeSubjects(group).map { "  - " + $0 }.joined(separator: "\n")
                return "\(group.ticket ?? group.id):\n\(subjects)"
            }.joined(separator: "\n\n")
            if let names = try? await LanguageModelSession(instructions: instructions)
                .respond(to: "Name the feature and product area of each ticket from its commits.\n\n\(prompt)",
                         generating: GeneratedTicketNames.self, options: options)
                .content.tickets {
                for named in names {
                    guard let index = batch.first(where: { groups[$0].ticket == named.key }) else { continue }
                    let name = named.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let area = named.area.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { groups[index].name = name }
                    if !area.isEmpty { groups[index].area = area }
                }
            }
            done += 1
            await update(report(final: false))
        }

        for (number, batch) in looseBatches.enumerated() {
            await progress("Grouping commits without a ticket… \(done + 1) of \(total)")
            let list = batch.enumerated().map { "\($0.offset + 1). \(String($0.element.subject.prefix(80)))" }.joined(separator: "\n")
            if let generated = try? await LanguageModelSession(instructions: instructions)
                .respond(to: "Group these commits by the feature they work on.\n\n\(list)",
                         generating: GeneratedClusters.self, options: options)
                .content.groups {
                for (offset, cluster) in generated.enumerated() {
                    let members = cluster.commits.compactMap { $0 >= 1 && $0 <= batch.count ? batch[$0 - 1] : nil }
                    guard !members.isEmpty else { continue }
                    for member in members {
                        if let index = loose.firstIndex(where: { $0.id == member.id }) { clustered.insert(index) }
                    }
                    clusters.append(FeatureGroup(id: "cluster-\(number)-\(offset)", name: cluster.name, area: cluster.area,
                                                 ticket: nil, commits: members))
                }
            }
            done += 1
            await update(report(final: false))
        }
        // Anything the model left out still shows up, under its tag.
        await update(report(final: true))
    }

    /// Up to four distinct, descriptive subjects: the newest few are often housekeeping ("PR media",
    /// "Fix lint") that would name the feature after the noise.
    private static func representativeSubjects(_ group: FeatureGroup) -> [String] {
        var seen: Set<String> = []
        var subjects: [String] = []
        for commit in group.commits {
            let cleaned = FeatureGrouper.cleanedSubject(commit.subject, removing: group.ticket ?? "")
            let key = cleaned.lowercased().filter(\.isLetter)
            guard !key.isEmpty, seen.insert(String(key.prefix(24))).inserted else { continue }
            subjects.append(String(cleaned.prefix(80)))
        }
        return Array(subjects.sorted { $0.count > $1.count }.prefix(4))
    }

    /// "watchlist" and "Watchlist" are the same area.
    private static func normalizeAreas(_ groups: inout [FeatureGroup]) {
        var canonical: [String: String] = [:]
        for index in groups.indices {
            let key = groups[index].area.lowercased()
            if let existing = canonical[key] {
                groups[index].area = existing
            } else {
                canonical[key] = groups[index].area
            }
        }
    }
}
#endif
