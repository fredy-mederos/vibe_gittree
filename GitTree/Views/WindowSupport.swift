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

extension NSColor {
    /// Windows' background in dark mode, a bit darker than the system's (#1E1E1E).
    static let darkerWindowBackground = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1)
}

/// Dark mode a bit darker than the system's: gives its window `darkerWindowBackground`, which the
/// sidebar's and the details' glass pick up too, and the system's background back in light mode
/// (with its wallpaper tinting, which a color of our own would turn off).
struct DarkerWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DarkerWindowBackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DarkerWindowBackgroundView: NSView {
    private var systemBackground: NSColor?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        guard let window else { return }
        if systemBackground == nil { systemBackground = window.backgroundColor }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        window.backgroundColor = isDark ? .darkerWindowBackground : systemBackground
    }
}

extension View {
    /// The sidebar and the details as dark as the commit list in dark mode: their glass dimmed
    /// behind their content (it still shows a little of what's behind it). Light mode is the system's.
    func darkerPanelInDarkMode() -> some View {
        modifier(DarkerPanel())
    }
}

private struct DarkerPanel: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            // Lists and forms would cover the dimming with a background of their own.
            .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
            .background(colorScheme == .dark ? Color.black.opacity(0.3) : .clear)
    }
}

/// Keeps the details' (the inspector's) width across launches, windows and repositories. SwiftUI
/// opens an inspector at its narrowest, sets it back there when the window's content changes (the
/// history loading, say) and doesn't remember a width it's dragged to; asked for a wider ideal or
/// narrowest width it can even fix the column's width. So the inspector keeps SwiftUI's range,
/// and this moves its divider in AppKit: to the width last dragged to, and back to it when
/// anything but a drag changes it.
@MainActor final class InspectorWidthKeeper {
    private weak var splitView: NSSplitView?
    private weak var item: NSSplitViewItem?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var width = 0.0
    private var range = 0.0...0.0
    private var save: (Double) -> Void = { _ in }
    private var saveTask: Task<Void, Never>?
    private var isRestoring = false
    /// Gives up putting the width back if something keeps changing it (until the next drag or showing).
    private var restoresLeft = 0

    /// Once the window's inspector is laid out, gives it `width`, then calls `save` with each width
    /// it's dragged to (when the dragging stops).
    func attach(to window: NSWindow?, width: Double, range: ClosedRange<Double>, save: @escaping (Double) -> Void) {
        self.width = min(max(width, range.lowerBound), range.upperBound)
        self.range = range
        self.save = save
        restoresLeft = 10
        Task {
            for _ in 0..<20 {
                if let content = window?.contentView, let (split, item) = Self.inspector(in: content), !item.isCollapsed {
                    watch(item, in: split)
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Opening, SwiftUI animates it to its narrowest, telling no one when it's done: for a
            // moment the kept width is given back whenever it isn't there (and not being dragged).
            for _ in 0..<20 {
                if NSEvent.pressedMouseButtons == 0 { restore() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The split view that holds an inspector, and the inspector's item.
    private static func inspector(in view: NSView) -> (NSSplitView, NSSplitViewItem)? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           let item = controller.splitViewItems.first(where: { $0.behavior == .inspector }) {
            return (split, item)
        }
        for subview in view.subviews {
            if let found = inspector(in: subview) { return found }
        }
        return nil
    }

    private func watch(_ item: NSSplitViewItem, in split: NSSplitView) {
        self.item = item
        guard split !== splitView else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        splitView = split
        observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        }
    }

    /// Dragged (the mouse is down on the divider): that's the width to keep, saved when the
    /// dragging stops. Changed otherwise while open: it gets the kept width back. Hiding it, opening
    /// it (until it's in range) and resizing the window change nothing.
    private func resized() {
        // A split view is in live resize while its divider is dragged too; the window only while it's resized.
        guard let item, let split = splitView, !isRestoring, !item.isCollapsed, split.window?.inLiveResize != true else { return }
        let current = Double(item.viewController.view.frame.width).rounded()
        guard range.contains(current) else { return }
        if NSEvent.pressedMouseButtons != 0 {
            width = current
            restoresLeft = 10
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.save(self.width)
            }
        } else if abs(current - width) >= 1, restoresLeft > 0 {
            restoresLeft -= 1
            // After the layout pass that changed it.
            Task { [weak self] in self?.restore() }
        }
    }

    private func restore() {
        guard let item, let split = splitView, !item.isCollapsed,
              let items = (split.delegate as? NSSplitViewController)?.splitViewItems,
              let index = items.firstIndex(of: item), index > 0 else { return }
        let view = item.viewController.view
        isRestoring = true
        defer { isRestoring = false }
        // The inspector is the last item, so its divider sits its width (and the divider's) from the right.
        var position = split.bounds.width - width - split.dividerThickness
        for _ in 0..<2 where abs(view.frame.width - width) >= 1 {
            split.setPosition(position, ofDividerAt: index - 1)
            position += view.frame.width - width
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
