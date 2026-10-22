import Foundation

/// One file's changes in one commit, as numbered lines ready to show.
struct FileDiff: Sendable {
    struct Line: Identifiable, Sendable {
        enum Kind: Sendable {
            case context, added, removed, hunk, note
        }

        let id: Int
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    /// A row of the side-by-side view: a removed line next to the line that replaced it, a context
    /// line on both sides, or a hunk header across both.
    struct SplitRow: Identifiable, Sendable {
        let id: Int
        let left: Line?
        let right: Line?
        /// Spans both sides (hunk headers and notes).
        let full: Line?
    }

    let lines: [Line]
    let isBinary: Bool
    let addedCount: Int
    let removedCount: Int
    /// Syntax colors for each line, by line id; empty when the language isn't known.
    var tokens: [[SyntaxToken]] = []
    /// Unchanged lines that read differently in the old file (inside a block the commit commented
    /// out, say): their colors on the old side.
    var oldSideTokens: [Int: [SyntaxToken]] = [:]
    /// The lines paired up for the side-by-side view.
    var splitRows: [SplitRow] = []

    /// Whether a line of the new file is shown (a change or its context).
    func contains(newLine number: Int) -> Bool {
        lines.contains { $0.newNumber == number }
    }

    func lineID(forNewLine number: Int) -> Int? {
        lines.first { $0.newNumber == number && $0.kind != .removed }?.id
    }

    func tokens(forLine id: Int) -> [SyntaxToken] {
        id < tokens.count ? tokens[id] : []
    }

    /// Colors for the old side of the side-by-side view.
    func oldSideTokens(forLine id: Int) -> [SyntaxToken] {
        oldSideTokens[id] ?? tokens(forLine: id)
    }

    /// The side-by-side row that shows a line.
    func splitRowID(containing lineID: Int) -> Int? {
        splitRows.first { $0.left?.id == lineID || $0.right?.id == lineID || $0.full?.id == lineID }?.id
    }

    /// Pairs each run of removed lines with the added lines that follow it. Notes ("No newline at
    /// end of file") go after the pair they belong to instead of splitting it.
    static func splitRows(_ lines: [Line]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var removed: [Line] = []
        var added: [Line] = []
        var notes: [Line] = []
        func flush() {
            for k in 0..<max(removed.count, added.count) {
                let left = k < removed.count ? removed[k] : nil
                let right = k < added.count ? added[k] : nil
                rows.append(SplitRow(id: left?.id ?? right?.id ?? 0, left: left, right: right, full: nil))
            }
            rows += notes.map { SplitRow(id: $0.id, left: nil, right: nil, full: $0) }
            removed = []
            added = []
            notes = []
        }
        for line in lines {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            case .note:
                notes.append(line)
            case .context:
                flush()
                rows.append(SplitRow(id: line.id, left: line, right: line, full: nil))
            case .hunk:
                flush()
                rows.append(SplitRow(id: line.id, left: nil, right: nil, full: line))
            }
        }
        flush()
        return rows
    }
}

/// Where to show a diff: a file in a commit of a repository (compared with the commit's first
/// parent, or with `base`), or the file's uncommitted changes, optionally scrolled to a line; or
/// all of them.
struct DiffTarget: Codable, Hashable, Sendable {
    var repositoryID: UUID
    /// Empty for uncommitted changes.
    var commit: String
    var path: String
    var line: Int?
    /// The commit to compare with instead of the first parent: where two branches diverged, say.
    var base: String?
    /// The file's path before a rename, so the diff shows what changed rather than a whole new file.
    var oldPath: String?
    /// Uncommitted changes instead of a commit's.
    var uncommitted: UncommittedSide?
    /// Opens on every file one after another rather than one at a time; `path` can be empty then.
    var allFiles: Bool?
    /// What the window is called while it shows every file: "feature/search since develop".
    var title: String?
}

/// Which of a file's uncommitted changes a diff shows.
enum UncommittedSide: String, Codable, Hashable, Sendable {
    /// What's staged for the next commit, compared with HEAD.
    case staged
    /// What isn't staged yet, compared with what is.
    case unstaged
    /// A file git doesn't track yet: all of it.
    case untracked

