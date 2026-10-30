import SwiftUI

/// The details for the row of uncommitted changes: the files, staged and not, each opening its
/// diff. With Settings › General › Allow commits and stashes on, checkboxes stage and unstage
/// them, and the box below commits what's staged or stashes the changes.
struct WorkingTreeInspector: View {
    @Bindable var graph: GraphViewModel
    @AppStorage(AppSettings.allowsChangesKey) private var allowsChanges = false
    /// Sections showing every file instead of the first few hundred.
    @State private var showsAll: Set<String> = []

    private static let rowLimit = 300

    private var model: RepositoryModel { graph.model }
    private var canChange: Bool { allowsChanges && model.hasWorkingTree }

    var body: some View {
        if let status = model.workingTree {
            Form {
                Section {
                    header(status)
                }
                fileSection("Conflicts", id: "conflicts", status.conflicted, side: .unstaged, total: status.conflictedCount)
                fileSection("Staged", id: "staged", status.staged, side: .staged, total: status.stagedCount)
                fileSection("Not Staged", id: "unstaged", status.unstaged, side: .unstaged, total: status.unstagedCount)
                fileSection("New Files", id: "untracked", status.untracked, side: .untracked, total: status.untrackedCount)
                if status.total > status.changes.count {
                    Text("\(status.total - status.changes.count) more files aren't listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // What's pinned below the list keeps a height that doesn't depend on the width: text
            // that wraps there makes the window's layout go round in circles while it zooms (AppKit
            // then stops the app), so wrapping text goes in the list above.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if canChange {
                    CommitPanel(graph: graph, status: status)
                }
            }
        } else if !model.hasWorkingTree {
            ContentUnavailableView("No Working Tree", systemImage: "externaldrive",
                                   description: Text("This repository has no working tree, so nothing in it is uncommitted."))
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ status: WorkingTreeStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Uncommitted Changes")
                    .font(.headline)
                Spacer()
                if !status.isClean {
                    Button {
                        graph.showChanges(DiffTarget(repositoryID: model.id, commit: "", path: "", uncommitted: .unstaged,
                                                     allFiles: true, title: String(localized: "Uncommitted Changes")))
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show every uncommitted change, one file after another")
                }
            }
            Text(branchLine(status))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let operation = status.operation {
                Label(operation.finishOrStop, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.isClean {
                Text("Nothing to commit: the files are as HEAD has them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !canChange && model.hasWorkingTree {
                readOnlyNote
            }
        }
        .padding(.vertical, 2)
    }

    /// "On develop · 2 ahead and 1 behind origin/develop".
    private func branchLine(_ status: WorkingTreeStatus) -> String {
        var line: String
        if let branch = status.branch {
            line = status.head == nil ? String(localized: "On \(branch), before its first commit")
                : String(localized: "On \(branch)", comment: "The checked-out branch")
        } else {
            line = String(localized: "HEAD detached at \(status.head.map { String($0.prefix(8)) } ?? "?")")
        }
        if let upstream = status.upstream {
            let tracking = switch (status.ahead, status.behind) {
            case (0, 0): String(localized: "up to date with \(upstream)")
            case (let ahead, 0): String(localized: "\(ahead) ahead of \(upstream)", comment: "Commits ahead of the upstream branch")
            case (0, let behind): String(localized: "\(behind) behind \(upstream)", comment: "Commits behind the upstream branch")
            case (let ahead, let behind):
                String(localized: "\(ahead) ahead and \(behind) behind \(upstream)", comment: "Commits ahead of and behind the upstream branch")
            }
            line += " · " + tracking
        }
        return line
    }

    @ViewBuilder
    private func fileSection(_ title: LocalizedStringKey, id: String, _ files: [WorkingChange], side: UncommittedSide, total: Int) -> some View {
        if !files.isEmpty {
            let busy = model.changeInProgress != nil
            Section {
                let shown = showsAll.contains(id) ? files : Array(files.prefix(Self.rowLimit))
                ForEach(shown) { change in
                    WorkingFileRow(change: change, side: side, staged: canChange ? side == .staged : nil, disabled: busy) {
                        toggle([change], staged: side == .staged)
                    } open: {
                        graph.showChanges(DiffTarget(repositoryID: model.id, commit: "", path: change.path,
                                                     oldPath: side == .staged ? change.oldPath : nil,
                                                     uncommitted: change.isConflicted ? .unstaged : side,
                                                     title: String(localized: "Uncommitted Changes")))
                    }
                }
                if files.count > shown.count {
                    Button("Show All \(files.count)") { showsAll.insert(id) }
                        .buttonStyle(.link)
                }
            } header: {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer()
                    if canChange {
                        Button(side == .staged ? "Unstage All" : "Stage All") {
                            toggle(files, staged: side == .staged)
                        }
                        .buttonStyle(.link)
                        .disabled(busy)
                    }
                    Text(total.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if id == "conflicts" {
                    Text("Both sides changed these files. Resolve them in your editor, then stage them.")
                }
            }
        }
    }

    /// Stages files, or unstages the staged ones.
    private func toggle(_ files: [WorkingChange], staged: Bool) {
        Task {
            if staged {
                await model.unstage(files)
            } else {
                await model.stage(files)
            }
        }
    }

    /// Changes aren't allowed: how to allow them.
    private var readOnlyNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock")
            VStack(alignment: .leading, spacing: 4) {
                Text("Vibe GitTree only reads this repository. To stage, commit and stash here, turn on Allow commits and stashes.")
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink {
                    Text("Open Settings…")
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

/// A changed file: a checkbox that stages or unstages it (when changes are allowed), its status
/// letter and path; clicking it opens its diff.
private struct WorkingFileRow: View {
    let change: WorkingChange
    let side: UncommittedSide
    /// Whether it's staged, when it can be changed here; nil shows no checkbox.
    let staged: Bool?
    let disabled: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let staged {
                Toggle("Staged", isOn: Binding(get: { staged }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(disabled)
                    .help(staged ? "Unstage: leave it out of the next commit" : "Stage: put it in the next commit")
            }
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(letter)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(ChangeStatus.color(letter))
                        .frame(width: 14)
                    Text(change.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private var letter: String {
        if change.isConflicted { return "!" }
        switch side {
        case .staged: return change.staged ?? "M"
        case .unstaged: return change.unstaged ?? "M"
        case .untracked: return "A"
        }
    }

    private var help: String {
        var lines = [change.oldPath.map { "\($0) → \(change.path)" } ?? change.path]
        if change.isConflicted {
            lines.append(String(localized: "Not resolved yet"))
        } else if change.staged != nil && change.unstaged != nil {
            lines.append(String(localized: "Partly staged: it's under Staged and Not Staged"))
        }
        lines.append(String(localized: "Click to see the changes"))
        return lines.joined(separator: "\n")
    }
}

/// The message box under the uncommitted changes: commits what's staged, or stashes changes.
private struct CommitPanel: View {
    @Bindable var graph: GraphViewModel
    let status: WorkingTreeStatus
    @State private var isStashPresented = false

    private var model: RepositoryModel { graph.model }
    private var busy: Bool { model.changeInProgress != nil }
    private var summary: String { graph.commitSummary.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why there's nothing to commit yet, or where the commit goes.
    private var note: String {
        if let operation = status.operation, operation != .merge { return operation.finish }
        if status.stagedCount == 0 { return String(localized: "Stage files to commit them.") }
        if summary.isEmpty { return String(localized: "Write a summary of the changes.") }
        if let branch = status.branch { return String(localized: "Commits to \(branch).", comment: "Where the commit button commits") }
        return String(localized: "Commits on a detached HEAD.")
    }

    private var canCommit: Bool {
        !busy && status.stagedCount > 0 && !summary.isEmpty && (status.operation == nil || status.operation == .merge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.changeError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    // Three lines whatever the width (see the note on the list's inset); all of it in the tooltip.
                    Text(error)
                        .font(.caption)
                        .lineLimit(3, reservesSpace: true)
                        .textSelection(.enabled)
                        .help(error)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissChangeError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
            }
            TextField("Summary", text: $graph.commitSummary, prompt: Text("Summary"))
                .textFieldStyle(.roundedBorder)
            // Always three lines tall; longer descriptions scroll inside it.
            TextField("Description", text: $graph.commitDescription, prompt: Text("Description"), axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Stash…") { isStashPresented = true }
                    .disabled(status.isClean || busy)
                    .help("Put changes aside, to bring back later")
                    .popover(isPresented: $isStashPresented, arrowEdge: .top) {
                        StashForm(model: model, status: status) { isStashPresented = false }
                    }
                Spacer(minLength: 4)
                if let progress = model.changeInProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(status.stagedCount > 0 ? String(localized: "Commit \(status.stagedCount) Files")
                       : String(localized: "Commit.button", defaultValue: "Commit", comment: "Button: commits the staged files")) { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    .help("Commit the staged files (⌘Return)")
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(note)
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func commit() {
        let description = graph.commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? summary : summary + "\n\n" + description
        Task {
            guard await model.commit(message: message) else { return }
            graph.commitSummary = ""
            graph.commitDescription = ""
        }
    }
}

/// Stashes every change, or only the staged files' (all of their changes), with an optional message.
private struct StashForm: View {
    let model: RepositoryModel
    let status: WorkingTreeStatus
    let done: () -> Void
    @State private var message = ""
    @State private var onlyStaged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(.headline)
            Text("Puts the changes aside, new files too, and sets the files back to how HEAD has them. Apply or pop the stash to bring them back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Message", text: $message, prompt: Text("Message (optional)"))
                .textFieldStyle(.roundedBorder)
            // Offered when every staged file is listed (very long lists stop at a few thousand files).
            if status.stagedCount > 0 && status.stagedCount < status.total && status.staged.count == status.stagedCount {
                Picker("Stash", selection: $onlyStaged) {
                    Text("Every changed file (\(status.total))").tag(false)
                    Text("The staged files, all of their changes (\(status.stagedCount))").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Stash.button", defaultValue: "Stash", comment: "Button: puts the changes aside in a stash")) {
                    let files = onlyStaged ? status.staged : nil
                    let message = message
                    Task {
                        _ = await model.stash(files, message: message)
                        done()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.changeInProgress != nil)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// A stash picked in the sidebar: its message, where it was made, the files it changed and the
/// new files it took along. With changes allowed: Apply, Pop and Drop.
struct StashInspector: View {
    let graph: GraphViewModel
    let stash: StashEntry
    @AppStorage(AppSettings.allowsChangesKey) private var allowsChanges = false
    @State private var details: StashDetails?
    @State private var didLoad = false
    @State private var confirmsDrop = false

    private var model: RepositoryModel { graph.model }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stash.title)
                        .font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    // git's own description of a stash made without a message: the commit it was made on.
                    if stash.subject.hasPrefix("WIP on ") {
                        Text(stash.subject)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
            Section("Stash") {
                LabeledContent("Name") {
                    Text(stash.name)
                        .monospaced()
                        .textSelection(.enabled)
                }
                LabeledContent("Date") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(stash.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        Text(stash.date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let branch = stash.branch {
                    LabeledContent("Branch", value: branch)
                }
                if let base = stash.base {
                    LabeledContent("Made on") {
                        if let commitGraph = graph.commitGraph, let commit = commitGraph.indexByID[base] {
                            Button {
                                graph.select(commit)
                            } label: {
                                Text(verbatim: "\(base.short) \(commitGraph.subjects[Int(commit)])")
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                            .buttonStyle(.link)
                            .help("Go to this commit")
                        } else {
                            Text(base.short).monospaced()
                        }
                    }
                }
            }
            Section {
                if let details {
                    ForEach(details.files) { file in
                        fileButton(file, commit: stash.id)
                    }
                    if details.files.isEmpty {
                        Text("No changes to tracked files.")
                            .foregroundStyle(.secondary)
                    }
                } else if didLoad {
                    Text("Couldn't read the stash's changes.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Changed Files")
                    Spacer()
                    if let base = stash.base, details?.files.isEmpty == false {
                        Button {
                            graph.showChanges(DiffTarget(repositoryID: model.id, commit: stash.id.hex, path: "", base: base.hex,
                                                         allFiles: true, title: "\(stash.name) \(stash.title)"))
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Show all of the stash's changes, one file after another")
                    }
                    if let details {
                        Text(details.files.count.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let details, let untracked = stash.untracked, !details.untrackedFiles.isEmpty {
                Section("New Files") {
                    ForEach(details.untrackedFiles) { file in
                        fileButton(file, commit: untracked)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if allowsChanges && model.hasWorkingTree { actions }
        }
        .task(id: stash.id) {
            details = await model.stashDetails(stash)
            didLoad = true
        }
        .confirmationDialog("Drop \(stash.name)?", isPresented: $confirmsDrop) {
            Button("Drop Stash", role: .destructive) {
                Task {
                    if await model.dropStash(stash) { graph.userSelected(nil) }
                }
            }
        } message: {
            Text("“\(stash.title)” is deleted with its changes. Vibe GitTree can't bring it back.")
        }
    }

    /// A file of the stash; its diff compares the stash with the commit it was made on (or, for a
    /// new file, shows all of it).
    private func fileButton(_ file: ChangedFile, commit: ObjectID) -> some View {
        Button {
            graph.showChanges(DiffTarget(repositoryID: model.id, commit: commit.hex, path: file.path, oldPath: file.oldPath,
                                         title: "\(stash.name) \(stash.title)"))
        } label: {
            HStack(spacing: 8) {
                Text(file.status)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(ChangeStatus.color(file.status))
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((file.oldPath.map { "\($0) → \(file.path)" } ?? file.path) + "\n" + String(localized: "Click to see the changes"))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.changeError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    // Three lines whatever the width (see the note on the list's inset); all of it in the tooltip.
                    Text(error)
                        .font(.caption)
                        .lineLimit(3, reservesSpace: true)
                        .textSelection(.enabled)
                        .help(error)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissChangeError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
            }
            HStack(spacing: 8) {
                Button("Apply") {
                    Task { _ = await model.applyStash(stash) }
                }
                .help("Bring its changes back and keep the stash")
                Button("Pop") {
                    Task {
                        if await model.popStash(stash) { graph.selectWorkingTree() }
                    }
                }
                .help("Bring its changes back and drop the stash")
                if let progress = model.changeInProgress {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Drop…", role: .destructive) { confirmsDrop = true }
                    .help("Delete the stash and its changes")
            }
            .disabled(model.changeInProgress != nil)
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
