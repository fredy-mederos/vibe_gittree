import SwiftUI

@main
struct GitTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per repository; windows can be merged into tabs.
        WindowGroup("Vibe GitTree", id: "repository", for: WindowTarget.self) { $target in
            RepositoryWindow(target: $target)
                .background(DarkerWindowBackground())
        }
        .defaultSize(width: 1400, height: 880)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            GitTreeCommands()
        }

        // The activity calendar, one window per repository.
        WindowGroup("Activity", id: "activity", for: UUID.self) { $repositoryID in
            ActivityWindow(repositoryID: repositoryID)
                .background(DarkerWindowBackground())
        }
        .defaultSize(width: 1000, height: 640)
        .handlesExternalEvents(matching: [])

        // Two branches side by side, opened from the Repository menu or a branch's context menu.
        WindowGroup("Compare Branches", id: "compare", for: CompareTarget.self) { $target in
            CompareWindow(target: $target)
                .background(DarkerWindowBackground())
        }
        .defaultSize(width: 1200, height: 760)
        .handlesExternalEvents(matching: [])

        // One window per file diff (or all of a commit's, a comparison's or the uncommitted ones),
        // opened from the inspector, a comparison or a deep link.
        WindowGroup("Changes", id: "diff", for: DiffTarget.self) { $target in
            DiffWindow(target: target)
                .background(DarkerWindowBackground())
        }
        .defaultSize(width: 1200, height: 760)
        .handlesExternalEvents(matching: [])

        Settings {
            AppSettingsView()
                .background(DarkerWindowBackground())
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppAppearance.current.apply()
            AppUpdater.shared.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A new version found while GitTree was in the background is announced when it comes to the front.
        MainActor.assumeIsolated { AppUpdater.shared.announceIfNew() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