    var title: String {
        switch self {
        case .staged: String(localized: "Staged")
        case .unstaged: String(localized: "Not Staged")
        case .untracked: String(localized: "New File")
        }
    }
}

enum FileDiffLoader {
    /// What a target asks for: by default a commit's changes to the file compared with its first
    /// parent (what a merge brought in). `wholeFile` shows every line of the file around the
    /// changes instead of a few lines of context.
    static func load(_ target: DiffTarget, firstParent: String?, in directory: URL, wholeFile: Bool) async throws -> FileDiff {
        let options = ["--no-color", "--no-ext-diff", wholeFile ? "--unified=1000000" : "--unified=4"]
        // A rename shows the changes it made when renames are looked for between both paths.
        let renames = target.oldPath == nil ? [] : ["-M"]
        let paths = ["--", target.path] + (target.oldPath.map { [$0] } ?? [])
        let arguments: [String]
        var allowFailure = false
        switch target.uncommitted {
        case .staged:
            arguments = ["diff", "--cached"] + options + renames + paths
        case .unstaged:
            arguments = ["diff"] + options + paths
        case .untracked:
            // Exits with 1 when the files differ, which they always do here.
            arguments = ["diff", "--no-index"] + options + ["--", "/dev/null", target.path]
            allowFailure = true
        case nil:
            if let base = target.base ?? firstParent {
                arguments = ["diff"] + options + renames + [base, target.commit] + paths
            } else {
                arguments = ["show"] + options + ["--format=", target.commit] + paths
            }
        }
        let output = try await Git.run(arguments, in: directory, allowFailure: allowFailure)
        return await Task.detached(priority: .userInitiated) {
            prepare(parse(String(decoding: output, as: UTF8.self)), path: target.path)
        }.value
    }

    /// Syntax colors and the side-by-side pairs for a parsed diff.
    static func prepare(_ parsed: FileDiff, path: String) -> FileDiff {
        var diff = parsed
        if let highlighter = SyntaxHighlighter(path: path) {
            let highlighted = highlighter.highlight(diff)
            diff.tokens = highlighted.tokens
            diff.oldSideTokens = highlighted.oldSide
        }
        diff.splitRows = FileDiff.splitRows(diff.lines)
        return diff
    }

