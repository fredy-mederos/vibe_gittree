import AppKit
import SwiftUI

// Settings › General's About and Updates sections. Vibe Notepad and KeepMyMacClean show the same rows.

/// Version, build (commit count · commit), configuration and build time, with Copy Version Info for bug reports.
struct AboutSection: View {
    var body: some View {
        Section("About \(BuildInfo.name)") {
            LabeledContent("Version", value: BuildInfo.version)
            LabeledContent("Build") {
                Text(verbatim: BuildInfo.buildDescription)
                    .monospacedDigit()
            }
            LabeledContent("Configuration") {
                Text(BuildInfo.configuration)
                    .foregroundStyle(BuildInfo.isDebug ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help(BuildInfo.isDebug
                          ? "A development build from Xcode or the build folder. \"Prepare a release\" installs a Release build."
                          : "An optimized build, as installed by scripts/install.sh or downloaded from GitHub.")
            }
            LabeledContent("Built") {
                if let date = BuildInfo.date {
                    Text(date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                } else {
                    Text("Unknown")
                }
            }
            HStack {
                Link("Source on GitHub", destination: AppUpdater.repositoryURL)
                Spacer()
                Button("Copy Version Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BuildInfo.summary, forType: .string)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// What the last update check found, with Check Now, or Download when there's a newer version.
struct UpdatesSection: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Section {
            LabeledContent {
                if updater.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if let release = updater.available {
                    Button("Download") { updater.download(release) }
                } else {
                    Button("Check Now") { Task { await updater.check() } }
                }
            } label: {
                Text(title)
                Text(detail)
            }
            if let release = updater.available {
                Link("Release Notes", destination: release.pageURL)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("GitTree asks GitHub for the newest release when it opens and once a day while it's open. GitTree › Check for Updates… asks any time.")
        }
    }

    private var title: String {
        if updater.isChecking { return "Checking for updates…" }
        if let release = updater.available { return "GitTree \(release.version) is available" }
        if updater.failure != nil { return "Couldn't check for updates" }
        if updater.lastChecked != nil { return "GitTree is up to date" }
        return "Not checked yet"
    }

    private var detail: String {
        if let release = updater.available {
            let released = release.publishedAt.map { " · released \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "You have \(BuildInfo.version)\(released)"
        }
        if let failure = updater.failure { return failure }
        if let checked = updater.lastChecked {
            let when = "Checked \(checked.formatted(.relative(presentation: .named)))"
            return updater.latest == nil ? "\(when) · no releases yet" : when
        }
        return BuildInfo.isDebug ? "Debug builds check only when you ask." : "GitTree checks when it opens."
    }
}
