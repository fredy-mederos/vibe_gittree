import Foundation

enum AppSettings {
    static let gitPathKey = "gitExecutablePath"
    static let fetchOnOpenKey = "fetchRemotesOnOpen"
    static let showTagsKey = "showTags"
    static let epicCommitLimitKey = "epicCommitLimit"
    /// The sidebar's Features section (commits grouped by term, with Apple's on-device model), off
    /// by default: the Epics and Releases sections group the same work by Jira.
    static let groupsFeaturesKey = "groupsFeatures"
    /// Staging, committing and stashing (Settings › General), off by default: until it's turned on,
    /// Vibe GitTree never changes a repository (fetching aside).
    static let allowsChangesKey = "allowsRepositoryChanges"
    /// The details' (inspector's) width, kept for every window and repository.
    static let inspectorWidthKey = "inspectorWidth"
    /// The sidebar's starting width, which the details start with too.
    static let defaultInspectorWidth = 280.0

    /// A git binary the user picked in Settings, if any.
    static var gitExecutableOverride: String? {
        let value = UserDefaults.standard.string(forKey: gitPathKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    static var fetchRemotesOnOpen: Bool {
        UserDefaults.standard.object(forKey: fetchOnOpenKey) as? Bool ?? true
    }

    /// Whether staging, committing and stashing are allowed, from where the windows read it (test
    /// runs have preferences of their own).
    @MainActor static var allowsChanges: Bool {
        #if DEBUG
        DebugLaunch.appStorage.bool(forKey: allowsChangesKey)
        #else
        UserDefaults.standard.bool(forKey: allowsChangesKey)
        #endif
    }
}

enum AppPaths {
    static let dataDirectory: URL = {
        #if DEBUG
        // Lets test runs use a throwaway library instead of the real one.
        if let custom = UserDefaults.standard.string(forKey: "GTDataDirectory") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("GitTree", isDirectory: true)
    }()

    static var libraryFile: URL { dataDirectory.appendingPathComponent("library.json") }

    /// Remote repositories are cloned here, one folder per host/owner/name.
    static var clonesDirectory: URL { dataDirectory.appendingPathComponent("Clones", isDirectory: true) }
}
