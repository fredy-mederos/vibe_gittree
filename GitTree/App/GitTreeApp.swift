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
        .commands {
            GitTreeCommands()
        }

        Settings {
            AppSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
