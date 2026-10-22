import Foundation

struct RefItem: Identifiable, Hashable {
    let ref: GitRef
    /// Name shown in the sidebar: without the folder for grouped branches.
    let label: String
    var id: String { ref.fullName }
}

struct RefGroup: Identifiable {
    let id: String
    let title: String
    let items: [RefItem]
}

struct RefSection {
    var groups: [RefGroup] = []
    var items: [RefItem] = []
    var count = 0
}

struct RemoteRefSection: Identifiable {
    let name: String
    let section: RefSection
    var id: String { name }
}

/// Worktrees kept in the same folder, like `.claude/worktrees`.
struct WorktreeGroup: Identifiable {
    let id: String
    let title: String
    let worktrees: [Worktree]
}

struct WorktreeSection {
    var groups: [WorktreeGroup] = []
    /// The worktrees alone in their folder.
    var items: [Worktree] = []
    var count = 0
}

/// The sidebar's worktrees, branches, remotes and tags. Branches are grouped by their first path
/// component (feature/, release/…), tags by version (v2.11, v2.12…) and worktrees by the folder
/// they're kept in; newest first everywhere. With a filter, matches are listed flat.
struct RefTree {
    var local = RefSection()
    var remotes: [RemoteRefSection] = []
    var tags = RefSection()
    /// The worktrees other than the one the repository was opened from.
    var worktrees = WorktreeSection()

    var remoteCount: Int { remotes.reduce(0) { $0 + $1.section.count } }

    init(graph: CommitGraph, filter: String) {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let flat = !needle.isEmpty
        let refs = flat ? graph.refs.filter { $0.name.lowercased().contains(needle) } : graph.refs
        let newestFirst: (GitRef, GitRef) -> Bool = { graph.times[Int($0.commit)] > graph.times[Int($1.commit)] }
        worktrees = Self.worktreeSection(graph: graph, needle: needle)

        local = Self.section(
            refs.filter { $0.kind == .local }.sorted(by: newestFirst),
            idPrefix: "local", flat: flat, label: { $0.name }, folding: Self.branchFolder
        )

        var byRemote: [String: [GitRef]] = [:]
        for ref in refs where ref.kind == .remote {
            byRemote[ref.remoteParts?.remote ?? ref.name, default: []].append(ref)
        }
        remotes = byRemote.keys.sorted().map { name in
            RemoteRefSection(name: name, section: Self.section(
                byRemote[name, default: []].sorted(by: newestFirst),
                idPrefix: "remote/\(name)", flat: flat, label: { $0.remoteParts?.branch ?? $0.name }, folding: Self.branchFolder
            ))
        }

        tags = Self.section(
            refs.filter { $0.kind == .tag }.sorted(by: newestFirst),
            idPrefix: "tag", flat: flat, label: { $0.name }, folding: Self.versionFolder
        )
    }

    private static func section(
        _ refs: [GitRef], idPrefix: String, flat: Bool,
        label: (GitRef) -> String, folding: (String) -> (folder: String, label: String)?
    ) -> RefSection {
        var section = RefSection()
        section.count = refs.count
        if flat {
            section.items = refs.map { RefItem(ref: $0, label: label($0)) }
            return section
        }
        var grouped: [String: [RefItem]] = [:]
        var order: [String] = []
        for ref in refs {
            let name = label(ref)
            if let fold = folding(name) {
                if grouped[fold.folder] == nil { order.append(fold.folder) }
                grouped[fold.folder, default: []].append(RefItem(ref: ref, label: fold.label))
            } else {
                section.items.append(RefItem(ref: ref, label: name))
            }
        }
        section.groups = order.map { RefGroup(id: "\(idPrefix)/\($0)", title: $0, items: grouped[$0] ?? []) }
        return section
    }

    /// Newest commit first, worktrees whose folder is gone last. Those kept in the same folder are
    /// grouped under it, in the order of their newest, unless they're all in one; with a filter,
    /// matching names and branches flat.
    private static func worktreeSection(graph: CommitGraph, needle: String) -> WorktreeSection {
        var worktrees = graph.worktrees.filter { !$0.isCurrent }
        if !needle.isEmpty {
            worktrees = worktrees.filter { $0.name.lowercased().contains(needle) || ($0.branchName?.lowercased().contains(needle) ?? false) }
        }
        let time: (Worktree) -> Int64 = { $0.commit >= 0 ? graph.times[Int($0.commit)] : 0 }
        worktrees.sort { a, b in
            if a.isMissing != b.isMissing { return !a.isMissing }
            if time(a) != time(b) { return time(a) > time(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var section = WorktreeSection(count: worktrees.count)
        var byLocation: [String: [Worktree]] = [:]
        var order: [String] = []
        for worktree in worktrees {
            if byLocation[worktree.location] == nil { order.append(worktree.location) }
            byLocation[worktree.location, default: []].append(worktree)
        }
        guard needle.isEmpty, order.count > 1 else {
            section.items = worktrees
            return section
        }
        for location in order {
            let kept = byLocation[location] ?? []
            if kept.count > 1 {
                section.groups.append(WorktreeGroup(id: "worktrees/\(location)", title: location, worktrees: kept))
            }
        }
        section.items = worktrees.filter { byLocation[$0.location]?.count == 1 }
        return section
    }

    /// `feature/login` → folder `feature`, label `login`.
    private static func branchFolder(_ name: String) -> (folder: String, label: String)? {
        guard let slash = name.firstIndex(of: "/") else { return nil }
        let label = name[name.index(after: slash)...]
        guard !label.isEmpty else { return nil }
        return (String(name[..<slash]), String(label))
    }

    /// `v2.11.3-rc.4` → folder `v2.11`, full name as label.
    private static func versionFolder(_ name: String) -> (folder: String, label: String)? {
        guard let match = name.firstMatch(of: #/^v?(\d+)\.(\d+)/#) else { return nil }
        return ("v\(match.1).\(match.2)", name)
    }
}
