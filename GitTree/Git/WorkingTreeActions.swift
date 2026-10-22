import Foundation

/// The commands that change a repository, besides `fetch`: staging, committing and stashing. Each
/// one is started by a click, and only with Settings › General › Allow commits and stashes on.
/// Nothing here discards changes: unstaging keeps them in the working tree, and a stash keeps
/// what it takes.
enum WorkingTreeActions {
    /// Stages files for the next commit: their changes, their deletion, or the new file.
    static func stage(_ paths: [String], in directory: URL) async throws {
        try await Git.change(["add", "--pathspec-from-file=-", "--pathspec-file-nul"], in: directory, input: Git.pathspecInput(paths))
    }

    static func stageAll(in directory: URL) async throws {
        try await Git.change(["add", "--all"], in: directory)
    }

    /// Takes files out of the next commit and keeps their changes (also before the first commit,
    /// where `git restore --staged` has no HEAD to go back to).
    static func unstage(_ paths: [String], in directory: URL) async throws {
        try await Git.change(["reset", "--quiet", "--pathspec-from-file=-", "--pathspec-file-nul"], in: directory,
                             input: Git.pathspecInput(paths))
    }

    static func unstageAll(in directory: URL) async throws {
        try await Git.change(["reset", "--quiet"], in: directory)
    }

    /// Commits what's staged. The message comes on standard input, so it can start with anything;
    /// the repository's hooks run as they would in Terminal.
    static func commit(message: String, in directory: URL) async throws {
        try await Git.change(["commit", "--quiet", "--file=-"], in: directory, input: Data(message.utf8))
    }

    /// Stashes the changes to these files (staged or not, new files too), or to every file.
    static func stash(_ paths: [String]?, message: String, in directory: URL) async throws {
        var arguments = ["stash", "push", "--quiet", "--include-untracked"]
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { arguments += ["--message", message] }
        if let paths {
            try await Git.change(arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"], in: directory, input: Git.pathspecInput(paths))
        } else {
            try await Git.change(arguments, in: directory)
        }
    }

    /// Brings a stash's changes back, keeping the stash.
    static func apply(_ stash: ObjectID, in directory: URL) async throws {
        let name = try await reference(to: stash, in: directory)
        // Not quiet: git names the files that conflict on standard output.
        try await Git.change(["stash", "apply", name], in: directory)
    }

    /// Brings a stash's changes back and drops it, unless they conflict (then it's kept).
    static func pop(_ stash: ObjectID, in directory: URL) async throws {
        let name = try await reference(to: stash, in: directory)
        try await Git.change(["stash", "pop", name], in: directory)
    }

    /// Deletes a stash.
    static func drop(_ stash: ObjectID, in directory: URL) async throws {
        let name = try await reference(to: stash, in: directory)
        try await Git.change(["stash", "drop", "--quiet", name], in: directory)
    }

    /// `stash@{n}` for a stash, looked up again just before using it: git takes stashes only by
    /// their place in the list, which changes when one is added or dropped.
    private static func reference(to stash: ObjectID, in directory: URL) async throws -> String {
        guard let entry = await StashLoader.list(in: directory).first(where: { $0.id == stash }) else {
            throw GitError(arguments: ["stash"], status: 1, output: String(localized: "This stash isn't there anymore: it was applied or dropped elsewhere."))
        }
        return entry.name
    }
}
