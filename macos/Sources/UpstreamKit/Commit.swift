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
    /// A merge, rebase, cherry-pick or revert has stopped. A commit built
    /// from HEAD in a temporary index would drop the merge's second parent
    /// or the files it brought in; the operation is finished instead.
    case operationInProgress(RepoOperation.Kind)

    public var errorDescription: String? {
        switch self {
        case .changedSinceChosen(let path):
            "“\(path)” changed after its lines were chosen. Choose them again, then commit."
        case .operationInProgress(let kind):
            "A \(kind.command) is in progress. Continue or abort it first."
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
    /// `trailers` ("Co-authored-by: Name <email>") go through `--trailer`,
    /// so git formats them, below the message, as it would in a terminal.
    public func commit(
        _ selection: [(FileChange, FileSelection)], message: String, trailers: [String] = [], amend: Bool,
        hasHead: Bool, in repo: URL
    ) async throws {
        let paths = try await gitPaths(in: repo)
        if let operation = RepoOperation.detect(paths) {
            throw CommitError.operationInProgress(operation.kind)
        }
        let index = FileManager.default.temporaryDirectory.appending(
            path: "upstream-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        if hasHead {
            // From a copy of the real index, so that unchanged entries keep
            // their stat data and the commit does not rehash every file.
            try? FileManager.default.copyItem(at: paths.index, to: index)
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
            ["commit", "--file=-"] + trailers.flatMap { ["--trailer", $0] } + (amend ? ["--amend"] : []),
            in: repo, input: Data(message.utf8), environment: env)
        if !committed.isEmpty {
            try await run(["--literal-pathspecs", "reset", "-q", "--"] + committed, in: repo)
        }
    }
}

extension Git {
    /// The message `commit.template` names, as (summary, description), with
    /// its comment lines stripped by git itself (`stripspace`, which knows
    /// `core.commentChar`). A relative path is taken from the top level.
    /// Empty when none is set or the file cannot be read.
    func commitTemplate(in repo: URL) async -> (String, String) {
        guard
            let path = try? await run(["config", "--path", "commit.template"], in: repo).text
                .trimmingCharacters(in: .newlines), !path.isEmpty,
            let data = try? Data(
                contentsOf: path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appending(path: path)),
            let text = try? await run(["stripspace", "--strip-comments"], in: repo, input: data).text
        else { return ("", "") }
        return CommitDraft.split(message: text)
    }

    /// Who wrote the last 500 commits, as "Name <email>", most recent first:
    /// the co-author suggestions. Empty before the first commit.
    func recentAuthors(in repo: URL) async -> [String] {
        let log = try? await run(
            ["log", "-n", "500", "--no-show-signature", "--format=%an%x00%ae"], in: repo)
        var seen = Set<String>()
        return (log?.text.split(separator: "\n") ?? []).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let author = "\(parts[0]) <\(parts[1])>"
            return seen.insert(author).inserted ? author : nil
        }
    }
}
