import Foundation

/// What Settings › General shows about this copy of Vibe GitTree. `scripts/install.sh` and `scripts/release.sh` stamp
/// the build number, the commit and the build time into Info.plist.
enum BuildInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static let name = "Vibe GitTree"

    /// `0.1.0`.
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "–" }

    /// The number of commits it was built from; 1 in development builds.
    static var build: String { info["CFBundleVersion"] as? String ?? "–" }

    /// The short hash it was built from; nil when built from Xcode.
    static var commit: String? { stampedCommit.map { $0.hasSuffix("+") ? String($0.dropLast()) : $0 } }

    /// It was built with changes that weren't committed yet (stamped as a `+` after the hash).
    static var hasLocalChanges: Bool { stampedCommit?.hasSuffix("+") ?? false }

    private static var stampedCommit: String? {
        (info["GTBuildCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// When it was built: the stamped time, or else the executable's modification time, which code signing sets
    /// at the end of every build and `ditto` keeps when installing.
    static var date: Date? {
        if let stamp = info["GTBuildDate"] as? String, let date = try? Date(stamp, strategy: .iso8601) { return date }
        guard let path = Bundle.main.executableURL?.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// "Debug" or "Release".
    static var configuration: String { isDebug ? "Debug" : "Release" }

    /// `12 · a481f3a`, `12 · a481f3a + local changes`, or `1` in development builds.
    static var buildDescription: String {
        var text = build
        if let commit { text += " · \(commit)" }
        if hasLocalChanges { text += " + " + String(localized: "local changes", comment: "A build made with uncommitted changes: 12 · a481f3a + local changes") }
        return text
    }

    /// For pasting into a bug report: `Vibe GitTree 1.2.0 (27, a481f3a), Release, built 2026-10-11 08:01`.
    static var summary: String {
        let details = [build, commit.map { hasLocalChanges ? $0 + "+" : $0 }].compactMap { $0 }.joined(separator: ", ")
        let built = date.map { ", built " + $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
            + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "\(name) \(version) (\(details)), \(configuration)\(built)"
    }
}
