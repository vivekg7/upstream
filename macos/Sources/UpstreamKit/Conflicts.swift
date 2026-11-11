import Foundation

// A merge, rebase, cherry-pick or revert that stopped, and resolving its
// conflicts (docs/plans/008_discard_ignore_and_conflicts.md).

/// The files in the git directory the app reads itself. `git rev-parse
/// --git-path` finds them, including a linked worktree's own, once per
/// repository; after that, telling whether an operation is in progress is a
/// few stats, with no git process on each refresh.
public struct GitPaths: Sendable, Equatable {
    let index, mergeHead, mergeMessage, cherryPickHead, revertHead, rebaseMerge, rebaseApply: URL

    static let names = [
        "index", "MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
    ]
}

/// What is in progress, as git records it in the git directory.
public struct RepoOperation: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case merge, rebase, cherryPick = "cherry-pick", revert

        /// The git command that started it, and that continues or aborts it.
        public var command: String { rawValue }
        public var title: String {
            switch self {
            case .merge: "Merge"
            case .rebase: "Rebase"
            case .cherryPick: "Cherry-Pick"
            case .revert: "Revert"
            }
        }
    }

    public var kind: Kind
    /// The commit being merged, picked or reverted; for a rebase, the one it
    /// replays onto.
    public var head: String
    /// For a rebase, the branch being rebased; nil when it began detached.
    public var branch: String?
    /// What `head` is called: a branch, or a commit as "abc1234 Its subject".
    public var name: String
    /// During a merge, the message git prepared (MERGE_MSG), comments stripped.
    public var message = ""

    /// Reads what is in progress from the files git keeps for it. No git
    /// process: a few stats and two small reads, so it runs on every
    /// refresh. `name` is the abbreviated head until `Git.named` looks it up.
    static func detect(_ paths: GitPaths) -> RepoOperation? {
        func read(_ url: URL) -> String? {
            (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first.map(String.init)
        }
        // A rebase first: it can leave MERGE_MSG and the like behind it. Only
        // a rebase writes `onto`; `git am` uses rebase-apply/ too.
        for dir in [paths.rebaseMerge, paths.rebaseApply] {
            guard let onto = read(dir.appending(path: "onto")) else { continue }
            let head = read(dir.appending(path: "head-name")) ?? ""
            let branch = head.hasPrefix("refs/heads/") ? String(head.dropFirst("refs/heads/".count)) : nil
            return RepoOperation(kind: .rebase, head: onto, branch: branch, name: String(onto.prefix(7)))
        }
        let heads: [(Kind, URL)] = [
            (.merge, paths.mergeHead), (.cherryPick, paths.cherryPickHead), (.revert, paths.revertHead),
        ]
        for (kind, url) in heads {
            if let head = read(url) {
                return RepoOperation(kind: kind, head: head, name: String(head.prefix(7)))
            }
        }
        return nil
    }

    /// The same operation at the same commit: its names need no new lookup.
    func isSame(as other: RepoOperation?) -> Bool {
        kind == other?.kind && head == other?.head && branch == other?.branch
    }

    /// "Merging feature into main", for the banner.
    public func title(currentBranch: String?) -> String {
        switch kind {
        case .merge: "Merging \(name) into \(currentBranch ?? "HEAD")"
        case .rebase: "Rebasing \(branch ?? "detached HEAD") onto \(name)"
        case .cherryPick: "Cherry-picking \(name)"
        case .revert: "Reverting \(name)"
        }
    }

    /// Whose version `side` is, in the user's terms. During a rebase git's
    /// "ours" is the branch being rebased onto and "theirs" the commit being
    /// replayed, the reverse of what the words suggest, so the app names
    /// branches rather than saying ours and theirs.
    public func label(_ side: ConflictSide, currentBranch: String?) -> String {
        switch (kind, side) {
        case (.rebase, .ours): name
        case (.rebase, .theirs): branch ?? "the rebased commit"
        case (_, .ours): currentBranch ?? "HEAD"
        case (.revert, .theirs): "the revert"
        case (_, .theirs): name
        }
    }

    /// What Abort throws away, for its confirmation.
    public func abortWarning(currentBranch: String?) -> String {
        let back = "goes back to where it was before the \(kind.command)"
        return switch kind {
        case .merge:
            "\(currentBranch ?? "HEAD") \(back). The merged changes and your conflict resolutions are thrown away."
        case .rebase:
            "\(branch ?? "HEAD") \(back). The commits already replayed and your conflict resolutions are thrown away."
        case .cherryPick, .revert:
            "\(currentBranch ?? "HEAD") \(back). Its changes and your conflict resolutions are thrown away."
        }
    }

    /// Whether a file still has conflict markers: a line that starts with
    /// seven `<` or `>` and then ends or has a space. `=======` alone is not
    /// counted, since a Markdown heading underline looks the same.
    public static func hasConflictMarkers(_ data: Data) -> Bool {
        data.split(separator: UInt8(ascii: "\n")).contains { line in
            let head = Array(line.prefix(8))
            guard head.count >= 7, head[0] == UInt8(ascii: "<") || head[0] == UInt8(ascii: ">") else {
                return false
            }
            return head.prefix(7).allSatisfy { $0 == head[0] }
                && (head.count == 7 || head[7] == UInt8(ascii: " ") || head[7] == UInt8(ascii: "\r"))
        }
    }
}

