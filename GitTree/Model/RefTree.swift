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

/// The sidebar's branches, remotes and tags. Branches are grouped by their first path component
/// (feature/, release/…) and tags by version (v2.11, v2.12…); newest first everywhere.
/// With a filter, matches are listed flat.
struct RefTree {
    var local = RefSection()
    var remotes: [RemoteRefSection] = []
    var tags = RefSection()

    var remoteCount: Int { remotes.reduce(0) { $0 + $1.section.count } }

    init(graph: CommitGraph, filter: String) {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let flat = !needle.isEmpty
        let refs = flat ? graph.refs.filter { $0.name.lowercased().contains(needle) } : graph.refs
        let newestFirst: (GitRef, GitRef) -> Bool = { graph.times[Int($0.commit)] > graph.times[Int($1.commit)] }

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
