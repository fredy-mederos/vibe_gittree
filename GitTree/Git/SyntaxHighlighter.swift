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
        /// Comment markers that only count at the start of a line (`;` in INI files).
        var lineStartComments: [String] = []
        var blockComment: (open: String, close: String)?
        /// Block comments nest (Swift, Kotlin, Rust).
        var nestedComments = false
        var quotes: Set<UInt8> = [UInt8(ascii: "\"")]
        /// Strings that can span lines: `"""` in Swift, Kotlin and Java, `"""` and `'''` in Python,
        /// backticks in JavaScript and Go.
        var multilineQuotes: [String] = []
        /// A quote only opens a string after a space or punctuation, so `Don't` in YAML isn't one.
        var quotesAfterBoundary = false
        /// `'a'` and `'\n'` are characters, `'a` is a lifetime (Rust).
        var charLiterals = false
        /// `/…/` after an operator is a regular expression (JavaScript).
        var regexLiterals = false
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
        /// How many block comments are open (more than one only where they nest).
        var commentDepth = 0
        /// The closing delimiter of a string that continues on the next line.
        var openString: String?
        /// Inside a markup tag whose attributes continue on the next lines.
        var inTag = false
    }

    /// Token lists for a diff: one per line, plus, for unchanged lines that the old file saw in a
    /// different state (a block the commit commented out, say), how they looked before.
    struct Highlighted: Sendable {
        var tokens: [[SyntaxToken]] = []
        var oldSide: [Int: [SyntaxToken]] = [:]
    }

    /// Lines longer than this (minified code) aren't colored; drawing them colored stalls scrolling.
    static let longestLine = 2_000

    let language: Language
    private let lineComments: [[UInt8]]
    private let lineStartComments: [[UInt8]]
    private let blockOpen: [UInt8]
    private let blockClose: [UInt8]
    private let multilineQuotes: [[UInt8]]

    init?(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard let language = Self.language(name: name, extension: ext) else { return nil }
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf8) }
        lineStartComments = language.lineStartComments.map { Array($0.utf8) }
        blockOpen = Array((language.blockComment?.open ?? "").utf8)
        blockClose = Array((language.blockComment?.close ?? "").utf8)
        multilineQuotes = language.multilineQuotes.map { Array($0.utf8) }
    }

    /// Colors every line of a diff. State carries from line to line separately for the old and the
    /// new side; a hunk starts from scratch, except that markup attribute lines at its top are taken
    /// to be inside a tag that opened above it.
    func highlight(_ diff: FileDiff) -> Highlighted {
        var result = Highlighted()
        result.tokens.reserveCapacity(diff.lines.count)
        var old = State()
        var new = State()
        var startOfHunk = false
        for line in diff.lines {
            if startOfHunk, line.kind != .hunk, line.kind != .note {
                startOfHunk = false
                if language.markup, Self.looksLikeAttribute(line.text) {
                    old.inTag = true
                    new.inTag = true
                }
            }
            switch line.kind {
            case .hunk:
                old = State()
                new = State()
                startOfHunk = true
                result.tokens.append([])
            case .note:
                result.tokens.append([])
            case .removed:
                let scanned = scan(line.text, state: old)
                old = scanned.state
                result.tokens.append(scanned.tokens)
            case .added:
                let scanned = scan(line.text, state: new)
                new = scanned.state
                result.tokens.append(scanned.tokens)
            case .context:
                let scanned = scan(line.text, state: new)
                if old == new {
                    old = scanned.state
                } else {
                    let before = scan(line.text, state: old)
                    old = before.state
                    result.oldSide[line.id] = before.tokens
                }
                new = scanned.state
                result.tokens.append(scanned.tokens)
            }
        }
        return result
    }

    /// `android:id="@+id/title"`: an attribute line of a tag that started above.
    private static func looksLikeAttribute(_ text: String) -> Bool {
        text.range(of: #"^\s*[A-Za-z_][\w:.\-]*\s*=\s*["']"#, options: .regularExpression) != nil
    }

    func scan(_ text: String, state: State) -> (tokens: [SyntaxToken], state: State) {
        let bytes = Array(text.utf8)
        let count = bytes.count
        guard count <= Self.longestLine else { return ([], state) }
        var spans: [(start: Int, end: Int, kind: SyntaxToken.Kind)] = []
        var commentDepth = state.commentDepth
        var openString = state.openString.map { Array($0.utf8) }
        var inTag = state.inTag
        var i = 0

        func index(_ offset: Int) -> String.Index { text.utf8.index(text.utf8.startIndex, offsetBy: offset) }
        func finish() -> (tokens: [SyntaxToken], state: State) {
            let tokens = spans.filter { $0.end > $0.start }.map { SyntaxToken(range: index($0.start)..<index($0.end), kind: $0.kind) }
            let carried = openString.map { String(decoding: $0, as: UTF8.self) }
            return (tokens, State(commentDepth: commentDepth, openString: carried, inTag: inTag))
        }
        func matches(_ needle: [UInt8], at position: Int) -> Bool {
            guard !needle.isEmpty, position + needle.count <= count else { return false }
            for k in 0..<needle.count where bytes[position + k] != needle[k] { return false }
            return true
        }
        func find(_ needle: [UInt8], from position: Int, escapes: Bool = false) -> Int? {
            var p = position
            while p < count {
                if escapes, bytes[p] == UInt8(ascii: "\\") { p += 2; continue }
                if matches(needle, at: p) { return p }
                p += 1
            }
            return nil
        }
        /// Moves through block comments from `position`, counting nested ones where they nest;
        /// where the outermost one ends, or nil when the line ends first.
        func endOfComment(from position: Int) -> Int? {
            var p = position
            while p < count {
                if language.nestedComments, matches(blockOpen, at: p) {
                    commentDepth += 1
                    p += blockOpen.count
                } else if matches(blockClose, at: p) {
                    commentDepth -= 1
                    p += blockClose.count
                    if commentDepth == 0 { return p }
                } else {
                    p += 1
                }
            }
            return nil
        }
        func scanIdentifier(from position: Int) -> Int {
            var j = position
            while j < count, isIdentifier(bytes[j]) { j += 1 }
            return j
        }

        // A comment or string that started on an earlier line.
        if commentDepth > 0 {
            guard let end = endOfComment(from: 0) else {
                spans.append((0, count, .comment))
                return finish()
            }
            spans.append((0, end, .comment))
            i = end
        } else if let delimiter = openString {
            guard let end = find(delimiter, from: 0, escapes: true) else {
                spans.append((0, count, .string))
                return finish()
            }
            spans.append((0, end + delimiter.count, .string))
            i = end + delimiter.count
            openString = nil
        }

        // Things that only count at the start of a line.
        var first = i
        while first < count, isSpace(bytes[first]) { first += 1 }
        if first < count {
            if language.headings, bytes[first] == UInt8(ascii: "#") {
                spans.append((first, count, .keyword))
                return finish()
            }
            if lineStartComments.contains(where: { matches($0, at: first) }) {
                spans.append((first, count, .comment))
                return finish()
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
                // `#` only starts a comment at a word boundary (`$#`, `a#b` in shell), and `//` after
                // a colon is a URL (`url(http://…)` in CSS).
                if prefix == [UInt8(ascii: "#")], i > 0, !isSpace(bytes[i - 1]) { break }
                if prefix == [UInt8(ascii: "/"), UInt8(ascii: "/")], i > 0, bytes[i - 1] == UInt8(ascii: ":") { break }
                spans.append((i, count, .comment))
                break scanning
            }
            if matches(blockOpen, at: i) {
                commentDepth = 1
                if let end = endOfComment(from: i + blockOpen.count) {
                    spans.append((i, end, .comment))
                    i = end
                    continue
                }
                spans.append((i, count, .comment))
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
            if let delimiter = multilineQuotes.first(where: { matches($0, at: i) }) {
                if let end = find(delimiter, from: i + delimiter.count, escapes: true) {
                    spans.append((i, end + delimiter.count, .string))
                    i = end + delimiter.count
                    continue
                }
                spans.append((i, count, .string))
                openString = delimiter
                break
            }
            if language.charLiterals, c == UInt8(ascii: "'") {
                // 'a', '\n', '€' and '\u{1F600}' are characters; 'a in <'a, 'b> is a lifetime.
                if let close = find([UInt8(ascii: "'")], from: i + 1, escapes: true), close - i <= 12 {
                    let content = bytes[(i + 1)..<close]
                    if content.first == UInt8(ascii: "\\") || String(decoding: content, as: UTF8.self).count == 1 {
                        spans.append((i, close + 1, .string))
                        i = close + 1
                        continue
                    }
                }
                i += 1
                continue
            }
            if language.quotes.contains(c), !language.quotesAfterBoundary || i == 0 || isQuoteBoundary(bytes[i - 1]) {
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
            if language.regexLiterals, c == UInt8(ascii: "/"), startsRegex(bytes, at: i), let end = endOfRegex(bytes, from: i + 1) {
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
        return finish()
    }

    // MARK: Regular expressions

    private static let beforeRegex = Set("(,=:[!&|?{};+-*%<>~^".utf8)

    /// A `/` starts a regular expression after an operator, a bracket or at the start of a line;
    /// not when it divides (`a / b`, `x) / 2`) or starts a comment.
    private func startsRegex(_ bytes: [UInt8], at position: Int) -> Bool {
        guard position + 1 < bytes.count, bytes[position + 1] != UInt8(ascii: "/"), bytes[position + 1] != UInt8(ascii: "*") else {
            return false
        }
        var p = position - 1
        while p >= 0, isSpace(bytes[p]) { p -= 1 }
        return p < 0 || Self.beforeRegex.contains(bytes[p])
    }

    /// Where a regular expression ends, flags included; nil when the line ends first.
    private func endOfRegex(_ bytes: [UInt8], from position: Int) -> Int? {
        var p = position
        var inClass = false
        while p < bytes.count {
            switch bytes[p] {
            case UInt8(ascii: "\\"):
                p += 2
                continue
            case UInt8(ascii: "["):
                inClass = true
            case UInt8(ascii: "]"):
                inClass = false
            case UInt8(ascii: "/") where !inClass:
                p += 1
                while p < bytes.count, isLetter(bytes[p]) { p += 1 }
                return p
            default:
                break
            }
            p += 1
        }
        return nil
    }

    // MARK: Characters

    private func isLetter(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
    }

    private func isUppercase(_ c: UInt8) -> Bool { c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") }
    private func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
    private func isSpace(_ c: UInt8) -> Bool { c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") }
    private func isTagMark(_ c: UInt8) -> Bool { c == UInt8(ascii: "/") || c == UInt8(ascii: "?") || c == UInt8(ascii: "!") }

    /// Before a quote that opens a string in YAML: a space or one of `[{,:`.
    private func isQuoteBoundary(_ c: UInt8) -> Bool {
        isSpace(c) || c == UInt8(ascii: "[") || c == UInt8(ascii: "{") || c == UInt8(ascii: ",") || c == UInt8(ascii: ":")
    }

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
        case ".env":
            return settings
        default:
            if name.hasPrefix(".env.") { return settings }
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
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, nestedComments: true,
                multilineQuotes: ["\"\"\""], annotations: true, directives: true)
        case "kt", "kts", "gradle", "groovy":
            return Language(
                keywords: words("""
                package import class interface object fun val var if else when for while do return break continue throw try catch \
                finally in is as null true false this super override open abstract sealed data inner enum companion private \
                protected public internal lateinit const suspend inline crossinline noinline reified by get set init constructor \
                typealias vararg out where annotation operator infix tailrec external expect actual value def
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, nestedComments: ext == "kt" || ext == "kts",
                quotes: quotes, multilineQuotes: ["\"\"\""], annotations: true)
        case "java":
            return Language(
                keywords: words("""
                package import class interface enum extends implements public private protected static final abstract native \
                synchronized transient volatile new return if else switch case default for while do break continue throw throws try \
                catch finally instanceof this super null true false void boolean byte char short int long float double var record \
                sealed permits yield assert
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, quotes: quotes,
                multilineQuotes: ["\"\"\""], annotations: true)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return Language(
                keywords: words("""
                const let var function return if else for while do switch case default break continue new delete typeof instanceof \
                in of class extends super this null undefined true false import export from as async await yield try catch finally \
                throw interface type enum implements public private protected readonly static declare namespace abstract keyof void
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment,
                quotes: quotes, multilineQuotes: ["`"], regexLiterals: true, annotations: true)
        case "py":
            return Language(
                keywords: words("""
                def class return if elif else for while in not and or is None True False import from as with try except finally \
                raise pass break continue lambda yield global nonlocal assert del async await match case self
                """),
                lineComments: ["#"], quotes: quotes, multilineQuotes: ["\"\"\"", "'''"], annotations: true)
        case "go":
            return Language(
                keywords: words("""
                package import func return if else for range switch case default break continue go defer select chan map struct \
                interface type const var nil true false fallthrough goto
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment,
                quotes: quotes, multilineQuotes: ["`"], capitalizedTypes: false)
        case "rs":
            return Language(
                keywords: words("""
                fn let mut pub use mod struct enum impl trait for in if else match loop while return break continue as ref self Self \
                super crate where type const static unsafe extern move async await dyn true false Some None Ok Err
                """),
                lineComments: cStyle.lineComments, blockComment: cStyle.blockComment, nestedComments: true, charLiterals: true)
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
                            quotesAfterBoundary: true, capitalizedTypes: false, keys: true)
        case "xml", "html", "htm", "plist", "svg", "xib", "storyboard", "xsd", "vue":
            return Language(blockComment: (open: "<!--", close: "-->"), quotes: quotes, capitalizedTypes: false, markup: true)
        case "md", "markdown":
            return Language(quotes: [UInt8(ascii: "`")], capitalizedTypes: false, headings: true)
        case "css", "scss", "less":
            return Language(keywords: words("important"), lineComments: ext == "css" ? [] : ["//"],
                            blockComment: cStyle.blockComment, quotes: quotes, capitalizedTypes: false)
        case "toml", "ini", "properties", "cfg", "conf", "env":
            return settings
        default:
            return nil
        }
    }

    /// INI, TOML, properties and `.env` files: `#` comments, and `;` ones at the start of a line.
    private static var settings: Language {
        Language(keywords: words("true false"), lineComments: ["#"], lineStartComments: [";"], quotes: quotes, capitalizedTypes: false)
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
