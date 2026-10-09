import CoreServices
import Foundation

/// Watches a repository's git directory and reports when refs change: a commit, checkout, fetch,
/// rebase or gc. Object writes, reflogs and lock files are ignored.
final class GitDirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(list)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(_ paths: [String]) {
        let relevant = paths.contains { path in
            if path.hasSuffix(".lock") || path.contains("/objects/") || path.contains("/logs/") { return false }
            return path.contains("/refs/") || path.hasSuffix("/HEAD") || path.hasSuffix("/packed-refs")
        }
        if relevant { onChange() }
    }
}
