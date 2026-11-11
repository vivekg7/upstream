import Foundation

/// A discard the user asked for, held until they confirm it.
public enum DiscardRequest: Sendable {
    case files([FileChange])
    /// Indices into the lines of the diff that was shown for the file.
    case lines(Set<Int>, of: FileChange, in: FileDiff)
}

// Discard, ignore, co-authors, the prefilled message and conflicts: the
// Changes tab beyond the checkbox commit
// (docs/plans/008_discard_ignore_and_conflicts.md).
extension AppModel {
    // MARK: Refreshing

    /// Runs with every refresh: what operation is in progress, and the
    /// message the fields start with. Cheap in the steady state: the git
    /// paths and the template are read once per repository, the operation
    /// is a few stats, and its names are looked up only when it changes.
    func refreshChanges(in repo: URL) async {
        guard let git else { return }
        if gitPaths[repo] == nil { gitPaths[repo] = try? await git.gitPaths(in: repo) }
        if templates[repo] == nil {
            let (summary, description) = await git.commitTemplate(in: repo)
            templates[repo] = CommitDraft.Prefill(
                source: .template, summary: summary, description: description)
        }
        guard repo == selected, let paths = gitPaths[repo] else { return }
        var detected = RepoOperation.detect(paths)
        if let found = detected {
            detected =
                found.isSame(as: operation) ? operation : await git.named(found, paths: paths, in: repo)
        }
        guard repo == selected else { return }
        if detected != operation { operation = detected }
        // An operation is finished with its own message, not the last
        // commit's, and Amend is hidden meanwhile.
        if operation != nil, draft.amend { await setAmend(false) }
        prefill(in: repo)
    }

    /// Puts commit.template's message in empty fields, or during a merge
    /// git's message for it, as GitHub Desktop does. Fields the user has
    /// typed in, or cleared, are never replaced; nor is anything while
    /// Amend shows the last commit's message.
    private func prefill(in repo: URL) {
        var d = drafts[repo, default: CommitDraft()]
        var wanted = templates[repo]
        if let operation, operation.kind == .merge {
            let (summary, description) = CommitDraft.split(message: operation.message)
            wanted = CommitDraft.Prefill(source: .merge, summary: summary, description: description)
        }
        guard let wanted, !d.amend, d.prefill?.source != wanted.source,
            d.summary == d.prefill?.summary ?? "", d.description == d.prefill?.description ?? ""
        else { return }
        (d.summary, d.description, d.prefill) = (wanted.summary, wanted.description, wanted)
        drafts[repo] = d
    }

    // MARK: Discard

    /// Asks to discard `changes`; the view confirms, naming them. Conflicted
    /// files are resolved instead, so they are left out. Nothing is
    /// discarded while an operation is in progress: discarding a file the
    /// merge brought in would quietly drop it from the merge, and Abort is
    /// the way to throw the operation away.
    public func requestDiscard(_ changes: [FileChange]) {
        let changes = changes.filter { !$0.conflicted }
        if !changes.isEmpty, operation == nil { discardRequest = .files(changes) }
    }

    /// Asks to discard some changed lines of the shown diff: `indices` into
    /// its lines, of which only the added and removed ones count.
    public func requestDiscardLines(_ indices: some Sequence<Int>) {
        guard let diff, diff.canSelectLines, let change = shownChange, !change.conflicted, operation == nil
        else {
            return
        }
        let lines = Set(indices).intersection(diff.changedLines)
        if !lines.isEmpty { discardRequest = .lines(lines, of: change, in: diff) }
    }

    private var shownChange: FileChange? { status?.files.first { $0.id == selectedFile } }

    /// Carries out a confirmed discard. The content goes to the Trash first.
    public func discard(_ request: DiscardRequest) async {
        discardRequest = nil
        let (trash, hasHead) = (trash, hasHead)
        switch request {
        case .files(let changes):
            await perform("Discarding changes…") { git, repo in
                try await git.discard(changes, hasHead: hasHead, in: repo, trash: trash)
            }
        case .lines(let lines, let change, let diff):
            await perform("Discarding lines…") { git, repo in
                try await git.discardLines(
                    lines, of: change, in: diff, hasHead: hasHead, in: repo, trash: trash)
            }
        }
    }

    // MARK: Ignore

    /// Adds an untracked file, or every file with its extension, to the
    /// top-level .gitignore.
    public func ignore(_ change: FileChange, allWithItsExtension: Bool) async {
        let pattern =
            allWithItsExtension
            ? Ignore.fileExtension(of: change.path).map(Ignore.pattern(forExtension:))
            : Ignore.pattern(forFile: change.path)
        guard let pattern else { return }
        await perform("Ignoring…") { _, repo in try Ignore.add(pattern, in: repo) }
    }

    // MARK: Co-authors

    /// Adds a co-author to the draft; false when `text` is not "Name <email>".
    @discardableResult
    public func addCoAuthor(_ text: String) -> Bool {
        guard let author = CommitDraft.coAuthor(text) else { return false }
        if !draft.coAuthors.contains(author) { draft.coAuthors.append(author) }
        return true
    }

    /// Reads the recent authors once per repository, when the co-author
    /// field is first shown.
    public func loadAuthorSuggestions() async {
        guard let git, let repo = selected else { return }
        if recentAuthors[repo] == nil { recentAuthors[repo] = await git.recentAuthors(in: repo) }
        if repo == selected { authorSuggestions = recentAuthors[repo] ?? [] }
    }

    // MARK: Conflicts

    /// Why Continue (or Commit Merge) is disabled, or nil when it is not.
    public var continueBlocker: String? {
        guard let operation, let status else { return "" }
        let left = status.files.count(where: \.conflicted)
        if left > 0 {
            return left == 1
                ? "Resolve the conflicted file first." : "Resolve the \(left) conflicted files first."
        }
        if operation.kind == .merge, draft.summary.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a summary."
        }
        return nil
    }

    /// Commits the merge, or continues the rebase, cherry-pick or revert,
    /// with what is staged.
    public func continueOperation() async {
        guard let operation, continueBlocker == nil else { return }
        let d = draft
        await perform(operation.kind == .merge ? "Committing the merge…" : "Continuing…") { git, repo in
            try await git.continueOperation(
                operation.kind, message: d.message, trailers: d.trailers, in: repo)
            if operation.kind == .merge {
                // As after any commit: only the unchecked files keep their state.
                var next = CommitDraft()
                next.selection = d.selection.filter { $0.value == .nothing }
                drafts[repo] = next
            }
        }
    }

    /// Aborts the operation; the view has asked first.
    public func abortOperation() async {
        guard let operation else { return }
        await perform("Aborting the \(operation.kind.command)…") { git, repo in
            try await git.abortOperation(operation.kind, in: repo)
        }
    }

    /// Resolves a conflicted file by taking one side's version.
    public func resolve(_ change: FileChange, taking side: ConflictSide) async {
        let trash = trash
        await perform("Resolving \(change.path)…") { git, repo in
            try await git.resolve(change.path, taking: side, in: repo, trash: trash)
        }
    }

    public func markResolved(_ change: FileChange) async {
        await perform("Marking \(change.path) resolved…") { git, repo in
            try await git.markResolved(change.path, in: repo)
        }
    }
}
