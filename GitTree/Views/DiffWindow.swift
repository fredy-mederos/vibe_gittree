import SwiftUI

/// A window showing a file's changes in a commit (or since another commit, or not committed yet),
/// scrolled to a line when asked, with the other files listed to move between, or all of them one
/// after another. Commits, comparisons, stashes and uncommitted changes all open here.
struct DiffWindow: View {
    let target: DiffTarget?

    var body: some View {
        if let target, let repository = RepositoryLibrary.shared.repository(id: target.repositoryID) {
            FileDiffView(target: target, repository: repository)
        } else {
            ContentUnavailableView("Nothing to Show", systemImage: "doc.text.magnifyingglass",
                                   description: Text("The repository for these changes is no longer in Vibe GitTree."))
        }
    }
}

/// How the diff window lists the other files: as git does (by path), or the biggest changes first.
private enum DiffFileOrder: String {
    case path, changes
}

private struct FileDiffView: View {
    /// What the window was opened for.
    let target: DiffTarget
    let repository: Repository

    /// The file shown: the window's own, or another one picked in the list.
    @State private var current: DiffTarget
    /// The commit's files, or every uncommitted one, to move between.
    @State private var files: [DiffFile] = []
    @State private var filesVersion = 0
    @State private var selection: String?
    @AppStorage("diff.fileOrder") private var order = DiffFileOrder.path
    /// Every file one after another instead of one at a time.
    @State private var showsAllFiles: Bool
    /// All Files' diffs by file, and whether they're all there (a long diff stops at a limit).
    @State private var combined: (diffs: [String: FileDiff], complete: Bool)?
    @State private var combinedError: String?
    @State private var diff: FileDiff?
    @State private var errorMessage: String?
    @State private var wholeFile = false
    @AppStorage("diff.sideBySide") private var sideBySide = false
    @State private var didExpandForLine = false
    @State private var loadCount = 0

    init(target: DiffTarget, repository: Repository) {
        self.target = target
        self.repository = repository
        _current = State(initialValue: target)
        _showsAllFiles = State(initialValue: target.allFiles ?? false)
        _selection = State(initialValue: target.path.isEmpty ? nil : DiffFile.id(path: target.path, uncommitted: target.uncommitted))
    }

    private var hosting: HostingService? {
        RepositoryModelStore.shared.existingModel(id: repository.id)?.hosting
            ?? repository.remoteURL.flatMap(HostingService.init(remoteURL:))
            ?? repository.originURL.flatMap(HostingService.init(remoteURL:))
    }

    private var targetLineID: Int? {
        guard let line = current.line else { return nil }
        return diff?.lineID(forNewLine: line)
    }

    /// For uncommitted changes, increments whenever the working tree is looked at, so the diff follows edits.
    private var workingTreeVersion: Int {
        guard target.uncommitted != nil else { return 0 }
        return RepositoryModelStore.shared.model(for: repository).workingTreeVersion
    }

