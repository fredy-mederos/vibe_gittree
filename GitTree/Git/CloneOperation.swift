import Foundation
import Observation

/// Clones a remote repository into GitTree's own storage with live progress.
///
/// The clone is bare (no working files) and blobless (commits and trees only, file contents are
/// downloaded on demand), which is all a history viewer needs and much faster than a full clone.
@MainActor @Observable final class CloneOperation {
    enum State: Equatable {
        case idle, running, finished, failed(String), cancelled
    }

    private(set) var state: State = .idle
    private(set) var phase = ""
    private(set) var fraction: Double?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pendingProgress = ""

    var isRunning: Bool { state == .running }

    func start(remoteURL: String, destination: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard state != .running else { return }
        state = .running
        phase = "Connecting…"
        fraction = nil
        pendingProgress = ""

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = Git.baseArguments + ["clone", "--bare", "--filter=blob:none", "--progress", remoteURL, destination.path]
        process.environment = Git.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let log = LockedData()

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            log.append(chunk)
            let text = String(decoding: chunk, as: UTF8.self)
            Task { @MainActor [weak self] in self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            stderr.fileHandleForReading.readabilityHandler = nil
            log.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let status = finished.terminationStatus
            // Clean up here rather than in `finish`, which won't run if the sheet is already gone.
            if status != 0 { try? FileManager.default.removeItem(at: destination) }
            let output = String(decoding: log.data, as: UTF8.self)
            Task { @MainActor [weak self] in
                await self?.finish(status: status, output: output, remoteURL: remoteURL, destination: destination, completion: completion)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
            completion(.failure(error))
        }
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        process?.terminate()
    }

    /// git rewrites its progress line with carriage returns; show the latest one.
    private func consume(_ text: String) {
        pendingProgress += text
        let lines = pendingProgress.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        if let last = pendingProgress.last, last != "\r" && last != "\n" {
            pendingProgress = String(lines.last ?? "")
        } else {
            pendingProgress = ""
        }
        guard let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        var display = line.trimmingCharacters(in: .whitespaces)
        if display.hasPrefix("remote: ") { display.removeFirst("remote: ".count) }
        if let match = display.firstMatch(of: #/^([A-Za-z][A-Za-z ]+):\s+(\d+)%/#) {
            phase = display.replacingOccurrences(of: ", done.", with: "")
            fraction = (Double(match.2) ?? 0) / 100
        } else if display.hasPrefix("Cloning into") {
            phase = "Connecting…"
        }
    }

    private func finish(status: Int32, output: String, remoteURL: String, destination: URL,
                        completion: @MainActor (Result<Void, Error>) -> Void) async {
        process = nil
        if state == .cancelled {
            try? FileManager.default.removeItem(at: destination)
            completion(.failure(CancellationError()))
            return
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let error = GitError(arguments: ["clone"], status: status, output: output)
            state = .failed(error.localizedDescription)
            completion(.failure(error))
            return
        }
        // A bare clone has no fetch refspec; map the remote's branches straight onto ours so
        // `git fetch` keeps every branch current and prunes deleted ones.
        _ = try? await Git.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], in: destination)
        phase = "Done"
        fraction = 1
        state = .finished
        completion(.success(()))
    }
}
