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

    let lines: [Line]
    let isBinary: Bool
    let addedCount: Int
    let removedCount: Int

    /// Whether a line of the new file is shown (a change or its context).
    func contains(newLine number: Int) -> Bool {
        lines.contains { $0.newNumber == number }
    }

    func lineID(forNewLine number: Int) -> Int? {
        lines.first { $0.newNumber == number && $0.kind != .removed }?.id
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
        return parse(String(decoding: output, as: UTF8.self))
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

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
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
