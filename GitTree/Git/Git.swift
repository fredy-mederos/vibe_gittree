import Foundation

/// A failed git invocation, described with git's own message.
struct GitError: LocalizedError {
    let arguments: [String]
    let status: Int32
    let output: String

    var errorDescription: String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                for prefix in ["fatal: ", "error: ", "remote: "] where text.hasPrefix(prefix) {
                    text.removeFirst(prefix.count)
                }
                return text
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
        guard !lines.isEmpty else {
            return "git \(arguments.first ?? "") failed with exit code \(status)."
        }
        let message = lines.prefix(3).joined(separator: "\n")
        return message.prefix(1).uppercased() + message.dropFirst()
    }
}

/// Runs the git command-line tool. Everything GitTree knows about a repository comes through here.
enum Git {
    static var executableURL: URL {
        if let custom = AppSettings.gitExecutableOverride, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        return detectedExecutable
    }

    /// Homebrew's git when installed (usually newer), otherwise Apple's.
    static let detectedExecutable: URL = {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Never prompt (there is no terminal to answer), and find credential helpers installed by Homebrew.
    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        return environment
    }()

    /// Keeps machine-readable output stable whatever the user's git config says.
    static let baseArguments = ["-c", "log.showSignature=false", "-c", "color.ui=never", "-c", "core.quotePath=false"]

    /// - Parameter timeout: for commands that touch the network, so a stalled connection can't hang a fetch.
    static func run(_ arguments: [String], in directory: URL?, allowFailure: Bool = false, timeout: TimeInterval? = nil) async throws -> Data {
        try await ProcessRunner.run(executableURL, baseArguments + arguments, in: directory, environment: environment,
                                    timeout: timeout, allowFailure: allowFailure)
    }

    static func string(_ arguments: [String], in directory: URL?, allowFailure: Bool = false) async throws -> String {
        let data = try await run(arguments, in: directory, allowFailure: allowFailure)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Bytes collected from a pipe on a background thread.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
