import Foundation

/// A working tree of a repository, as `git worktree list` reports it: the repository's own folder,
/// or one added with `git worktree add` (Claude Code's `.claude/worktrees/…`, say). They share the
/// history and the branches; each has a commit checked out and uncommitted changes of its own.
struct Worktree: Identifiable, Hashable, Sendable {
    /// Its folder.
    let path: String
    /// Shown in the sidebar and on graph labels: the folder's name, or for one named after the
    /// repository (`~/.codex/worktrees/2165/acme`) the folder it's in (`2165`).
    let name: String
    /// Where it's kept, which groups the worktrees kept together: `.claude/worktrees` inside the
    /// repository, `~/.codex/worktrees` elsewhere.
    let location: String
    /// The commit checked out there; nil before the first commit.
    let head: ObjectID?
    /// That commit in the history, or -1.
    let commit: Int32
    /// The branch checked out there (`refs/heads/feature/login`); nil when its HEAD is detached.
    let branch: String?
    /// The repository's own folder, which git lists first.
    let isMain: Bool
    /// The one the repository was opened from.
    let isCurrent: Bool
    /// Why `git worktree lock` locked it (empty when no reason was given); nil when it isn't locked.
    let lockReason: String?
    /// Its folder is gone (git calls it prunable); `git worktree prune` would forget it.
    let isMissing: Bool

    var id: String { path }

    /// `feature/login`, without `refs/heads/`.
    var branchName: String? { branch.map(GitRef.shortName(fullName:)) }
}

extension Worktree {
    /// One worktree as `git worktree list --porcelain -z` describes it.
    struct Listing: Sendable {
        var path: String
        var head: ObjectID?
        var branch: String?
        var isBare = false
        var lockReason: String?
        var isMissing = false
    }

    /// Reads `git worktree list --porcelain -z`: for each worktree `worktree <path>`, `HEAD <hash>`,
    /// `branch <ref>` or `detached`, and maybe `bare`, `locked [<reason>]` and `prunable [<reason>]`,
    /// each field ending in NUL and each worktree in an empty field.
    static func listings(_ data: Data) -> [Listing] {
        var listings: [Listing] = []
        for field in data.split(separator: 0) {
            let text = String(decoding: field, as: UTF8.self)
            let space = text.firstIndex(of: " ")
            let key = space.map { String(text[..<$0]) } ?? text
            let value = space.map { String(text[text.index(after: $0)...]) } ?? ""
            if key == "worktree" {
                listings.append(Listing(path: value))
                continue
            }
            guard !listings.isEmpty else { continue }
            let last = listings.count - 1
            switch key {
            case "HEAD":
                // All zeros before the first commit.
                if value.contains(where: { $0 != "0" }) { listings[last].head = ObjectID(hex: value) }
            case "branch": listings[last].branch = value
            case "bare": listings[last].isBare = true
            case "locked": listings[last].lockReason = value
            case "prunable": listings[last].isMissing = true
            default: break
            }
        }
        return listings
    }

    /// The worktrees listed, with their commits found in the history; `directory` is the folder the
    /// repository was opened from. A bare repository itself isn't one.
    static func resolve(_ listings: [Listing], indexByID: [ObjectID: Int32], openedFrom directory: String) -> [Worktree] {
        guard let main = listings.first else { return [] }
        var repositoryName = URL(fileURLWithPath: main.path).lastPathComponent
        if main.isBare, repositoryName.hasSuffix(".git"), repositoryName.count > 4 { repositoryName.removeLast(4) }
        let mainPath = main.isBare ? nil : URL(fileURLWithPath: main.path).standardizedFileURL.path
        let current = resolvedPath(directory)
        return listings.enumerated().compactMap { index, listing in
            guard !listing.isBare else { return nil }
            let url = URL(fileURLWithPath: listing.path)
            var folder = url.deletingLastPathComponent()
            var name = url.lastPathComponent
            // Named after the repository (`~/.codex/worktrees/2165/acme`): the folder above tells it apart.
            if index > 0, name == repositoryName, folder.path != "/" {
                name = folder.lastPathComponent
                folder = folder.deletingLastPathComponent()
            }
            return Worktree(
                path: listing.path, name: name, location: location(of: folder, mainPath: index > 0 ? mainPath : nil),
                head: listing.head, commit: listing.head.flatMap { indexByID[$0] } ?? -1, branch: listing.branch,
                isMain: index == 0, isCurrent: resolvedPath(listing.path) == current,
                lockReason: listing.lockReason, isMissing: listing.isMissing
            )
        }
    }

    /// Inside the repository's own folder, the path from there (`.claude/worktrees`); elsewhere the
    /// whole path, from `~` when it's in the home folder.
    private static func location(of folder: URL, mainPath: String?) -> String {
        let path = folder.standardizedFileURL.path
        if let mainPath, path.hasPrefix(mainPath + "/") { return String(path.dropFirst(mainPath.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// The path with symbolic links resolved (`/tmp` is `/private/tmp`), as git lists worktrees.
    private static func resolvedPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
