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

/// "Open in New Tab": SwiftUI opens a separate window, which is then moved into the current
/// window's tab group as soon as it appears.
@MainActor enum WindowTabbing {
    private static weak var pendingParent: NSWindow?

    static func openNextWindowAsTab() {
        pendingParent = NSApp.keyWindow
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
