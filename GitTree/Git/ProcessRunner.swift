import Foundation

/// A command that failed or ran too long.
struct CommandError: LocalizedError {
    let command: String
    let status: Int32
    let output: String
    var timedOut = false

    var errorDescription: String? {
        if timedOut { return "\(command) didn't answer in time." }
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
        guard !lines.isEmpty else { return "\(command) failed with exit code \(status)." }
        let message = lines.prefix(3).joined(separator: "\n")
        return message.prefix(1).uppercased() + message.dropFirst()
    }
}

/// Runs command-line tools off the main thread, draining both pipes so chatty tools can't stall,
/// and stopping them after a timeout so nothing hangs the app.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil, environment: [String: String],
                    timeout: TimeInterval? = nil, allowFailure: Bool = false) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runBlocking(executable, arguments, in: directory, environment: environment,
                                                                   timeout: timeout, allowFailure: allowFailure))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runBlocking(_ executable: URL, _ arguments: [String], in directory: URL?, environment: [String: String],
                            timeout: TimeInterval?, allowFailure: Bool) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let timedOut = LockedFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }

        let errors = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.append(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()

        let name = executable.lastPathComponent + (arguments.first(where: { !$0.hasPrefix("-") }).map { " \($0)" } ?? "")
        if timedOut.isSet {
            throw CommandError(command: name, status: process.terminationStatus, output: "", timedOut: true)
        }
        if process.terminationStatus != 0 && !allowFailure {
            throw CommandError(command: name, status: process.terminationStatus, output: String(decoding: errors.data, as: UTF8.self))
        }
        return output
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
