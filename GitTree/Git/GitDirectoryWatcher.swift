import CoreServices
import Foundation

/// Watches a repository's git directory and reports what changed: refs (a commit, checkout,
/// fetch, rebase or gc), the index (staging) or the stash. Object writes, other reflogs and lock
/// files are ignored.
final class GitDirectoryWatcher {
    struct Change: OptionSet {
        let rawValue: Int
        static let refs = Change(rawValue: 1)
        static let index = Change(rawValue: 2)
        static let stash = Change(rawValue: 4)
    }

    private var events: FileEventStream?

    init?(directory: URL, onChange: @escaping (Change) -> Void) {
        events = FileEventStream(directory: directory, latency: 0.5) { paths, _ in
            let change = Self.change(in: paths)
            if !change.isEmpty { onChange(change) }
        }
        if events == nil { return nil }
    }

    private static func change(in paths: [String]) -> Change {
        var change: Change = []
        for path in paths {
            if path.hasSuffix(".lock") || path.contains("/objects/") { continue }
            // The stash isn't in the history; its ref and reflog only change the Stashes list.
            if path.hasSuffix("/refs/stash") {
                change.insert(.stash)
            } else if path.contains("/logs/") {
                continue
            } else if path.contains("/refs/") || path.hasSuffix("/HEAD") || path.hasSuffix("/packed-refs") {
                // Before the index: a branch can be called `feature/index`.
                change.insert(.refs)
            } else if path.hasSuffix("/index") {
                change.insert(.index)
            }
        }
        return change
    }
}

/// Watches a working tree's files and reports the ones that changed outside git's own folders
/// (relative to the working tree), or that events were dropped and everything should be looked at.
final class WorkingTreeWatcher {
    private var events: FileEventStream?

    init?(directory: URL, onChange: @escaping (_ paths: [String], _ everything: Bool) -> Void) {
        // The path as FSEvents reports it: `realpath` keeps `/private` (as in /private/tmp), which
        // `resolvingSymlinksInPath()` takes off.
        let root = directory.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return directory.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        events = FileEventStream(directory: URL(fileURLWithPath: root), latency: 0.5) { paths, rescan in
            var changed: [String] = []
            for path in paths {
                guard path.hasPrefix(root + "/") else {
                    // The working tree's own folder: something in it was added or removed.
                    if path == root || path == root + "/" { changed.append("") }
                    continue
                }
                let relative = String(path.dropFirst(root.count + 1))
                if relative == ".git" || relative.hasPrefix(".git/") || relative.contains("/.git/") || relative.hasSuffix("/.git") { continue }
                changed.append(relative)
            }
            if rescan || !changed.isEmpty { onChange(changed, rescan) }
        }
        if events == nil { return nil }
    }
}

/// An FSEvents stream for a folder and everything in it, delivering changed paths on the main
/// queue, and whether the system dropped events (so the folder needs a full look).
private final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let handler: ([String], Bool) -> Void

    init?(directory: URL, latency: CFTimeInterval, handler: @escaping ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let stream = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            let rescan = (0..<count).contains { flags[$0] & dropped != 0 }
            stream.handler(list, rescan)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
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
}