    static func parse(_ text: String) -> FileDiff {
        var lines: [FileDiff.Line] = []
        var oldNumber = 0
        var newNumber = 0
        var inHunk = false
        var isBinary = false
        var added = 0
        var removed = 0

        func append(_ kind: FileDiff.Line.Kind, _ old: Int?, _ new: Int?, _ text: String) {
            lines.append(FileDiff.Line(id: lines.count, kind: kind, oldNumber: old, newNumber: new, text: text))
        }

        // Split on bytes: Swift treats "\r\n" as one character, so splitting the string on "\n" would
        // leave files with Windows line endings in one piece.
        for raw in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var line = String(decoding: raw, as: UTF8.self)
            if line.utf8.last == UInt8(ascii: "\r") { line.removeLast() }
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,9 @@ optional section header
                let numbers = line.split(separator: " ")
                if numbers.count >= 3 {
                    oldNumber = Int(numbers[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newNumber = Int(numbers[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                inHunk = true
                append(.hunk, nil, nil, line)
            } else if !inHunk {
                if line.hasPrefix("Binary files") { isBinary = true }
            } else if line.hasPrefix("+") {
                append(.added, nil, newNumber, String(line.dropFirst()))
                newNumber += 1
                added += 1
            } else if line.hasPrefix("-") {
                append(.removed, oldNumber, nil, String(line.dropFirst()))
                oldNumber += 1
                removed += 1
            } else if line.hasPrefix(" ") {
                append(.context, oldNumber, newNumber, String(line.dropFirst()))
                oldNumber += 1
                newNumber += 1
            } else if line.hasPrefix("\\") {
                append(.note, nil, nil, String(line.dropFirst(2)))
            } else if line.hasPrefix("diff --git") {
                inHunk = false
            }
        }
        return FileDiff(lines: lines, isBinary: isBinary, addedCount: added, removedCount: removed)
    }
}

/// A file the diff window can switch to: one of the commit's files, or one of the uncommitted ones.
struct DiffFile: Identifiable, Hashable, Sendable {
    let path: String
    let oldPath: String?
    /// git's status letter (A, M, D, R…).
    let status: String
    let uncommitted: UncommittedSide?
    /// Lines added and removed; nil for binary files, new files and where counting them would
    /// download contents (partial clones).
    var added: Int?
    var removed: Int?

    var id: String { Self.id(path: path, uncommitted: uncommitted) }
    var changes: Int { (added ?? 0) + (removed ?? 0) }

    static func id(path: String, uncommitted: UncommittedSide?) -> String {
        (uncommitted?.rawValue ?? "commit") + ":" + path
    }
}

enum DiffFileListLoader {
    /// The files that changed with a diff window's target: the commit's (compared with `base` or
    /// its first parent), or every uncommitted file. `counts`: lines added and removed per file,
    /// left out for partial clones, where counting would download every file's contents.
    static func files(for target: DiffTarget, firstParent: String?, workingTree: WorkingTreeStatus?, in directory: URL,
                      counts: Bool) async throws -> [DiffFile] {
        if target.uncommitted != nil {
            guard let workingTree else { return [] }
            async let staged = counts ? Git.run(["diff", "--cached", "--numstat", "-z", "-M"], in: directory) : nil
            async let unstaged = counts ? Git.run(["diff", "--numstat", "-z"], in: directory) : nil
            let stagedCounts = try await staged.map(parseNumstat) ?? [:]
            let unstagedCounts = try await unstaged.map(parseNumstat) ?? [:]
            func file(_ change: WorkingChange, _ side: UncommittedSide, _ letter: String?) -> DiffFile {
                let count = side == .staged ? stagedCounts[change.path] : side == .unstaged ? unstagedCounts[change.path] : nil
                return DiffFile(path: change.path, oldPath: side == .staged ? change.oldPath : nil, status: letter ?? "M",
                                uncommitted: side, added: count?.added, removed: count?.removed)
            }
            return workingTree.conflicted.map { file($0, .unstaged, "!") }
                + workingTree.staged.map { file($0, .staged, $0.staged) }
                + workingTree.unstaged.map { file($0, .unstaged, $0.unstaged) }
                + workingTree.untracked.map { file($0, .untracked, "A") }
        }
        let renames = counts ? "-M" : "--no-renames"
        let range = (target.base ?? firstParent).map { [$0, target.commit] } ?? ["--root", target.commit]
        async let names = Git.run(["diff-tree", "-r", "-z", "--name-status", "--no-commit-id", renames] + range, in: directory)
        async let numbers = counts ? Git.run(["diff-tree", "-r", "-z", "--numstat", "--no-commit-id", renames] + range, in: directory) : nil
        let listed = CommitDetailsLoader.parseNameStatus(try await names, limit: 5_000).files
        let lineCounts = try await numbers.map(parseNumstat) ?? [:]
        return listed.map { file in
            let count = lineCounts[file.path]
            return DiffFile(path: file.path, oldPath: file.oldPath, status: file.status, uncommitted: nil,
                            added: count?.added, removed: count?.removed)
        }
    }

    /// `--numstat -z` output by path: lines added and removed (nil for binary files). A rename
    /// writes an empty path, then the old and the new one.
    static func parseNumstat(_ data: Data) -> [String: (added: Int?, removed: Int?)] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var counts: [String: (added: Int?, removed: Int?)] = [:]
        var i = 0
        while i < tokens.count {
            let fields = tokens[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard fields.count == 3 else { continue }
            var path = String(fields[2])
            if path.isEmpty {
                guard i + 1 < tokens.count else { break }
                path = tokens[i + 1]
                i += 2
            }
            counts[path] = (Int(fields[0]), Int(fields[1]))
        }
        return counts
    }
}
