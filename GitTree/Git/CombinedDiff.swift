import Foundation

/// Every listed file's diff at once, for the diff window's All Files: a commit's changes (or the
/// changes between two commits) from one patch split by file; uncommitted ones from the staged and
/// unstaged patches and each new file.
enum CombinedDiffLoader {
    /// Lines shown at most; the files after that open one at a time.
    static let lineLimit = 30_000
    /// New files read at most, one command each.
    static let untrackedLimit = 100

    /// The diffs of `files`, in the order given, by `DiffFile.id`, until `lineLimit` lines; and
    /// whether every file is in. Partial clones skip rename detection, which would download more
    /// files' contents.
    static func load(_ target: DiffTarget, firstParent: String?, files: [DiffFile], in directory: URL,
                     detectRenames: Bool) async throws -> (diffs: [String: FileDiff], complete: Bool) {
        let options = ["--no-color", "--no-ext-diff", "--unified=4"]
        let renames = detectRenames ? "-M" : "--no-renames"
        var patches: [(side: UncommittedSide?, output: Data)] = []
        var untracked: [String: Data] = [:]
        if target.uncommitted != nil {
            async let staged = Git.run(["diff", "--cached"] + options + [renames], in: directory)
            async let unstaged = Git.run(["diff"] + options, in: directory)
            patches = [(.staged, try await staged), (.unstaged, try await unstaged)]
            for file in files.filter({ $0.uncommitted == .untracked }).prefix(untrackedLimit) {
                // Exits with 1 when the files differ, which they always do here.
                untracked[file.path] = try await Git.run(["diff", "--no-index"] + options + ["--", "/dev/null", file.path],
                                                         in: directory, allowFailure: true)
            }
        } else if let base = target.base ?? firstParent {
            patches = [(nil, try await Git.run(["diff"] + options + [renames, base, target.commit], in: directory))]
        } else {
            patches = [(nil, try await Git.run(["show", "--format="] + options + [target.commit], in: directory))]
        }
        return await Task.detached(priority: .userInitiated) {
            var sections: [String: String] = [:]
            for (side, output) in patches {
                for (path, text) in split(String(decoding: output, as: UTF8.self)) {
                    sections[DiffFile.id(path: path, uncommitted: side)] = text
                }
            }
            for (path, output) in untracked {
                sections[DiffFile.id(path: path, uncommitted: .untracked)] = String(decoding: output, as: UTF8.self)
            }
            var diffs: [String: FileDiff] = [:]
            var lines = 0
            for file in files {
                guard lines < lineLimit else { return (diffs, false) }
                guard let text = sections[file.id] else { continue }
                let parsed = FileDiffLoader.parse(text)
                lines += parsed.lines.count
                diffs[file.id] = FileDiffLoader.prepare(parsed, path: file.path)
            }
            return (diffs, true)
        }.value
    }

    /// A patch's files, each with its part of the patch, by the path git gives them (the new one
    /// for a rename). Unresolved conflicts come as `diff --cc`.
    static func split(_ patch: String) -> [(path: String, text: String)] {
        var sections: [[Substring]] = []
        // Split on bytes: Swift reads "\r\n" as one character, which would hide where files start.
        for raw in patch.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let line = Substring(raw)
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                sections.append([line])
            } else if !sections.isEmpty {
                sections[sections.count - 1].append(line)
            }
        }
        return sections.compactMap { section in
            var oldSide: String?
            var newSide: String?
            var renamedTo: String?
            for line in section.prefix(12) {
                if line.hasPrefix("@@") { break }
                if line.hasPrefix("rename to ") { renamedTo = unquoted(line.dropFirst("rename to ".count)) }
                if line.hasPrefix("--- ") { oldSide = side(line.dropFirst(4), prefix: "a/") }
                if line.hasPrefix("+++ ") { newSide = side(line.dropFirst(4), prefix: "b/") }
            }
            let first = section[0]
            let header = first.hasPrefix("diff --git ") ? headerPath(first.dropFirst("diff --git ".count))
                : first.split(separator: " ", maxSplits: 2).last.map { unquoted($0) }
            guard let path = renamedTo ?? newSide ?? oldSide ?? header else { return nil }
            return (path, section.joined(separator: "\n"))
        }
    }

    /// `a/path` or `b/path` from a `---`/`+++` line; nil for `/dev/null` (a new or deleted file).
    private static func side(_ text: Substring, prefix: String) -> String? {
        // A path with a space ends with a tab, for tools that read patches.
        let path = unquoted(text.hasSuffix("\t") ? text.dropLast() : text)
        guard path != "/dev/null" else { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The path in `a/<path> b/<path>` when both are the same (binary files have no other line naming it).
    private static func headerPath(_ text: Substring) -> String? {
        let count = text.count
        guard count > 5, (count - 5) % 2 == 0 else { return nil }
        let length = (count - 5) / 2
        let path = String(text.dropFirst(2).prefix(length))
        return text == "a/\(path) b/\(path)" ? path : nil
    }

    /// git puts paths with tabs, newlines, quotes or backslashes in quotes, with C escapes.
    static func unquoted(_ text: Substring) -> String {
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return String(text) }
        var bytes: [UInt8] = []
        var iterator = Array(text.dropFirst().dropLast().utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Three octal digits: one byte of a UTF-8 name.
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit) - Int(UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
