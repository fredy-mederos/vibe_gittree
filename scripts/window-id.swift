// Prints the window number of an app's largest on-screen window, for `screencapture -l`.
// Usage: swift scripts/window-id.swift "Vibe GitTree" [part of the window title]
import CoreGraphics

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Vibe GitTree"
let title = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .filter { window in
        guard let title else { return true }
        return (window[kCGWindowName as String] as? String)?.contains(title) ?? false
    }

func area(_ window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return 0 }
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

print(windows.max { area($0) < area($1) }?[kCGWindowNumber as String] as? Int ?? 0)
