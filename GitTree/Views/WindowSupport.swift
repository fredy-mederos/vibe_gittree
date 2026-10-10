import AppKit
import SwiftUI

/// Hands a SwiftUI view its `NSWindow` once it's on screen.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowReportingView: NSView {
    let onWindow: (NSWindow) -> Void

    init(onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow(window) }
    }
}

/// What a repository window shows. SwiftUI focuses an existing window instead of opening a new one
/// when one already presents the same value, so each window also carries its own identity: opening
/// a repository that's already on screen in a new tab or window still opens one.
struct WindowTarget: Codable, Hashable {
    var repositoryID: UUID?
    var window = UUID()

    /// A new window for a repository.
    static func opening(_ repositoryID: UUID) -> WindowTarget {
        WindowTarget(repositoryID: repositoryID)
    }
}

/// "Open in New Tab": SwiftUI opens a separate window, which is then moved into the current
/// window's tab group as soon as it appears.
@MainActor enum WindowTabbing {
    private static weak var pendingParent: NSWindow?

    /// `window` is the window to add the tab to; the key window when it's not known.
    static func openNextWindowAsTab(in window: NSWindow?) {
        pendingParent = window ?? NSApp.keyWindow
        Task {
            // If the repository was already open, SwiftUI just focuses that window; don't tab a later one.
            try? await Task.sleep(for: .seconds(1))
            pendingParent = nil
        }
    }

    static func windowAppeared(_ window: NSWindow) {
        guard let parent = pendingParent, parent !== window else { return }
        pendingParent = nil
        parent.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}
