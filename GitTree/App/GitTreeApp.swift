import SwiftUI

@main
struct GitTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per repository; windows can be merged into tabs.
        WindowGroup("GitTree", id: "repository", for: UUID.self) { $repositoryID in
            RepositoryWindow(repositoryID: $repositoryID)
        }
        .defaultSize(width: 1400, height: 880)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            GitTreeCommands()
        }

        // One window per file diff, opened from the inspector or a deep link.
        WindowGroup("Changes", id: "diff", for: DiffTarget.self) { $target in
            DiffWindow(target: target)
        }
        .defaultSize(width: 980, height: 720)
        .handlesExternalEvents(matching: [])

        Settings {
            AppSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppAppearance.current.apply() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
