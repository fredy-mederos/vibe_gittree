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
            state.resumePendingDeepLink()
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
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            JiraSettingsView()
                .tabItem { Label("Jira", systemImage: "ticket") }
            GitHubSettingsView()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }
        }
        .frame(width: 580)
    }
}

/// Light, dark, or following the system.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(AppSettings.gitPathKey) private var gitPath = ""
    @AppStorage(AppSettings.fetchOnOpenKey) private var fetchOnOpen = true
    @State private var version = ""

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in new.apply() }
            }
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
        .task(id: gitPath) {
            version = (try? await Git.string(["--version"], in: nil)) ?? "Not found"
        }
    }
}

/// Connect Jira to show ticket statuses. The token goes to the keychain.
private struct JiraSettingsView: View {
    @State private var site = UserDefaults.standard.string(forKey: JiraSettings.siteKey) ?? ""
    @State private var email = UserDefaults.standard.string(forKey: JiraSettings.emailKey) ?? ""
    @State private var token = ""
    @State private var hasSavedToken = JiraSettings.connection != nil
    @State private var status: String?
    @State private var isTesting = false

    private var isComplete: Bool {
        JiraSettings.normalizedSite(site) != nil && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && (!token.isEmpty || hasSavedToken)
    }

    var body: some View {
        Form {
            Section {
                TextField("Site", text: $site, prompt: Text("your-company.atlassian.net"))
                TextField("Email", text: $email, prompt: Text("you@company.com"))
                SecureField("API token", text: $token, prompt: Text(hasSavedToken ? "Saved in your keychain" : "Paste an API token"))
            } header: {
                Text("Jira Cloud")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ticket keys in commit messages (like ABC-123) show their status in a Ticket column and in the details. GitTree only asks Jira about tickets on screen, in small batches, and caches the answers.")
                    Link("Create an API token…", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                }
            }
            Section {
                HStack {
                    Button("Save and Test") { Task { await saveAndTest() } }
                        .disabled(!isComplete || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if hasSavedToken {
                        Button("Disconnect", role: .destructive) { disconnect() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func saveAndTest() async {
        JiraSettings.save(site: site, email: email, token: token.isEmpty ? nil : token)
        token = ""
        isTesting = true
        defer { isTesting = false }
        guard let connection = JiraSettings.connection else {
            hasSavedToken = false
            status = "Add the site, email and API token."
            return
        }
        hasSavedToken = true
        do {
            let name = try await JiraClient.myself(connection)
            status = "Connected as \(name)."
        } catch {
            status = error.localizedDescription
        }
    }

    private func disconnect() {
        if let host = JiraSettings.normalizedSite(site)?.host {
            Keychain.setPassword("", service: JiraSettings.keychainService, account: host)
        }
        JiraSettings.save(site: site, email: email, token: nil)
        hasSavedToken = false
        status = "Disconnected."
    }
}

/// Pull requests come from the GitHub CLI; this shows whether it's installed and signed in.
private struct GitHubSettingsView: View {
    @State private var status = "Checking…"

    var body: some View {
        Form {
            Section {
                LabeledContent("GitHub CLI", value: GitHubCLI.executableURL?.path ?? "Not installed")
                Text(status)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Pull Requests")
            } footer: {
                Text("GitTree reads pull requests with `gh` for repositories hosted on GitHub: one request when a repository loads, at most every five minutes, plus one when you fetch. Install it with `brew install gh` and sign in with `gh auth login`.")
            }
        }
        .formStyle(.grouped)
        .task { await check() }
    }

    private func check() async {
        guard let gh = GitHubCLI.executableURL else {
            status = "Install the GitHub CLI to see pull requests."
            return
        }
        let output = try? await ProcessRunner.run(gh, ["auth", "status"], environment: Git.environment, timeout: 15, allowFailure: true)
        let lines = String(decoding: output ?? Data(), as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("Logged in") || $0.contains("Active account") || $0.contains("not logged") }
        status = lines.isEmpty ? "Run `gh auth login` in Terminal to sign in." : lines.joined(separator: "\n")
    }
}
