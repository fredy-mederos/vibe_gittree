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
                    ForEach(diff.lines) { line in
                        DiffLineRow(line: line, isTarget: line.id == targetLineID)
                            .id(line.id)
                    }
                }
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
            .task(id: loadCount) {
                guard let targetLineID else { return }
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(targetLineID, anchor: .center)
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

private struct DiffLineRow: View {
    let line: FileDiff.Line
    let isTarget: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker)
                .frame(width: 22)
                .foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .overlay(alignment: .leading) {
            if isTarget {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? .green : .red
    }

    private var background: Color {
        if isTarget { return Color.yellow.opacity(0.32) }
        switch line.kind {
        case .added: return Color.green.opacity(0.13)
        case .removed: return Color.red.opacity(0.13)
        case .hunk: return Color.accentColor.opacity(0.08)
        default: return .clear
        }
    }
}
