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

/// Where to show a diff: a file in a commit of a repository, optionally scrolled to a line.
struct DiffTarget: Codable, Hashable, Sendable {
    var repositoryID: UUID
    var commit: String
    var path: String
    var line: Int?
}

enum FileDiffLoader {
    /// Compares against the first parent (what a merge brought in). `wholeFile` shows every line
    /// of the file around the changes instead of a few lines of context.
    static func load(commit: String, firstParent: String?, path: String, in directory: URL, wholeFile: Bool) async throws -> FileDiff {
        let context = wholeFile ? "--unified=1000000" : "--unified=4"
        let arguments: [String]
        if let firstParent {
            arguments = ["diff", "--no-color", "--no-ext-diff", context, firstParent, commit, "--", path]
        } else {
            arguments = ["show", "--no-color", "--no-ext-diff", "--format=", context, commit, "--", path]
        }
        let output = try await Git.run(arguments, in: directory)
        var diff = parse(String(decoding: output, as: UTF8.self))
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