    /// The files in the list's order: uncommitted ones by kind (conflicts, staged, not staged,
    /// new), each kind by path or with the most changed lines first.
    private var orderedFiles: [DiffFile] {
        func rank(_ file: DiffFile) -> Int {
            if file.status == "!" { return 0 }
            switch file.uncommitted {
            case .staged: return 1
            case .unstaged: return 2
            case .untracked: return 3
            case nil: return 0
            }
        }
        return files.enumerated().sorted { a, b in
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            if order == .changes, a.element.changes != b.element.changes { return a.element.changes > b.element.changes }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var position: Int? {
        orderedFiles.firstIndex { $0.id == selection }
    }

    /// The file on its own when one is shown; the window's own title for All Files.
    private var title: String {
        if showsAllFiles || current.path.isEmpty { return target.title ?? "All Changes" }
        return URL(fileURLWithPath: current.path).lastPathComponent
    }

    private struct AllFilesKey: Hashable {
        let showsAllFiles: Bool
        let filesVersion: Int
        let order: DiffFileOrder
    }

    var body: some View {
        NavigationSplitView {
            DiffFileList(files: orderedFiles, selection: $selection, order: $order, uncommitted: target.uncommitted != nil)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            if showsAllFiles {
                allFiles
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onChange(of: selection) { _, id in show(id) }
        // Uncommitted changes are looked at while the window is open, even with no repository window showing them.
        .onAppear { if target.uncommitted != nil { RepositoryModelStore.shared.model(for: repository).beginWatchingWorkingTree() } }
        .onDisappear { if target.uncommitted != nil { RepositoryModelStore.shared.model(for: repository).endWatchingWorkingTree() } }
        .task(id: workingTreeVersion) { await loadFiles() }
        .task(id: AllFilesKey(showsAllFiles: showsAllFiles, filesVersion: filesVersion, order: order)) {
            guard showsAllFiles else { return }
            await loadAllFiles()
        }
        .task(id: "\(current.path) \(current.uncommitted?.rawValue ?? "") \(wholeFile) \(workingTreeVersion) \(showsAllFiles)") {
            guard !showsAllFiles, !current.path.isEmpty else { return }
            await load()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                Button {
                    step(-1)
                } label: {
                    Label("Previous File", systemImage: "chevron.up")
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled((position ?? 0) == 0)
                Button {
                    step(1)
                } label: {
                    Label("Next File", systemImage: "chevron.down")
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(position.map { $0 >= orderedFiles.count - 1 } ?? orderedFiles.isEmpty)
            }
            .help("The previous or next file (⌥⌘↑, ⌥⌘↓)")
        }
        ToolbarItem {
            Toggle(isOn: $showsAllFiles) {
                Label("All Files", systemImage: "doc.on.doc")
            }
            .help("Show every file's changes one after another, or one file at a time")
        }
        ToolbarItem {
            Toggle(isOn: $sideBySide) {
                Label("Side by Side", systemImage: "rectangle.split.2x1")
            }
            .help("Show the files before and after the changes next to each other")
        }
        ToolbarItem {
            Toggle(isOn: $wholeFile) {
                Label("Whole File", systemImage: "doc.plaintext")
            }
            .disabled(showsAllFiles)
            .help(showsAllFiles ? "Shows a whole file one file at a time" : "Show the whole file around the changes")
        }
        if current.uncommitted == nil, !showsAllFiles, !current.path.isEmpty {
            ToolbarItem {
                Button {
                    guard let url = DeepLink.url(repository: repository.kind == .local ? repository.path : (repository.remoteURL ?? repository.name),
                                                 commit: current.commit, path: current.path, line: current.line) else { return }
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
                        NSWorkspace.shared.open(hosting.fileURL(commit: current.commit, path: current.path, line: current.line))
                    } label: {
                        Label("Open on \(hosting.displayName)", systemImage: "safari")
                    }
                    .help("Open this file as of this commit on \(hosting.displayName)")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("Vibe GitTree can't show changes to binary files."))
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "equal.circle", description: Text(noChanges))
            } else {
                lines(diff)
            }
        } else if let errorMessage {
            ContentUnavailableView("Couldn't Load the Changes", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if current.path.isEmpty, files.isEmpty, filesVersion > 0 {
            ContentUnavailableView("No Changes", systemImage: "equal.circle", description: Text("No file changed."))
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
                    Text(current.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    if let position, orderedFiles.count > 1 {
                        Text("File \((position + 1).formatted()) of \(orderedFiles.count.formatted())")
                            .foregroundStyle(.secondary)
                    }
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
            // Each file starts at its top.
            .id(current)
        }
    }

    /// Every file's changes one after another, each under a header that stays on top while its
    /// changes scroll by; picking a file in the list scrolls to it.
    @ViewBuilder private var allFiles: some View {
        if let combined {
            if files.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "equal.circle", description: Text("No file changed."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(orderedFiles) { file in
                                Section {
                                    fileChanges(file, diff: combined.diffs[file.id])
                                    // Space before the next file (padding on the rows would space every line).
                                    Color.clear.frame(height: 14)
                                } header: {
                                    fileHeader(file)
                                        .id(file.id)
                                }
                            }
                            if !combined.complete {
                                Text("The rest aren't shown here, to keep this window quick. Pick them in the list to see them one at a time.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                    .onChange(of: selection) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .top) }
                    }
                    .task {
                        // Opened on a file: start there.
                        if let selection, selection != orderedFiles.first?.id { proxy.scrollTo(selection, anchor: .top) }
                    }
                }
            }
        } else if let combinedError {
            ContentUnavailableView("Couldn't Load the Changes", systemImage: "exclamationmark.triangle", description: Text(combinedError))
        } else {
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func fileChanges(_ file: DiffFile, diff: FileDiff?) -> some View {
        if let diff {
            if diff.isBinary {
                note("Binary file: its changes can't be shown.")
            } else if diff.lines.isEmpty {
                note(file.status == "R" ? "Renamed, without other changes." : "No changes to show here (its mode changed, say).")
            } else if sideBySide {
                ForEach(diff.splitRows) { row in
                    SplitRowView(row: row, diff: diff, targetLineID: nil)
                }
            } else {
                ForEach(diff.lines) { line in
                    DiffLineRow(line: line, tokens: diff.tokens(forLine: line.id), isTarget: false)
                }
            }
        } else {
            Button("Show This File’s Changes") { showAlone(file) }
                .buttonStyle(.link)
                .font(.callout)
                .padding(12)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(ChangeStatus.color(file.status))
            Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let side = file.uncommitted {
                Text(side.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let added = file.added, let removed = file.removed {
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
            }
            Button {
                showAlone(file)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Show only this file")
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var subtitle: String {
        var parts = [repository.name]
        if showsAllFiles || current.path.isEmpty {
            if !files.isEmpty {
                let added = files.reduce(0) { $0 + ($1.added ?? 0) }
                let removed = files.reduce(0) { $0 + ($1.removed ?? 0) }
                parts.append(counted(files.count, "file", "files") + (repository.kind == .local ? " · +\(added.formatted()) −\(removed.formatted())" : ""))
            }
            if target.uncommitted != nil {
                parts.append("not committed")
            } else if let base = target.base {
                parts.append("\(base.prefix(8)) → \(target.commit.prefix(8))")
            } else {
                parts.append(String(target.commit.prefix(8)))
            }
            return parts.joined(separator: " · ")
        }
        if let uncommitted = current.uncommitted {
            switch uncommitted {
            case .staged: parts.append("Staged, not committed")
            case .unstaged: parts.append("Not staged")
            case .untracked: parts.append("New file, not committed")
            }
        } else if let base = current.base {
            parts.append("\(base.prefix(8)) → \(current.commit.prefix(8))")
        } else {
            parts.append(String(current.commit.prefix(8)))
        }
        if let oldPath = current.oldPath { parts.append("renamed from \(oldPath)") }
        if let line = current.line { parts.append("line \(line)") }
        return parts.joined(separator: " · ")
    }

    private var noChanges: String {
        switch current.uncommitted {
        case .staged: return "Nothing in this file is staged now."
        case .unstaged: return "This file has no changes that aren't staged now."
        case .untracked: return "This file isn't there anymore, or git tracks it now."
        case nil: return current.base == nil ? "This file didn't change in this commit compared to its first parent."
            : "This file is the same in both commits."
        }
    }

    /// Picked in the list (or stepped to): that file's diff, the same kind as the window's. With
    /// All Files on, the changes scroll to it instead.
    private func show(_ id: String?) {
        guard let id, id != DiffFile.id(path: current.path, uncommitted: current.uncommitted),
              let file = files.first(where: { $0.id == id }) else { return }
        let isTarget = file.path == target.path && file.uncommitted == target.uncommitted
        // The whole file was shown to find the line asked for; other files start with their changes.
        if didExpandForLine {
            wholeFile = false
            didExpandForLine = false
        }
        diff = nil
        errorMessage = nil
        current = DiffTarget(repositoryID: target.repositoryID, commit: target.commit, path: file.path, line: isTarget ? target.line : nil,
                             base: target.base, oldPath: file.oldPath, uncommitted: file.uncommitted)
    }

    /// One file on its own, from All Files.
    private func showAlone(_ file: DiffFile) {
        selection = file.id
        showsAllFiles = false
    }

    private func step(_ offset: Int) {
        let list = orderedFiles
        guard let position else {
            selection = list.first?.id
            return
        }
        guard list.indices.contains(position + offset) else { return }
        selection = list[position + offset].id
    }

    /// The first parent a commit is compared with, when there's no other base.
    private func firstParent() async -> String? {
        guard target.uncommitted == nil, target.base == nil else { return nil }
        let parent = try? await Git.string(["rev-parse", "--verify", "--quiet", "\(target.commit)^1"],
                                           in: repository.directory, allowFailure: true)
        return parent?.isEmpty == false ? parent : nil
    }

    private func loadFiles() async {
        let model = RepositoryModelStore.shared.model(for: repository)
        let parent = await firstParent()
        guard let listed = try? await DiffFileListLoader.files(for: target, firstParent: parent, workingTree: model.workingTree,
                                                                in: repository.directory, counts: repository.kind == .local),
              !Task.isCancelled else { return }
        files = listed
        filesVersion += 1
        // Opened on every file (or on one that's gone): the first one is the one to show alone.
        if selection.map({ id in !listed.contains { $0.id == id } }) ?? true, current.path.isEmpty {
            selection = orderedFiles.first?.id
        }
    }

    private func loadAllFiles() async {
        combinedError = nil
        let parent = await firstParent()
        do {
            let loaded = try await CombinedDiffLoader.load(target, firstParent: parent, files: orderedFiles, in: repository.directory,
                                                           detectRenames: repository.kind == .local)
            // A newer load (the files changed, or their order) has taken over.
            guard !Task.isCancelled else { return }
            combined = loaded
        } catch {
            guard !Task.isCancelled else { return }
            combinedError = error.localizedDescription
        }
    }

    private func load() async {
        errorMessage = nil
        let loading = current
        let parent = await firstParent()
        do {
            let loaded = try await FileDiffLoader.load(loading, firstParent: parent, in: repository.directory, wholeFile: wholeFile)
            // Another file was picked meanwhile (a big file's diff can arrive after a small one's).
            guard !Task.isCancelled, loading == current else { return }
            // The line asked for isn't near a change: show the whole file so it can be found.
            if let line = current.line, !wholeFile, !didExpandForLine, !loaded.contains(newLine: line) {
                didExpandForLine = true
                wholeFile = true
                return
            }
            diff = loaded
            loadCount += 1
        } catch {
            guard !Task.isCancelled, loading == current else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// The files the diff window moves between, each a `DiffFileRow`; uncommitted ones by kind.
private struct DiffFileList: View {
    let files: [DiffFile]
    @Binding var selection: String?
    @Binding var order: DiffFileOrder
    let uncommitted: Bool

    var body: some View {
        let most = DiffFileRow.most(of: files)
        List(selection: $selection) {
            if uncommitted {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.files) { row($0, most: most) }
                    }
                }
            } else {
                ForEach(files) { row($0, most: most) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Picker("Order", selection: $order) {
                    Text("By Path").tag(DiffFileOrder.path)
                    Text("Most Changes First").tag(DiffFileOrder.changes)
                }
                .labelsHidden()
                .fixedSize()
                .help("List the files by path, or with the most changed lines first")
                Spacer()
                Text(counted(files.count, "file", "files"))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func row(_ file: DiffFile, most: Int) -> some View {
        DiffFileRow(file: file, most: most)
            .tag(file.id)
    }

    /// Uncommitted files by kind, as Uncommitted Changes lists them.
    private var groups: [(title: String, files: [DiffFile])] {
        let kinds: [(String, (DiffFile) -> Bool)] = [
            ("Conflicts", { $0.status == "!" }),
            ("Staged", { $0.uncommitted == .staged }),
            ("Not Staged", { $0.uncommitted == .unstaged && $0.status != "!" }),
            ("New Files", { $0.uncommitted == .untracked }),
        ]
        return kinds.map { kind in (kind.0, files.filter(kind.1)) }.filter { !$0.files.isEmpty }
    }
}

/// A changed file as the diff window and a comparison's Files list show it: its status, name and
/// folder, the lines it added and removed, and a bar as long as its changes compared with the
/// biggest, so where the work is stands out.
struct DiffFileRow: View {
    let file: DiffFile
    /// The biggest file's changed lines, which a full bar stands for.
    let most: Int

    static func most(of files: [DiffFile]) -> Int {
        max(1, files.map(\.changes).max() ?? 1)
    }

    var body: some View {
        let folder = (file.path as NSString).deletingLastPathComponent
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(file.status)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(ChangeStatus.color(file.status), selected: .primary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let added = file.added, let removed = file.removed {
                        Text(verbatim: "+\(added) −\(removed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary, selected: .secondary)
                    }
                }
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if file.changes > 0 {
                    ChangeBar(added: file.added ?? 0, removed: file.removed ?? 0, most: most)
                }
            }
        }
        .padding(.vertical, 1)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

/// Added lines in green and removed ones in red, the whole as long as the changes compared with `most`.
private struct ChangeBar: View {
    let added: Int
    let removed: Int
    let most: Int

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / CGFloat(most)
            HStack(spacing: 1) {
                if added > 0 {
                    Capsule().fill(Color.green.opacity(0.8)).frame(width: max(2, CGFloat(added) * scale))
                }
                if removed > 0 {
                    Capsule().fill(Color.red.opacity(0.8)).frame(width: max(2, CGFloat(removed) * scale))
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Colors for git's status letters, as in the details' file lists.
enum ChangeStatus {
    static func color(_ status: String) -> Color {
        switch status {
        case "A", "?": .green
        case "D": .red
        case "R", "C": .blue
        case "U", "!": .red
        default: .orange
        }
    }
}

/// One line of the unified view: old and new line numbers, a +/− marker and the colored text.
struct DiffLineRow: View {
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
struct SplitRowView: View {
    let row: FileDiff.SplitRow
    let diff: FileDiff
    let targetLineID: Int?

    var body: some View {
        if let full = row.full {
            DiffLineRow(line: full, tokens: [], isTarget: false)
        } else {
            HStack(spacing: 0) {
                SplitCell(line: row.left, number: row.left?.oldNumber,
                          tokens: row.left.map { diff.oldSideTokens(forLine: $0.id) } ?? [], isTarget: false)
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
