import Foundation

/// What one changed file's checkbox says to commit
/// (docs/plans/003_the_checkbox_commit.md).
public enum FileSelection: Sendable, Equatable {
    case all
    /// Unchecked. Not `none`, which a lookup in a dictionary of these
    /// would read as nil.
    case nothing
    /// Some of its changed lines: indices into `lines` of the diff they
    /// were chosen in, which is kept to cut the patch from.
    case lines(Set<Int>, of: FileDiff)

    /// `picked` as the simplest selection that says the same.
    public static func picking(_ picked: Set<Int>, in diff: FileDiff) -> FileSelection {
        if picked.isEmpty { return .nothing }
        if picked.count == diff.changedLines.count { return .all }
        return .lines(picked, of: diff)
    }
}

public enum CommitError: Error, LocalizedError, Equatable {
    /// A file changed after its lines were chosen, so the chosen indices
    /// now point at other lines.
    case changedSinceChosen(path: String)

    public var errorDescription: String? {
        switch self {
        case .changedSinceChosen(let path):
            "“\(path)” changed after its lines were chosen. Choose them again, then commit."
        }
    }
}

extension Git {
    /// Commits exactly the selected files and lines, the way `git commit
    /// --only` commits its paths: from a temporary index that starts as
    /// HEAD, so whatever the user staged for any other file stays staged.
    /// Hooks, signing and the rest of the user's config run as they would
    /// in a terminal. Afterwards the real index takes the committed paths
    /// from the new HEAD, and only those, which is where `--only` leaves it.
    public func commit(
        _ selection: [(FileChange, FileSelection)], message: String, amend: Bool, hasHead: Bool,
        in repo: URL
    ) async throws {
        let index = FileManager.default.temporaryDirectory.appending(
            path: "upstream-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        if hasHead {
            // From a copy of the real index, so that unchanged entries keep
            // their stat data and the commit does not rehash every file.
            let real = try await run(
                ["rev-parse", "--path-format=absolute", "--git-path", "index"], in: repo
            )
            .text.trimmingCharacters(in: .newlines)
            try? FileManager.default.copyItem(atPath: real, toPath: index.path)
            try await run(["read-tree", "--reset", "HEAD"], in: repo, environment: env)
        } else {
            try await run(["read-tree", "--empty"], in: repo, environment: env)
        }

        var whole: [String] = []
        var committed: [String] = []
        for (change, chosen) in selection {
            switch chosen {
            case .nothing:
                continue
            case .all:
                whole += change.paths
            case .lines(let picked, let diff):
                let (args, allowed) = FileDiff.arguments(for: change, hasHead: hasHead)
                let now = FileDiff(parsing: try await run(args, in: repo, allowedExitCodes: allowed).stdout)
                guard now == diff else { throw CommitError.changedSinceChosen(path: change.path) }
                guard let patch = diff.patch(selecting: picked) else { continue }
                // nowarn: `apply.whitespace=fix` in the user's config would
                // otherwise change the lines they chose.
                try await run(
                    ["apply", "--cached", "--whitespace=nowarn", "-"], in: repo, input: patch,
                    environment: env)
            }
            committed += change.paths
        }
        if !whole.isEmpty {
            try await run(["--literal-pathspecs", "add", "--all", "--"] + whole, in: repo, environment: env)
        }
        try await run(
            ["commit", "--file=-"] + (amend ? ["--amend"] : []), in: repo, input: Data(message.utf8),
            environment: env)
        if !committed.isEmpty {
            try await run(["--literal-pathspecs", "reset", "-q", "--"] + committed, in: repo)
        }
    }
}
