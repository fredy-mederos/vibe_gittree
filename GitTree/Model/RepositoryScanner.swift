import Foundation

/// Finds git repositories under a folder, for "Add Repositories in Folder…".
enum RepositoryScanner {
    /// Folders that hold dependencies or build output, never projects of their own.
    private static let skipped: Set<String> = [
        "node_modules", "build", "Build", "DerivedData", "Pods", "Carthage", "vendor", "dist", "target",
        ".build", ".gradle", "venv", ".venv", "__pycache__", "Library",
    ]

    static func repositories(in folder: URL, maxDepth: Int = 4) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            if isRepository(directory) {
                found.append(directory)
                continue
            }
            guard depth < maxDepth,
                  let children = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard !skipped.contains(child.lastPathComponent),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true
                else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// A working copy (has `.git`) or a bare repository (`HEAD` plus `objects/` and `refs/`).
    private static func isRepository(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) { return true }
        return directory.pathExtension == "git"
            && fileManager.fileExists(atPath: directory.appendingPathComponent("HEAD").path)
            && fileManager.fileExists(atPath: directory.appendingPathComponent("objects").path)
            && fileManager.fileExists(atPath: directory.appendingPathComponent("refs").path)
    }
}
