import SwiftUI

/// A window showing one file's changes in one commit, scrolled to a line when asked.
struct DiffWindow: View {
    let target: DiffTarget?

    var body: some View {
        if let target, let repository = RepositoryLibrary.shared.repository(id: target.repositoryID) {
            FileDiffView(target: target, repository: repository)
        } else {
            ContentUnavailableView("Nothing to Show", systemImage: "doc.text.magnifyingglass",
                                   description: Text("The repository for these changes is no longer in GitTree."))
        }
    }
}

private struct FileDiffView: View {
    let target: DiffTarget
    let repository: Repository

    @State private var diff: FileDiff?
    @State private var errorMessage: String?
    @State private var wholeFile = false
    @AppStorage("diff.sideBySide") private var sideBySide = false
    @State private var didExpandForLine = false
    @State private var loadCount = 0

    private var hosting: HostingService? {
        RepositoryModelStore.shared.existingModel(id: repository.id)?.hosting
            ?? repository.remoteURL.flatMap(HostingService.init(remoteURL:))
            ?? repository.originURL.flatMap(HostingService.init(remoteURL:))
    }

    private var targetLineID: Int? {
        guard let line = target.line else { return nil }
        return diff?.lineID(forNewLine: line)
    }

    var body: some View {
        content
            .navigationTitle(URL(fileURLWithPath: target.path).lastPathComponent)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $sideBySide) {
                        Label("Side by Side", systemImage: "rectangle.split.2x1")
                    }
                    .help("Show the file before and after the commit next to each other")
                }
                ToolbarItem {
                    Toggle(isOn: $wholeFile) {
                        Label("Whole File", systemImage: "doc.plaintext")
                    }
                    .help("Show the whole file around the changes")
                }
                ToolbarItem {
                    Button {
                        guard let url = DeepLink.url(repository: repository.kind == .local ? repository.path : (repository.remoteURL ?? repository.name),
                                                     commit: target.commit, path: target.path, line: target.line) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    .help("Copy a gittree:// link to this file in this commit")
                }
                if let hosting {
                    ToolbarItem {
                        Button {
                            NSWorkspace.shared.open(hosting.fileURL(commit: target.commit, path: target.path, line: target.line))
                        } label: {
                            Label("Open on \(hosting.displayName)", systemImage: "safari")
                        }
                        .help("Open this file as of this commit on \(hosting.displayName)")
                    }
                }
            }
            .task(id: wholeFile) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("GitTree can't show changes to binary files."))
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "equal.circle",
                                       description: Text("This file didn't change in this commit compared to its first parent."))
            } else {
                lines(diff)
            }
        } else if let errorMessage {
            ContentUnavailableView("Couldn't Load the Changes", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else {
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lines(_ diff: FileDiff) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sideBySide {
                        ForEach(diff.splitRows) { row in
                            SplitRowView(row: row, diff: diff, targetLineID: targetLineID)
                                .id(row.id)
                        }
                    } else {
                        ForEach(diff.lines) { line in
                            DiffLineRow(line: line, tokens: diff.tokens(forLine: line.id), isTarget: line.id == targetLineID)
                                .id(line.id)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Text("+\(diff.addedCount)").foregroundStyle(.green)
                    Text("−\(diff.removedCount)").foregroundStyle(.red)
                    Text(target.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
            .task(id: "\(loadCount) \(sideBySide)") {
                guard let targetLineID, let rowID = sideBySide ? diff.splitRowID(containing: targetLineID) : targetLineID else { return }
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(rowID, anchor: .center)
            }
        }
    }

    private var subtitle: String {
        var parts = [repository.name, String(target.commit.prefix(8))]
        if let line = target.line { parts.append("line \(line)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        errorMessage = nil
        let parent = try? await Git.string(["rev-parse", "--verify", "--quiet", "\(target.commit)^1"],
                                          in: repository.directory, allowFailure: true)
        do {
            let loaded = try await FileDiffLoader.load(
                commit: target.commit, firstParent: parent?.isEmpty == false ? parent : nil,
                path: target.path, in: repository.directory, wholeFile: wholeFile
            )
            // The line asked for isn't near a change: show the whole file so it can be found.
            if let line = target.line, !wholeFile, !didExpandForLine, !loaded.contains(newLine: line) {
                didExpandForLine = true
                wholeFile = true
                return
            }
            diff = loaded
            loadCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One line of the unified view: old and new line numbers, a +/− marker and the colored text.
private struct DiffLineRow: View {
    let line: FileDiff.Line
    let tokens: [SyntaxToken]
    let isTarget: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.kind.marker)
                .frame(width: 22)
                .foregroundStyle(line.kind.markerColor)
            Text(highlighted(line.text, tokens: tokens))
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
        .background(isTarget ? Color.yellow.opacity(0.32) : line.kind.background)
        .overlay(alignment: .leading) {
            if isTarget {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }
}

/// One row of the side-by-side view: the old line on the left, the new one on the right, or a hunk
/// header across both.
private struct SplitRowView: View {
    let row: FileDiff.SplitRow
    let diff: FileDiff
    let targetLineID: Int?

    var body: some View {
        if let full = row.full {
            DiffLineRow(line: full, tokens: [], isTarget: false)
        } else {
            HStack(spacing: 0) {
                SplitCell(line: row.left, number: row.left?.oldNumber,
                          tokens: row.left.map { diff.tokens(forLine: $0.id) } ?? [], isTarget: false)
                Divider()
                SplitCell(line: row.right, number: row.right?.newNumber,
                          tokens: row.right.map { diff.tokens(forLine: $0.id) } ?? [],
                          isTarget: row.right != nil && row.right?.id == targetLineID)
            }
            // Both halves take the height of the taller one, so wrapped lines stay side by side.
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SplitCell: View {
    let line: FileDiff.Line?
    let number: Int?
    let tokens: [SyntaxToken]
    let isTarget: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line?.kind.marker ?? "")
                .frame(width: 20)
                .foregroundStyle(line?.kind.markerColor ?? .clear)
            Text(line.map { highlighted($0.text, tokens: tokens) } ?? AttributedString(" "))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .overlay(alignment: .leading) {
            if isTarget {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    private var background: Color {
        guard let line else { return Color.secondary.opacity(0.07) }
        return isTarget ? Color.yellow.opacity(0.32) : line.kind.background
    }
}

private extension FileDiff.Line.Kind {
    var marker: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    var markerColor: Color {
        self == .added ? .green : .red
    }

    var background: Color {
        switch self {
        case .added: Color.green.opacity(0.13)
        case .removed: Color.red.opacity(0.13)
        case .hunk: Color.accentColor.opacity(0.08)
        default: .clear
        }
    }
}

/// A line's text with its syntax colors.
private func highlighted(_ text: String, tokens: [SyntaxToken]) -> AttributedString {
    guard !text.isEmpty else { return AttributedString(" ") }
    guard !tokens.isEmpty else { return AttributedString(text) }
    var result = AttributedString()
    var cursor = text.startIndex
    for token in tokens where token.range.lowerBound >= cursor && token.range.upperBound <= text.endIndex {
        if cursor < token.range.lowerBound {
            result += AttributedString(String(text[cursor..<token.range.lowerBound]))
        }
        var piece = AttributedString(String(text[token.range]))
        piece.swiftUI.foregroundColor = token.kind.color
        result += piece
        cursor = token.range.upperBound
    }
    if cursor < text.endIndex {
        result += AttributedString(String(text[cursor...]))
    }
    return result
}

private extension SyntaxToken.Kind {
    /// Xcode's default theme, light and dark.
    var color: Color {
        Self.colors[self] ?? .primary
    }

    private static let colors: [SyntaxToken.Kind: Color] = [
        .keyword: dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        .string: dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .comment: dynamic(light: 0x5D6C79, dark: 0x7F8C98),
        .number: dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .type: dynamic(light: 0x0B4F79, dark: 0x5DD8FF),
        .attribute: dynamic(light: 0x815F03, dark: 0xBF8555),
    ]

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
