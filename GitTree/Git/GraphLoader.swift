import Foundation

/// Reads a repository's full history and refs with two git commands and turns them into a `CommitGraph`.
enum GraphLoader {
    /// One commit per line: hash, parents, author, email, author time, subject — separated by 0x1F.
    private static let logFormat = "%H%x1f%P%x1f%aN%x1f%aE%x1f%at%x1f%s"

    static func load(repositoryAt directory: URL) async throws -> CommitGraph {
        async let refsData = Git.run(
            ["for-each-ref", "--format=%(HEAD)%1f%(refname)%1f%(objectname)%1f%(*objectname)", "refs/heads", "refs/remotes", "refs/tags"],
            in: directory
        )
        async let headData = Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory, allowFailure: true)
        // An empty repository makes `git log` fail; that's an empty graph, not an error.
        async let logData = Git.run(
            ["log", "--branches", "--remotes", "--tags", "--date-order", "--format=\(logFormat)"],
            in: directory,
            allowFailure: true
        )
        let refs = try await refsData
        let head = try await headData
        let log = try await logData
        return await Task.detached(priority: .userInitiated) {
            build(log: log, refs: refs, head: head)
        }.value
    }

    static func build(log: Data, refs refData: Data, head headData: Data) -> CommitGraph {
        var ids: [ObjectID] = []
        var parentIDs: [ObjectID] = []
        var parentStart: [Int32] = [0]
        var authorOf: [Int32] = []
        var authors: [String] = []
        var emails: [String] = []
        var authorLookup: [String: Int32] = [:]
        var times: [Int64] = []
        var subjects: [String] = []

        let estimate = max(16, log.count / 110)
        ids.reserveCapacity(estimate)
        parentIDs.reserveCapacity(estimate + estimate / 8)
        parentStart.reserveCapacity(estimate + 1)
        authorOf.reserveCapacity(estimate)
        times.reserveCapacity(estimate)
        subjects.reserveCapacity(estimate)

        log.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let end = raw.count
            var lineStart = 0
            while lineStart < end {
                let lineEnd: Int
                if let hit = memchr(base + lineStart, 0x0A, end - lineStart) {
                    lineEnd = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                } else {
                    lineEnd = end
                }
                defer { lineStart = lineEnd + 1 }

                func fieldEnd(from start: Int) -> Int {
                    var i = start
                    while i < lineEnd && base[i] != 0x1F { i += 1 }
                    return i
                }
                func text(_ from: Int, _ to: Int) -> String {
                    to > from ? String(decoding: UnsafeBufferPointer(start: base + from, count: to - from), as: UTF8.self) : ""
                }

                let hashEnd = fieldEnd(from: lineStart)
                let parentsEnd = fieldEnd(from: hashEnd + 1)
                let nameEnd = fieldEnd(from: parentsEnd + 1)
                let emailEnd = fieldEnd(from: nameEnd + 1)
                let timeEnd = fieldEnd(from: emailEnd + 1)
                guard timeEnd < lineEnd,
                      let id = ObjectID(UnsafeBufferPointer(start: base + lineStart, count: hashEnd - lineStart))
                else { continue }

                var p = hashEnd + 1
                while p < parentsEnd {
                    var q = p
                    while q < parentsEnd && base[q] != 0x20 { q += 1 }
                    if let parent = ObjectID(UnsafeBufferPointer(start: base + p, count: q - p)) {
                        parentIDs.append(parent)
                    }
                    p = q + 1
                }
                parentStart.append(Int32(parentIDs.count))

                let name = text(parentsEnd + 1, nameEnd)
                if let known = authorLookup[name] {
                    authorOf.append(known)
                } else {
                    let index = Int32(authors.count)
                    authorLookup[name] = index
                    authors.append(name)
                    emails.append(text(nameEnd + 1, emailEnd))
                    authorOf.append(index)
                }

                var time: Int64 = 0
                for i in (emailEnd + 1)..<timeEnd where base[i] >= 0x30 && base[i] <= 0x39 {
                    time = time * 10 + Int64(base[i] - 0x30)
                }
                times.append(time)
                subjects.append(text(timeEnd + 1, lineEnd))
                ids.append(id)
            }
        }

        var indexByID = [ObjectID: Int32](minimumCapacity: ids.count)
        for (index, id) in ids.enumerated() { indexByID[id] = Int32(index) }
        let parentList = parentIDs.map { indexByID[$0] ?? -1 }

        var refs: [GitRef] = []
        for line in String(decoding: refData, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let fullName = String(parts[1])
            let target = parts[3].isEmpty ? parts[2] : parts[3]
            guard let oid = ObjectID(hex: String(target)), let commit = indexByID[oid] else { continue }
            let kind: GitRef.Kind
            let name: String
            if fullName.hasPrefix("refs/heads/") {
                kind = .local
                name = String(fullName.dropFirst("refs/heads/".count))
            } else if fullName.hasPrefix("refs/remotes/") {
                name = String(fullName.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
                kind = .remote
            } else if fullName.hasPrefix("refs/tags/") {
                kind = .tag
                name = String(fullName.dropFirst("refs/tags/".count))
            } else {
                continue
            }
            refs.append(GitRef(kind: kind, fullName: fullName, name: name, commit: commit, isHead: parts[0] == "*"))
        }

        let headHex = String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let headCommit = ObjectID(hex: headHex).flatMap { indexByID[$0] } ?? -1

        return CommitGraph(
            ids: ids,
            parentStart: parentStart,
            parentList: parentList,
            authorOf: authorOf,
            authors: authors,
            authorEmails: emails,
            times: times,
            subjects: subjects,
            refs: refs,
            indexByID: indexByID,
            headCommit: headCommit,
            ticketPrefixes: TicketDetector.prefixes(in: subjects)
        )
    }
}

/// Finds issue-tracker prefixes (PROJ in PROJ-1234) that appear often enough to be real, not noise like UTF-8.
enum TicketDetector {
    static func prefixes(in subjects: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for subject in subjects {
            let scanned = subject.utf8.withContiguousStorageIfAvailable { buffer -> Bool in
                scan(buffer, into: &counts)
                return true
            } ?? false
            if !scanned {
                Array(subject.utf8).withUnsafeBufferPointer { scan($0, into: &counts) }
            }
        }
        let threshold = max(25, subjects.count / 200)
        return counts.filter { $0.value >= threshold }.sorted { $0.value > $1.value }.map(\.key)
    }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>, into counts: inout [String: Int]) {
        @inline(__always) func isUpper(_ c: UInt8) -> Bool { c >= 0x41 && c <= 0x5A }
        @inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        @inline(__always) func isWord(_ c: UInt8) -> Bool {
            isUpper(c) || isDigit(c) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
        }
        var i = 0
        let n = b.count
        while i < n {
            guard isUpper(b[i]), i == 0 || !isWord(b[i - 1]) else { i += 1; continue }
            var j = i + 1
            while j < n && (isUpper(b[j]) || isDigit(b[j])) { j += 1 }
            let length = j - i
            guard length >= 2, length <= 10, j < n, b[j] == 0x2D else { i = j; continue }
            var k = j + 1
            while k < n && isDigit(b[k]) { k += 1 }
            let digits = k - j - 1
            if digits >= 1 && digits <= 6 && (k == n || !isWord(b[k])) {
                counts[String(decoding: UnsafeBufferPointer(rebasing: b[i..<j]), as: UTF8.self), default: 0] += 1
            }
            i = k
        }
    }
}
