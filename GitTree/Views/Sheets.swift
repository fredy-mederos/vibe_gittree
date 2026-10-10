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
    @State private var ticketPrefixes: String
    private let initialJiraProfileID: UUID?

    init(repository: Repository) {
        _repository = State(initialValue: repository)
        _ticketPrefixes = State(initialValue: repository.customTicketPrefixes.joined(separator: ", "))
        initialJiraProfileID = repository.jiraProfileID
    }

    /// The repository's profile; one that was removed reads as none.
    private var jiraProfile: Binding<UUID?> {
        Binding(
            get: { JiraStore.shared.profile(id: repository.jiraProfileID)?.id },
            set: { repository.jiraProfileID = $0 }
        )
    }

    /// What GitTree found in the commit messages, shown when no keys are set.
    private var detectedPrefixes: String {
        let detected = RepositoryModelStore.shared.existingModel(id: repository.id)?.graph?.ticketPrefixes ?? []
        return detected.isEmpty ? "Detected from commit messages" : "Detected: " + detected.prefix(4).joined(separator: ", ")
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
                    Picker("Jira", selection: jiraProfile) {
                        Text("No Jira").tag(UUID?.none)
                        ForEach(JiraStore.shared.profiles) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                    TextField("Ticket keys", text: $ticketPrefixes, prompt: Text(detectedPrefixes))
                    TextField("Issue link", text: optional(\.issueURLTemplate),
                              prompt: Text("https://example.atlassian.net/browse/{key}"))
                } header: {
                    Text("Tickets")
                } footer: {
                    Text("Ticket keys like ABC-123 in commit messages show their status from this Jira (profiles are in Settings › Jira). Ticket keys limits them to these projects, separated by commas; leave it empty to detect them. Issue link opens tickets somewhere else, with {key} for the key.")
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
                    // Onto the latest copy, so changes made elsewhere meanwhile (pins, fetch times,
                    // the Jira profile picked in Settings) aren't undone by an older one.
                    guard var latest = RepositoryLibrary.shared.repository(id: repository.id) else {
                        dismiss()
                        return
                    }
                    latest.name = repository.name.trimmingCharacters(in: .whitespaces)
                    latest.issueURLTemplate = repository.issueURLTemplate
                    latest.releaseTagPattern = repository.releaseTagPattern
                    if repository.jiraProfileID != initialJiraProfileID { latest.jiraProfileID = repository.jiraProfileID }
                    let prefixes = ticketPrefixes.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    latest.ticketPrefixes = prefixes.isEmpty ? nil : prefixes
                    RepositoryLibrary.shared.update(latest)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repository.name.trimmingCharacters(in: .whitespaces).isEmpty || patternError != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 560)
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
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            JiraSettingsView()
                .tabItem { Label("Jira", systemImage: "ticket") }
                .tag("jira")
            GitHubSettingsView()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }
                .tag("github")
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

/// Jira profiles (a site and an account each), which one each repository uses, and the one new
/// repositories start with.
private struct JiraSettingsView: View {
    @Bindable private var store = JiraStore.shared
    @Bindable private var library = RepositoryLibrary.shared
    @State private var editing: JiraProfile?

    var body: some View {
        Form {
            Section {
                if store.profiles.isEmpty {
                    Text("No profiles yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text([profile.host, profile.email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.connection(for: profile) == nil {
                            Text("Incomplete")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let problem = store.problems[profile.id] {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(problem)
                        }
                        Button("Edit…") { editing = profile }
                    }
                }
                Button("Add Profile…") { editing = JiraProfile(id: UUID(), name: "", site: "", email: "") }
            } header: {
                Text("Profiles")
            } footer: {
                Text("A profile is a Jira Cloud site and the account GitTree uses there. Ticket keys in commit messages (like ABC-123) show their status in a Ticket column and in the details. GitTree only asks Jira about tickets on screen, in small batches, and caches the answers.")
            }
            Section {
                Picker("New repositories", selection: $store.defaultProfileID) {
                    profileOptions
                }
                ForEach(library.repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { repository in
                    Picker(selection: profileBinding(for: repository)) {
                        profileOptions
                    } label: {
                        Text(repository.name)
                        Text(repository.locationSummary)
                    }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("Each repository shows ticket statuses from its own Jira, or none.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 540)
        .sheet(item: $editing) { profile in
            JiraProfileEditor(profile: profile, isNew: store.profile(id: profile.id) == nil)
        }
    }

    @ViewBuilder private var profileOptions: some View {
        Text("No Jira").tag(UUID?.none)
        ForEach(store.profiles) { profile in
            Text(profile.name).tag(UUID?.some(profile.id))
        }
    }

    /// A repository's profile; one that was removed reads as none.
    private func profileBinding(for repository: Repository) -> Binding<UUID?> {
        Binding(
            get: { store.profile(id: repository.jiraProfileID)?.id },
            set: { library.setJiraProfile($0, for: repository.id) }
        )
    }
}

/// Adds or edits a Jira profile. The token goes to the keychain.
private struct JiraProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: JiraProfile
    @State private var isNew: Bool
    @State private var token = ""
    @State private var hasSavedToken: Bool
    @State private var status: String?
    @State private var isTesting = false
    @State private var confirmsRemoval = false

    init(profile: JiraProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        _isNew = State(initialValue: isNew)
        _hasSavedToken = State(initialValue: JiraProfiles.token(for: profile.id) != nil)
    }

    private var isComplete: Bool {
        profile.baseURL != nil && !profile.email.trimmingCharacters(in: .whitespaces).isEmpty && (!token.isEmpty || hasSavedToken)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $profile.name, prompt: Text("Work"))
                    TextField("Site", text: $profile.site, prompt: Text("your-company.atlassian.net"))
                    TextField("Email", text: $profile.email, prompt: Text("you@company.com"))
                    SecureField("API token", text: $token, prompt: Text(hasSavedToken ? "Saved in your keychain" : "Paste an API token"))
                } header: {
                    Text(isNew ? "New Jira Profile" : "Jira Profile")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let status {
                            Text(status)
                        }
                        Link("Create an API token…", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Remove…", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
                Button(isNew ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Test") { Task { await saveAndTest() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete || isTesting)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .confirmationDialog("Remove “\(profile.name)”?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                JiraStore.shared.remove(profileID: profile.id)
                dismiss()
            }
        } message: {
            Text("Its API token is removed from your keychain. Repositories that use it show no ticket statuses until you pick another profile.")
        }
    }

    private func saveAndTest() async {
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.name = profile.host?.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Jira"
        }
        JiraStore.shared.save(profile, token: token)
        token = ""
        isNew = false
        hasSavedToken = JiraProfiles.token(for: profile.id) != nil
        guard let connection = JiraStore.shared.connection(for: profile) else {
            status = "Add the site, email and API token."
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let name = try await JiraClient.myself(connection)
            status = "Saved. Connected as \(name)."
        } catch {
            status = "Saved, but the test failed: \(error.localizedDescription)"
        }
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