/// One side of a conflict, as git's `--ours` and `--theirs` mean it.
public enum ConflictSide: Sendable { case ours, theirs }

public enum ConflictError: Error, LocalizedError, Equatable {
    case markersRemain(path: String)

    public var errorDescription: String? {
        switch self {
        case .markersRemain(let path):
            "“\(path)” still has conflict markers (<<<<<<<). Edit them out, or use one side's version."
        }
    }
}

extension Git {
    func gitPaths(in repo: URL) async throws -> GitPaths {
        let p = try await run(
            ["rev-parse", "--path-format=absolute"] + GitPaths.names.flatMap { ["--git-path", $0] }, in: repo
        ).text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        guard p.count == GitPaths.names.count else {
            throw GitError(arguments: ["rev-parse"], status: 0, message: "Could not find the git directory.")
        }
        return GitPaths(
            index: p[0], mergeHead: p[1], mergeMessage: p[2], cherryPickHead: p[3], revertHead: p[4],
            rebaseMerge: p[5], rebaseApply: p[6])
    }

    /// Fills in what a detected operation's commit is called, and a merge's
    /// message. Run only when the operation or its commit changes.
    func named(_ operation: RepoOperation, paths: GitPaths, in repo: URL) async -> RepoOperation {
        var op = operation
        switch op.kind {
        case .merge, .rebase:
            // refs/heads sorts first, so a local branch wins over its remote.
            let refs = try? await run(
                [
                    "for-each-ref", "--points-at=\(op.head)", "--format=%(refname:short)", "refs/heads",
                    "refs/remotes",
                    "refs/tags",
                ], in: repo)
            if let first = refs?.text.split(separator: "\n").first { op.name = String(first) }
        case .cherryPick, .revert:
            let line = try? await run(
                ["log", "-1", "--no-show-signature", "--format=%h %s", op.head], in: repo)
            if let line = line?.text.trimmingCharacters(in: .newlines), !line.isEmpty { op.name = line }
        }
        if op.kind == .merge, let data = try? Data(contentsOf: paths.mergeMessage),
            let text = try? await run(["stripspace", "--strip-comments"], in: repo, input: data).text
        {
            op.message = text  // git's own stripping, which knows core.commentChar
        }
        return op
    }

    /// Resolves a conflicted file with one side's version (`checkout --ours`
    /// or `--theirs`, then `add`). When that side deleted the file, taking it
    /// means deleting it (`rm`). Whatever is in the working tree, possibly a
    /// resolution by hand, is kept in the Trash first.
    public func resolve(_ path: String, taking side: ConflictSide, in repo: URL, trash: Trash) async throws {
        // "<mode> <object> <stage>\t<path>" per stage present: 2 is ours, 3 theirs.
        let stages = try await run(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path], in: repo)
            .stdout
            .split(separator: 0).compactMap { record in
                record.split(separator: UInt8(ascii: "\t")).first?.split(separator: UInt8(ascii: " ")).last
                    .flatMap { Int(String(decoding: $0, as: UTF8.self)) }
            }
        try keepInTrash([path], of: repo, trash: trash)
        if stages.contains(side == .ours ? 2 : 3) {
            try await run(
                ["--literal-pathspecs", "checkout", side == .ours ? "--ours" : "--theirs", "--", path],
                in: repo)
            try await run(["--literal-pathspecs", "add", "--", path], in: repo)
        } else {
            try await run(["--literal-pathspecs", "rm", "-q", "--force", "--", path], in: repo)
        }
    }

    /// Marks a file resolved as it is in the working tree (`add`, which also
    /// records a deletion), refusing while conflict markers remain in it.
    public func markResolved(_ path: String, in repo: URL) async throws {
        if let data = try? Data(contentsOf: repo.appending(path: path)),
            RepoOperation.hasConflictMarkers(data)
        {
            throw ConflictError.markersRemain(path: path)
        }
        try await run(["--literal-pathspecs", "add", "--all", "--", path], in: repo)
    }

    /// Finishes the operation with what is staged. A merge is committed with
    /// the message the user saw and may have edited (MERGE_MSG to begin
    /// with); the others continue with git's own message, the original
    /// commit's, and no editor opens.
    public func continueOperation(
        _ kind: RepoOperation.Kind, message: String, trailers: [String] = [], in repo: URL
    ) async throws {
        if kind == .merge {
            try await run(
                ["commit", "--file=-"] + trailers.flatMap { ["--trailer", $0] }, in: repo,
                input: Data(message.utf8))
        } else {
            try await run([kind.command, "--continue"], in: repo, environment: ["GIT_EDITOR": "true"])
        }
    }

    public func abortOperation(_ kind: RepoOperation.Kind, in repo: URL) async throws {
        try await run([kind.command, "--abort"], in: repo)
    }
}
