import SwiftUI

extension FocusedValues {
    @Entry var windowState: WindowState?
}

/// Menu bar commands. They act on the focused window.
struct GitTreeCommands: Commands {
    @FocusedValue(\.windowState) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()

        CommandGroup(after: .newItem) {
            Divider()
            Button("Switch to Repository…") { window?.isSwitcherPresented = true }
                .keyboardShortcut("k")
                .disabled(window == nil)
            Divider()
            Button("Add Local Repository…") { window?.addLocalRepository() }
                .keyboardShortcut("o")
                .disabled(window == nil)
            Button("Add Repositories in Folder…") { window?.addRepositoriesInFolder() }
                .disabled(window == nil)
            Button("Clone Remote Repository…") { window?.cloneRemoteRepository() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(window == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find Commits…") { window?.requestSearchFocus() }
                .keyboardShortcut("f")
                .disabled(window?.graph == nil)
            Button("Find Next") { window?.graph?.nextMatch() }
                .keyboardShortcut("g")
                .disabled(window?.graph == nil)
            Button("Find Previous") { window?.graph?.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(window?.graph == nil)
        }

        CommandMenu("Repository") {
            Button("Fetch") { window?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(window?.currentRepository == nil)
            Button("Reload") { window?.graph?.model.reload() }
                .keyboardShortcut("r")
                .disabled(window?.graph == nil)
            Button("Refresh Ticket Statuses") { JiraStore.shared.markAllStale() }
                .disabled(JiraStore.shared.profiles.isEmpty)

            Divider()

            Button("All Branches") { window?.graph?.scope = .all }
                .keyboardShortcut("1")
                .disabled(window?.graph == nil)
            Button("Local Branches") { window?.graph?.scope = .local }
                .keyboardShortcut("2")
                .disabled(window?.graph == nil)
            Button("Current Branch") { window?.graph?.scope = .head }
                .keyboardShortcut("3")
                .disabled(window?.graph == nil)
            Button(window?.graph?.showTags == false ? "Show Tags" : "Hide Tags") { window?.graph?.showTags.toggle() }
                .disabled(window?.graph == nil)
            Button("Go to HEAD") { window?.graph?.revealHead() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(window?.graph == nil)
            Button("Show Activity") {
                if let id = window?.repositoryID { openWindow(id: "activity", value: id) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(window?.repositoryID == nil)

            Divider()

            Button("Show in Finder") {
                if let window, let repository = window.currentRepository { window.showInFinder(repository) }
            }
            .disabled(window?.currentRepository == nil)
            Button("Open in Terminal") {
                if let window, let repository = window.currentRepository { window.openInTerminal(repository) }
            }
            .disabled(window?.currentRepository?.kind != .local)
            Button("Open on Web") {
                if let window, let repository = window.currentRepository { window.openOnWeb(repository) }
            }
            .disabled(window?.graph?.model.hosting == nil)

            Divider()

            Button("Repository Settings…") { window?.editingRepository = window?.currentRepository }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(window?.currentRepository == nil)
        }
    }
}
