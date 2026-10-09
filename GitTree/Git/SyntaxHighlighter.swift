import Foundation

/// A colored stretch of a line: a keyword, a string, a comment…
struct SyntaxToken: Sendable {
    enum Kind: Sendable {
        case keyword, string, comment, number, type, attribute
    }

    let range: Range<String.Index>
    let kind: Kind
}

/// Colors code by file extension with a small scanner: keywords, strings, comments, numbers, types
/// and attributes. Good enough for reading diffs; it isn't a parser.
struct SyntaxHighlighter: Sendable {
    struct Language: Sendable {
        var keywords: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<UInt8> = [UInt8(ascii: "\"")]
        /// `@Something`: annotations, attributes and decorators.
        var annotations = false
        /// `#if`, `#include`: directives at the start of a line.
        var directives = false
        /// Capitalized names are types.
        var capitalizedTypes = true
        /// `$name` and `${name}` are variables.
        var dollarVariables = false
        /// `<tag attribute="value">`.
        var markup = false
        /// `key:` at the start of a line.
        var keys = false
        /// `# Heading` lines.
        var headings = false
    }

    /// What carries over from one line to the next.
    struct State: Equatable, Sendable {
        var inComment = false
        /// Inside a markup tag whose attributes continue on the next lines.
        var inTag = false
    }

    let language: Language
    private let lineComments: [[UInt8]]
    private let blockOpen: [UInt8]
    private let blockClose: [UInt8]

