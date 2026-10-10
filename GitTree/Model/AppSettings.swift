import Foundation

enum AppSettings {
    static let gitPathKey = "gitExecutablePath"
    static let fetchOnOpenKey = "fetchRemotesOnOpen"
    static let showTagsKey = "showTags"
    static let epicCommitLimitKey = "epicCommitLimit"

    /// A git binary the user picked in Settings, if any.
    static var gitExecutableOverride: String? {
        let value = UserDefaults.standard.string(forKey: gitPathKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    static var fetchRemotesOnOpen: Bool {
        UserDefaults.standard.object(forKey: fetchOnOpenKey) as? Bool ?? true
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
