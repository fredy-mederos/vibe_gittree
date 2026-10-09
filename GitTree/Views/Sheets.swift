import SwiftUI

/// Clone a remote repository by URL into GitTree's storage.
struct CloneSheet: View {
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var operation = CloneOperation()
    private let library = RepositoryLibrary.shared

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        HostingService.split(trimmedAddress) != nil || trimmedAddress.hasPrefix("/") || trimmedAddress.hasPrefix("file://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clone Remote Repository")
                        .font(.headline)
                    Text("GitTree downloads the commit history and folder structure, without file contents, into its own storage. Your other folders aren't touched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("Repository URL", text: $address, prompt: Text("https://github.com/owner/repository.git"))
                .textFieldStyle(.roundedBorder)
                .disabled(operation.isRunning)
                .onSubmit(start)

            if operation.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = operation.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(operation.phase)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if case .failed(let message) = operation.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    operation.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || operation.isRunning)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(operation.isRunning)
        .onAppear {
            if let url = state.pendingCloneURL {
                state.pendingCloneURL = nil
                address = url
                start()
            }
        }
    }

    private func start() {
        guard isValid, !operation.isRunning else { return }
        let url = trimmedAddress
        if let existing = library.existingRemote(url: url) {
            state.open(existing.id)
            dismiss()
            return
        }
        let destination = library.cloneDestination(for: url)
        operation.start(remoteURL: url, destination: destination) { result in
            guard case .success = result else { return }
            let repository = library.addRemote(url: url, clonedTo: destination)
            state.open(repository.id)
            dismiss()
        }
    }
}

/// Per-repository settings: name, issue links and the release tag pattern.
struct RepositorySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var repository: Repository

    init(repository: Repository) {
        _repository = State(initialValue: repository)
    }

    private var patternError: String? {
        guard let pattern = repository.releaseTagPattern, !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "This isn't a valid regular expression."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $repository.name)
                    LabeledContent("Location") {
                        Text(repository.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let remote = repository.remoteURL {
                        LabeledContent("Cloned from") {
                            Text(remote).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    TextField("Issue link", text: optional(\.issueURLTemplate),
                              prompt: Text("https://example.atlassian.net/browse/{key}"))
                } footer: {
                    Text("Ticket keys in commit messages, like ABC-123, open this link. {key} is replaced with the key.")
                }
                Section {
                    TextField("Release tags", text: optional(\.releaseTagPattern),
                              prompt: Text(Repository.defaultReleaseTagPattern))
                        .monospaced()
                } footer: {
                    if let patternError {
                        Text(patternError).foregroundStyle(.red)
                    } else {
                        Text("A regular expression for tags that mark a production release. The details show the first release that contains a commit.")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    repository.name = repository.name.trimmingCharacters(in: .whitespaces)
                    RepositoryLibrary.shared.update(repository)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repository.name.trimmingCharacters(in: .whitespaces).isEmpty || patternError != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540, height: 440)
    }

    private func optional(_ keyPath: WritableKeyPath<Repository, String?>) -> Binding<String> {
        Binding(
            get: { repository[keyPath: keyPath] ?? "" },
            set: { repository[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

/// GitTree > Settings.
struct AppSettingsView: View {
    @AppStorage(AppSettings.gitPathKey) private var gitPath = ""
    @AppStorage(AppSettings.fetchOnOpenKey) private var fetchOnOpen = true
    @State private var version = ""

    var body: some View {
        Form {
            Section("Git") {
                TextField("Git executable", text: $gitPath, prompt: Text(Git.detectedExecutable.path))
                LabeledContent("Version", value: version.isEmpty ? "…" : version)
            }
            Section("Remote Repositories") {
                Toggle("Fetch when a repository opens", isOn: $fetchOnOpen)
                LabeledContent("Stored in") {
                    HStack {
                        Text(AppPaths.clonesDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: AppPaths.clonesDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.clonesDirectory])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task(id: gitPath) {
            version = (try? await Git.string(["--version"], in: nil)) ?? "Not found"
        }
    }
}