    init?(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard let language = Self.language(name: name, extension: ext) else { return nil }
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf8) }
        blockOpen = Array((language.blockComment?.open ?? "").utf8)
        blockClose = Array((language.blockComment?.close ?? "").utf8)
    }

    /// Tokens for every line of a diff, indexed like its lines. Block comments carry on from line to
    /// line, separately for the old and the new side; a hunk starts outside any comment.
    func tokens(for diff: FileDiff) -> [[SyntaxToken]] {
        var result: [[SyntaxToken]] = []
        result.reserveCapacity(diff.lines.count)
        var old = State()
        var new = State()
        for line in diff.lines {
            switch line.kind {
            case .hunk, .note:
                old = State()
                new = State()
                result.append([])
            case .removed:
                let scanned = scan(line.text, state: old)
                old = scanned.state
                result.append(scanned.tokens)
            case .added:
                let scanned = scan(line.text, state: new)
                new = scanned.state
                result.append(scanned.tokens)
            case .context:
                let scanned = scan(line.text, state: new)
                old = old == new ? scanned.state : scan(line.text, state: old).state
                new = scanned.state
                result.append(scanned.tokens)
            }
        }
        return result
    }

    func scan(_ text: String, state: State) -> (tokens: [SyntaxToken], state: State) {
        let bytes = Array(text.utf8)
        let count = bytes.count
        var spans: [(start: Int, end: Int, kind: SyntaxToken.Kind)] = []
        var inComment = state.inComment
        var inTag = state.inTag
        var i = 0

        func index(_ offset: Int) -> String.Index { text.utf8.index(text.utf8.startIndex, offsetBy: offset) }
        func tokens() -> [SyntaxToken] {
            spans.filter { $0.end > $0.start }.map { SyntaxToken(range: index($0.start)..<index($0.end), kind: $0.kind) }
        }
        func matches(_ needle: [UInt8], at position: Int) -> Bool {
            guard !needle.isEmpty, position + needle.count <= count else { return false }
            for k in 0..<needle.count where bytes[position + k] != needle[k] { return false }
            return true
        }
        func find(_ needle: [UInt8], from position: Int) -> Int? {
            var p = position
            while p < count {
                if matches(needle, at: p) { return p }
                p += 1
            }
            return nil
        }
        func scanIdentifier(from position: Int) -> Int {
            var j = position
            while j < count, isIdentifier(bytes[j]) { j += 1 }
            return j
        }

        if inComment, !blockClose.isEmpty {
            guard let end = find(blockClose, from: 0) else {
                return ([SyntaxToken(range: text.startIndex..<text.endIndex, kind: .comment)], State(inComment: true, inTag: inTag))
            }
            i = end + blockClose.count
            spans.append((0, i, .comment))
            inComment = false
        }

        // Things that only count at the start of a line.
        var first = i
        while first < count, bytes[first] == UInt8(ascii: " ") || bytes[first] == UInt8(ascii: "\t") { first += 1 }
        if first < count {
            if language.headings, bytes[first] == UInt8(ascii: "#") {
                return ([SyntaxToken(range: index(first)..<text.endIndex, kind: .keyword)], State())
            }
            if language.directives, bytes[first] == UInt8(ascii: "#"), first + 1 < count, isLetter(bytes[first + 1]) {
                let end = scanIdentifier(from: first + 1)
                spans.append((first, end, .keyword))
                i = end
            }
            if language.keys {
                var start = first
                if start + 1 < count, bytes[start] == UInt8(ascii: "-"), bytes[start + 1] == UInt8(ascii: " ") { start += 2 }
                var end = start
                while end < count, isIdentifier(bytes[end]) || bytes[end] == UInt8(ascii: "-") || bytes[end] == UInt8(ascii: ".") { end += 1 }
                if end > start, end < count, bytes[end] == UInt8(ascii: ":"), end + 1 == count || bytes[end + 1] == UInt8(ascii: " ") {
                    spans.append((start, end, .attribute))
                    i = end
                }
            }
        }

        scanning: while i < count {
            let c = bytes[i]
            for prefix in lineComments where matches(prefix, at: i) {
                // `#` only starts a comment at a word boundary in shell-like languages (`$#`, `a#b`).
                if prefix == [UInt8(ascii: "#")], i > 0, !isSpace(bytes[i - 1]) { break }
                spans.append((i, count, .comment))
                break scanning
            }
            if matches(blockOpen, at: i) {
                if let end = find(blockClose, from: i + blockOpen.count) {
                    let close = end + blockClose.count
                    spans.append((i, close, .comment))
                    i = close
                    continue
                }
                spans.append((i, count, .comment))
                inComment = true
                break
            }
            if language.markup {
                if c == UInt8(ascii: "<"), i + 1 < count, isLetter(bytes[i + 1]) || isTagMark(bytes[i + 1]) {
                    var j = i + 1
                    while j < count, isTagMark(bytes[j]) { j += 1 }
                    while j < count, isMarkupName(bytes[j]) { j += 1 }
                    spans.append((i, j, .keyword))
                    i = j
                    inTag = true
                    continue
                }
                if inTag, c == UInt8(ascii: ">") || (c == UInt8(ascii: "/") || c == UInt8(ascii: "?")) && i + 1 < count && bytes[i + 1] == UInt8(ascii: ">") {
                    let end = c == UInt8(ascii: ">") ? i + 1 : i + 2
                    spans.append((i, end, .keyword))
                    i = end
                    inTag = false
                    continue
                }
                if inTag, isLetter(c) {
                    var j = i
                    while j < count, isMarkupName(bytes[j]) { j += 1 }
                    spans.append((i, j, .attribute))
                    i = j
                    continue
                }
                if !inTag {
                    i += 1
                    continue
                }
            }
            if language.quotes.contains(c) {
                var j = i + 1
                while j < count {
                    if bytes[j] == UInt8(ascii: "\\") { j += 2; continue }
                    if bytes[j] == c { j += 1; break }
                    j += 1
                }
                let end = min(j, count)
                spans.append((i, end, .string))
                i = end
                continue
            }
            if isDigit(c), i == 0 || !isIdentifier(bytes[i - 1]) {
                var j = i + 1
                while j < count {
                    let d = bytes[j]
                    if d == UInt8(ascii: "."), j + 1 < count, isDigit(bytes[j + 1]) { j += 1; continue }
                    guard isIdentifier(d) else { break }
                    j += 1
                }
                spans.append((i, j, .number))
                i = j
                continue
            }
            if language.annotations, c == UInt8(ascii: "@"), i + 1 < count, isIdentifierStart(bytes[i + 1]) {
                var j = scanIdentifier(from: i + 1)
                while j + 1 < count, bytes[j] == UInt8(ascii: "."), isIdentifierStart(bytes[j + 1]) { j = scanIdentifier(from: j + 1) }
                spans.append((i, j, .attribute))
                i = j
                continue
            }
            if language.dollarVariables, c == UInt8(ascii: "$"), i + 1 < count {
                if bytes[i + 1] == UInt8(ascii: "{"), let close = find([UInt8(ascii: "}")], from: i + 2) {
                    spans.append((i, close + 1, .attribute))
                    i = close + 1
                    continue
                }
                if isIdentifierStart(bytes[i + 1]) || isDigit(bytes[i + 1]) {
                    let end = scanIdentifier(from: i + 1)
                    spans.append((i, end, .attribute))
                    i = end
                    continue
                }
            }
            if isIdentifierStart(c) {
                let end = scanIdentifier(from: i)
                if let word = String(bytes: bytes[i..<end], encoding: .utf8) {
                    if language.keywords.contains(word) {
                        spans.append((i, end, .keyword))
                    } else if language.capitalizedTypes, isUppercase(c), end - i > 1 {
                        spans.append((i, end, .type))
                    }
                }
                i = end
                continue
            }
            i += 1
        }
        return (tokens(), State(inComment: inComment, inTag: inTag))
    }

    // MARK: Characters

    private func isLetter(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
    }

    private func isUppercase(_ c: UInt8) -> Bool { c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") }
    private func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
    private func isSpace(_ c: UInt8) -> Bool { c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") }
    private func isTagMark(_ c: UInt8) -> Bool { c == UInt8(ascii: "/") || c == UInt8(ascii: "?") || c == UInt8(ascii: "!") }

    private func isMarkupName(_ c: UInt8) -> Bool {
        isIdentifier(c) || c == UInt8(ascii: ":") || c == UInt8(ascii: "-") || c == UInt8(ascii: ".")
    }

    /// Letters, `_`, and anything outside ASCII, so tokens never split a multi-byte character.
    private func isIdentifierStart(_ c: UInt8) -> Bool {
        isLetter(c) || c == UInt8(ascii: "_") || c >= 0x80
    }

    private func isIdentifier(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    // MARK: Languages

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static let cStyle = (lineComments: ["//"], blockComment: (open: "/*", close: "*/"))
    private static let quotes = Set([UInt8(ascii: "\""), UInt8(ascii: "'")])

    private static func language(name: String, extension ext: String) -> Language? {
        switch name {
        case "dockerfile":
            return shell(extra: "FROM RUN COPY ADD CMD ENTRYPOINT ENV ARG WORKDIR EXPOSE USER LABEL VOLUME AS")
        case "makefile":
            return shell(extra: "")
        case "gemfile", "podfile", "fastfile", "appfile", "brewfile", "dangerfile":
            return ruby
        default:
            break
        }
        switch ext {
        case "swift":
            return Language(
                keywords: words("""
                let var func if else guard return struct class enum protocol extension import switch case default for in while \
                repeat break continue fallthrough throw throws rethrows try catch do as is nil true false self Self super init deinit \
                subscript static private fileprivate internal public open package final override mutating nonmutating weak unowned \
                lazy inout some any async await actor where typealias associatedtype defer get set willSet didSet convenience \
                required indirect operator isolated nonisolated consuming borrowing macro
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, annotations: true, directives: true)
        case "kt", "kts", "gradle", "groovy":
            return Language(
                keywords: words("""
                package import class interface object fun val var if else when for while do return break continue throw try catch \
                finally in is as null true false this super override open abstract sealed data inner enum companion private \
                protected public internal lateinit const suspend inline crossinline noinline reified by get set init constructor \
                typealias vararg out where annotation operator infix tailrec external expect actual value def
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, quotes: quotes, annotations: true)
        case "java":
            return Language(
                keywords: words("""
                package import class interface enum extends implements public private protected static final abstract native \
                synchronized transient volatile new return if else switch case default for while do break continue throw throws try \
                catch finally instanceof this super null true false void boolean byte char short int long float double var record \
                sealed permits yield assert
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, quotes: quotes, annotations: true)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return Language(
                keywords: words("""
                const let var function return if else for while do switch case default break continue new delete typeof instanceof \
                in of class extends super this null undefined true false import export from as async await yield try catch finally \
                throw interface type enum implements public private protected readonly static declare namespace abstract keyof void
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment,
                quotes: quotes.union([UInt8(ascii: "`")]), annotations: true, dollarVariables: false)
        case "py":
            return Language(
                keywords: words("""
                def class return if elif else for while in not and or is None True False import from as with try except finally \
                raise pass break continue lambda yield global nonlocal assert del async await match case self
                """),
                lineComments: ["#"], quotes: quotes, annotations: true)
        case "go":
            return Language(
                keywords: words("""
                package import func return if else for range switch case default break continue go defer select chan map struct \
                interface type const var nil true false fallthrough goto
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment,
                quotes: quotes.union([UInt8(ascii: "`")]), capitalizedTypes: false)
        case "rs":
            return Language(
                keywords: words("""
                fn let mut pub use mod struct enum impl trait for in if else match loop while return break continue as ref self Self \
                super crate where type const static unsafe extern move async await dyn true false Some None Ok Err
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment)
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh":
            return Language(
                keywords: words("""
                auto break case char const continue default do double else enum extern float for goto if inline int long register \
                return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false nullptr \
                NULL class namespace template typename public private protected virtual override new delete this using try catch \
                throw nil YES NO self super id instancetype nonatomic strong weak copy assign readonly readwrite nullable nonnull
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, quotes: quotes,
                annotations: true, directives: true, capitalizedTypes: false)
        case "rb", "rake", "gemspec", "podspec":
            return ruby
        case "sh", "bash", "zsh", "command":
            return shell(extra: "")
        case "json":
            return Language(keywords: words("true false null"), capitalizedTypes: false)
        case "yml", "yaml":
            return Language(keywords: words("true false null yes no on off"), lineComments: ["#"], quotes: quotes,
                            capitalizedTypes: false, keys: true)
        case "xml", "html", "htm", "plist", "svg", "xib", "storyboard", "xsd", "vue":
            return Language(blockComment: (open: "<!--", close: "-->"), quotes: quotes, capitalizedTypes: false, markup: true)
        case "md", "markdown":
            return Language(quotes: [UInt8(ascii: "`")], capitalizedTypes: false, headings: true)
        case "css", "scss", "less":
            return Language(keywords: words("important"), lineComments: ext == "css" ? [] : ["//"],
                            blockComment: cStyle.blockComment, quotes: quotes, capitalizedTypes: false)
        case "toml", "ini", "properties", "cfg", "conf", "env":
            return Language(keywords: words("true false"), lineComments: ["#", ";"], quotes: quotes, capitalizedTypes: false)
        default:
            return nil
        }
    }

    private static var ruby: Language {
        Language(
            keywords: words("""
            def end class module if elsif else unless while until for in do return yield begin rescue ensure raise nil true false \
            self super require require_relative include extend attr_reader attr_writer attr_accessor private protected public \
            then case when and or not lambda proc
            """),
            lineComments: ["#"], quotes: quotes)
    }

    private static func shell(extra: String) -> Language {
        Language(
            keywords: words("""
            if then else elif fi for while until do done case esac in function return local export readonly set unset echo exit \
            source shift trap \(extra)
            """),
            lineComments: ["#"], quotes: quotes, capitalizedTypes: false, dollarVariables: true)
    }
}
