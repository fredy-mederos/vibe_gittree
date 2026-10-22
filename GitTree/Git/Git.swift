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
            return String(localized: "git \(arguments.first ?? "") failed with exit code \(String(status)).", comment: "A git command, like git fetch")
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

    /// Keeps machine-readable output stable whatever the user's git config says (patches always
    /// with `a/` and `b/` before their paths, which reading them relies on).
    static let baseArguments = ["-c", "log.showSignature=false", "-c", "color.ui=never", "-c", "core.quotePath=false",
                                "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false"]

    /// - Parameter timeout: for commands that touch the network, so a stalled connection can't hang a fetch.
    static func run(_ arguments: [String], in directory: URL?, allowFailure: Bool = false, timeout: TimeInterval? = nil) async throws -> Data {
        try await ProcessRunner.run(executableURL, baseArguments + arguments, in: directory, environment: environment,
                                    timeout: timeout, allowFailure: allowFailure)
    }

    static func string(_ arguments: [String], in directory: URL?, allowFailure: Bool = false) async throws -> String {
        let data = try await run(arguments, in: directory, allowFailure: allowFailure)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command that changes the repository (staging, committing, stashing). Only the user's
    /// own clicks start one, and only with Settings › General › Allow commits and stashes on.
    /// Commit hooks get five minutes, and a failure reads as git explains it, on standard output
    /// too (a stash that conflicts, say).
    @discardableResult
    static func change(_ arguments: [String], in directory: URL, input: Data? = nil) async throws -> String {
        let result = try await ProcessRunner.execute(executableURL, baseArguments + arguments, in: directory,
                                                     environment: environment, timeout: 5 * 60, input: input)
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.status == 0 else {
            throw GitError(arguments: arguments, status: result.status, output: failure(errors: String(decoding: result.errors, as: UTF8.self),
                                                                                     output: output))
        }
        return output
    }

    /// What a failed change says about why: conflicts first (git lists them on standard output),
    /// then its errors; with no errors, the last line it printed (`git commit` explains there that
    /// nothing is staged).
    private static func failure(errors: String, output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let conflicts = lines.filter { $0.hasPrefix("CONFLICT") || $0.hasPrefix("error:") || $0.hasPrefix("fatal:") }
        if !conflicts.isEmpty { return (conflicts + [errors]).joined(separator: "\n") }
        if errors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = lines.last(where: { !$0.isEmpty }) { return last }
        return errors
    }

    /// Paths for `--pathspec-from-file=- --pathspec-file-nul`, so any number of them (and any names)
    /// fit, each taken literally: a file named `a*b` is just that file. (Not `--literal-pathspecs`,
    /// which also takes the `:/` that `git stash` uses inside literally, so it would leave new files.)
    static func pathspecInput(_ paths: [String]) -> Data {
        Data(paths.map { ":(literal)" + $0 + "\u{0}" }.joined().utf8)
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
