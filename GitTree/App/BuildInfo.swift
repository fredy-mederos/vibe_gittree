import Foundation

/// What Settings › General shows about this copy of GitTree.
enum BuildInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// `0.1.0`.
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "–" }

    /// The number of commits it was built from when `scripts/install.sh` built it; 1 in development builds.
    static var build: String { info["CFBundleVersion"] as? String ?? "–" }

    /// The short hash it was built from, with `+` when there were uncommitted changes; nil when
    /// built from Xcode.
    static var commit: String? {
        (info["GTBuildCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// When it was built: the executable's modification time, which code signing sets at the end
    /// of every build and `ditto` keeps when installing.
    static var date: Date? {
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

    /// For pasting into a bug report: `GitTree 0.1.0 (12, a481f3a), Release, built 2026-10-10 08:01`.
    static var summary: String {
        let details = [build, commit].compactMap { $0 }.joined(separator: ", ")
        let built = date.map { ", built " + $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
            + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return "GitTree \(version) (\(details)), \(configuration)\(built)"
    }
}
