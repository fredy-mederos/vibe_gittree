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
                    Text("Vibe GitTree downloads the commit history and folder structure, without file contents, into its own storage. Your other folders aren't touched.")
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

/// Per-repository settings: name, Jira and issue links, its fix versions and the release tag pattern.
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
        return detected.isEmpty ? String(localized: "Detected from commit messages")
            : String(localized: "Detected: \(detected.prefix(4).joined(separator: ", "))", comment: "Followed by ticket keys found in commit messages, like PROJ, ABC")
    }

    private var patternError: String? {
        guard let pattern = repository.releaseTagPattern, !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return String(localized: "This isn't a valid regular expression.")
        }
    }

    private var fixVersionError: String? {
        guard let pattern = repository.fixVersionPattern?.trimmingCharacters(in: .whitespaces), !pattern.isEmpty else { return nil }
        return repository.fixVersionRegex == nil ? String(localized: "This isn't a valid regular expression.") : nil
    }

    /// The repository's history, when it's loaded, for the branches it has.
    private var graph: CommitGraph? {
        RepositoryModelStore.shared.existingModel(id: repository.id)?.graph
    }

    private var typedMainBranch: String {
        (repository.mainBranch ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The main branch when none is picked.
    private var defaultMainBranch: String {
        var automatic = repository
        automatic.mainBranch = nil
        guard let graph, let name = automatic.effectiveMainBranch(in: graph) else { return String(localized: "The default branch") }
        return String(localized: "Default: \(name)", comment: "The main branch used when none is typed")
    }

    /// Branches matching what's typed, likely trunks (develop, main, release branches) first.
    private var mainBranchSuggestions: [String] {
        guard let graph else { return [] }
        let typed = typedMainBranch
        var names: Set<String> = []
        for ref in graph.refs {
            if ref.kind == .local {
                names.insert(ref.name)
            } else if let branch = ref.remoteParts?.branch {
                names.insert(branch)
            }
        }
        let matching = names.filter { name in
            typed.isEmpty ? PullRequestIndex.isLongLived(name) : name != typed && name.localizedCaseInsensitiveContains(typed)
        }
        return Array(matching.sorted { a, b in
            let (aLong, bLong) = (PullRequestIndex.isLongLived(a), PullRequestIndex.isLongLived(b))
            return aLong != bLong ? aLong : a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(10))
    }

    private var mainBranchError: String? {
        let name = typedMainBranch
        guard !name.isEmpty, let graph, !MainBranch.exists(name, in: graph) else { return nil }
        return String(localized: "There's no branch named \(name); the default branch is drawn instead.")
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
                    TextField("Main branch", text: optional(\.mainBranch), prompt: Text(defaultMainBranch))
                        .textInputSuggestions {
                            ForEach(mainBranchSuggestions, id: \.self) { name in
                                Text(name).textInputCompletion(name)
                            }
                        }
                } footer: {
                    if let mainBranchError {
                        Text(mainBranchError).foregroundStyle(.red)
                    } else {
                        Text("Drawn as a straight blue line on the left of the graph, down to the first commit; what was merged into it keeps other colors. Leave it empty for the repository's default branch on GitHub (or the one git noted when cloning), else main, master, develop or trunk.")
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
                    TextField("Fix versions", text: optional(\.fixVersionPattern), prompt: Text("The ones its tickets are in"))
                        .monospaced()
                } footer: {
                    if let fixVersionError {
                        Text(fixVersionError).foregroundStyle(.red)
                    } else {
                        Text("A regular expression for this repository's fix versions in Releases, like Android or ^iOS, when its Jira project's tickets don't tell (a project shared by several apps, say). Leave it empty for the fix versions its tickets are in.")
                    }
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
                    latest.fixVersionPattern = repository.fixVersionPattern
                    latest.mainBranch = typedMainBranch.isEmpty ? nil : typedMainBranch
                    if repository.jiraProfileID != initialJiraProfileID { latest.jiraProfileID = repository.jiraProfileID }
                    let prefixes = ticketPrefixes.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    latest.ticketPrefixes = prefixes.isEmpty ? nil : prefixes
                    RepositoryLibrary.shared.update(latest)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repository.name.trimmingCharacters(in: .whitespaces).isEmpty || patternError != nil || fixVersionError != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 740)
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
        case .system: String(localized: "System", comment: "Appearance that follows the system's")
        case .light: String(localized: "Light", comment: "Light appearance")
        case .dark: String(localized: "Dark", comment: "Dark appearance")
        }
    }

    static var current: AppAppearance {
        #if DEBUG
        // Test runs pick one with -GTAppearance dark|light, whatever the setting says.
        if let forced = UserDefaults.standard.string(forKey: "GTAppearance").flatMap(AppAppearance.init(rawValue:)) { return forced }
        #endif
        return AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
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
    @AppStorage(AppSettings.groupsFeaturesKey) private var groupsFeatures = false
    @AppStorage(AppSettings.allowsChangesKey) private var allowsChanges = false
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
            Section {
                Toggle("Group recent commits into features", isOn: $groupsFeatures)
            } footer: {
                Text("A Features section in the sidebar sorts recent commits by the terms in their messages, with Apple's on-device model for the rest. Epics and Releases group the same work by Jira.")
            }
            Section {
                Toggle("Allow commits and stashes", isOn: $allowsChanges)
            } footer: {
                Text("Uncommitted Changes gets checkboxes to stage files, and a box to commit or stash them; stashes can be applied, popped or dropped. Off, Vibe GitTree never changes a repository (fetching aside).")
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
            AboutSection()
            UpdatesSection()
        }
        .formStyle(.grouped)
        .task(id: gitPath) {
            version = (try? await Git.string(["--version"], in: nil)) ?? String(localized: "Not found")
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
                Text("A profile is a Jira Cloud site and the account Vibe GitTree uses there. Ticket keys in commit messages (like ABC-123) show their status in a Ticket column and in the details. Vibe GitTree only asks Jira about tickets on screen, in small batches, and caches the answers.")
            }
            ForEach(store.profiles) { profile in
                DefinitionOfDoneSection(profile: profile, showsName: store.profiles.count > 1)
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

/// A profile's Definition of Done: per project, the statuses that count as done on the development
/// side, like Jira's own done ones. The progress of releases and epics, status colors and
/// highlights count them.
private struct DefinitionOfDoneSection: View {
    let profile: JiraProfile
    let showsName: Bool
    private let store = JiraStore.shared
    /// Projects added here by key, before they have statuses of their own.
    @State private var added: [String] = []
    @State private var newProject = ""

    var body: some View {
        let _ = store.version
        let projects = (store.knownProjects(profileID: profile.id) + added.filter { !store.knownProjects(profileID: profile.id).contains($0) })
        Section {
            if projects.isEmpty {
                Text("Projects show up here once Vibe GitTree has listed their releases.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projects, id: \.self) { project in
                DoneStatusesRow(project: project, profileID: profile.id)
            }
            HStack {
                TextField("Add project", text: $newProject, prompt: Text("Project key, like PROJ"))
                    .onSubmit(addProject)
                Button("Add", action: addProject)
                    .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(showsName ? "Definition of Done · \(profile.name)" : "Definition of Done")
        } footer: {
            Text("Tickets in these statuses count as done on the development side, like Jira's Done and Released: in the progress of releases and epics, in status colors and in Highlight. Separate statuses with commas; + adds one seen in the project's tickets.")
        }
    }

    private func addProject() {
        let key = newProject.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return }
        if !added.contains(key) { added.append(key) }
        newProject = ""
    }
}

/// A project's statuses that count as done, typed or picked from the ones seen in its tickets.
private struct DoneStatusesRow: View {
    let project: String
    let profileID: UUID
    private let store = JiraStore.shared
    /// As typed; each change is saved.
    @State private var text = ""

    var body: some View {
        let chosen = Set(Self.statuses(in: text).map { $0.lowercased() })
        let others = store.knownStatuses(project: project, profileID: profileID).filter { !chosen.contains($0.lowercased()) }
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Done statuses", text: $text, prompt: Text("Dev Done, Ready for Release"))
                    .labelsHidden()
                Menu {
                    ForEach(others, id: \.self) { status in
                        Button(status) { text = (Self.statuses(in: text) + [status]).joined(separator: ", ") }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(others.isEmpty)
                .help(others.isEmpty ? "No other statuses seen in \(project)'s tickets yet" : "Add a status seen in \(project)'s tickets")
            }
        } label: {
            Text(verbatim: project).monospaced()
        }
        .onAppear { text = store.doneStatuses(project: project, profileID: profileID).joined(separator: ", ") }
        .onChange(of: text) { _, new in store.setDoneStatuses(Self.statuses(in: new), project: project, profileID: profileID) }
    }

    private static func statuses(in text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
            status = String(localized: "Add the site, email and API token.")
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let name = try await JiraClient.myself(connection)
            status = String(localized: "Saved. Connected as \(name).")
        } catch {
            status = String(localized: "Saved, but the test failed: \(error.localizedDescription)")
        }
    }
}

/// Pull requests come from the GitHub CLI; this shows whether it's installed and signed in.
private struct GitHubSettingsView: View {
    @State private var status = String(localized: "Checking…")

    var body: some View {
        Form {
            Section {
                LabeledContent("GitHub CLI", value: GitHubCLI.executableURL?.path ?? String(localized: "Not installed"))
                Text(status)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Pull Requests")
            } footer: {
                Text("Vibe GitTree reads pull requests with `gh` for repositories hosted on GitHub: one request when a repository loads, at most every five minutes, plus one when you fetch. Install it with `brew install gh` and sign in with `gh auth login`.")
            }
        }
        .formStyle(.grouped)
        .task { await check() }
    }

    private func check() async {
        guard let gh = GitHubCLI.executableURL else {
            status = String(localized: "Install the GitHub CLI to see pull requests.")
            return
        }
        let output = try? await ProcessRunner.run(gh, ["auth", "status"], environment: Git.environment, timeout: 15, allowFailure: true)
        let lines = String(decoding: output ?? Data(), as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("Logged in") || $0.contains("Active account") || $0.contains("not logged") }
        status = lines.isEmpty ? String(localized: "Run `gh auth login` in Terminal to sign in.") : lines.joined(separator: "\n")
    }
}
