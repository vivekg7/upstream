import Foundation
import Observation

/// The app's state: the repositories the user added, the one selected, and
/// what its working tree looks like. Views read it; only it runs git.
@MainActor @Observable
public final class AppModel {
    public private(set) var repositories: [URL]
    public var selected: URL? {
        didSet {
            guard selected != oldValue else { return }
            status = nil
            selectedFile = nil
            Task { await refresh() }
        }
    }
    public private(set) var status: RepoStatus?
    public var selectedFile: FileChange.ID? {
        didSet { if selectedFile != oldValue { Task { await loadDiff() } } }
    }
    public private(set) var diff: FileDiff?
    public private(set) var error: String?
    public private(set) var isCommitting = false

    /// The next commit of each repository as the user is shaping it. Kept
    /// when they switch to another repository and back: the message is
    /// their writing, and an unchecked file quietly checked again would be
    /// committed by surprise.
    private var drafts: [URL: CommitDraft] = [:]

    public let git: Git?
    private let defaults: UserDefaults
    private static let repositoriesKey = "repositories"

    public init(git: Git? = Git.locate(), defaults: UserDefaults = .standard) {
        self.git = git
        self.defaults = defaults
        repositories = (defaults.stringArray(forKey: Self.repositoriesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        selected = repositories.first
    }

    /// Adds a folder that is inside a git working tree, by its top level,
    /// so a subfolder picked by mistake still opens the whole repository.
    public func add(_ folder: URL) async {
        guard let git else { return }
        do {
            let top = try await git.run(["rev-parse", "--show-toplevel"], in: folder).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: top)
            if !repositories.contains(url) {
                repositories.append(url)
                repositories.sort {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                defaults.set(repositories.map(\.path), forKey: Self.repositoriesKey)
            }
            selected = url
        } catch {
            self.error = "\(folder.lastPathComponent) is not a git repository."
        }
    }

    /// Takes a repository off the list. Its folder is left alone.
    public func remove(_ url: URL) {
        repositories.removeAll { $0 == url }
        drafts[url] = nil
        defaults.set(repositories.map(\.path), forKey: Self.repositoriesKey)
        if selected == url { selected = repositories.first }
    }

    public func refresh() async {
        guard let git, let repo = selected else { return }
        do {
            let result = try await git.run(RepoStatus.arguments, in: repo)
            guard repo == selected else { return }  // the user moved on meanwhile
            let fresh = RepoStatus(parsing: result.stdout)
            await chooseDefaults(for: fresh, in: repo)
            guard repo == selected else { return }
            if fresh != status { status = fresh }
            error = nil
            if let file = selectedFile, !fresh.files.contains(where: { $0.id == file }) {
                selectedFile = nil
            } else {
                await loadDiff()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard let git, let repo = selected, let status,
            let change = status.files.first(where: { $0.id == selectedFile })
        else {
            diff = nil
            return
        }
        let (args, allowed) = FileDiff.arguments(for: change, hasHead: status.branch.oid != nil)
        do {
            let result = try await git.run(args, in: repo, allowedExitCodes: allowed)
            guard repo == selected, change.id == selectedFile else { return }
            let fresh = FileDiff(parsing: result.stdout)
            // Lines chosen in a diff that has since changed would point at
            // other lines. Uncheck the file rather than guess.
            if case .lines(_, let chosenIn) = selection(of: change), chosenIn != fresh {
                drafts[repo, default: CommitDraft()].selection[change.id] = FileSelection.nothing
            }
            diff = fresh
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: The next commit

    /// The selected repository's draft; an empty one when none is selected.
    public var draft: CommitDraft {
        get { selected.flatMap { drafts[$0] } ?? CommitDraft() }
        set { if let selected { drafts[selected] = newValue } }
    }

    public func selection(of change: FileChange) -> FileSelection {
        draft.selection[change.id] ?? .all
    }

    /// A file seen for the first time starts checked, as in GitHub Desktop,
    /// unless something is already staged: then what was staged starts
    /// checked and nothing else, so a commit prepared in a terminal is the
    /// one the app offers. Files that are gone are forgotten.
    private func chooseDefaults(for status: RepoStatus, in repo: URL) async {
        var selection = drafts[repo]?.selection ?? [:]
        let present = Set(status.files.map(\.id))
        selection = selection.filter { present.contains($0.key) }
        let anyStaged = status.files.contains { $0.index != nil && !$0.conflicted }
        for change in status.files where selection[change.id] == nil {
            if !anyStaged || (change.index != nil && change.worktree == nil) {
                selection[change.id] = .all
            } else if change.index == nil {
                selection[change.id] = .nothing
            } else {
                selection[change.id] = await stagedLines(
                    of: change, hasHead: status.branch.oid != nil, in: repo)
            }
        }
        drafts[repo, default: CommitDraft()].selection = selection
    }

    /// For a file with both staged and unstaged changes: the staged lines,
    /// checked. Unchecked when they cannot be told apart, which keeps
    /// whatever is staged out of the commit and untouched.
    private func stagedLines(of change: FileChange, hasHead: Bool, in repo: URL) async -> FileSelection {
        guard let git else { return .nothing }
        let (args, allowed) = FileDiff.arguments(for: change, hasHead: hasHead)
        let (staged, unstaged) = FileDiff.indexArguments(for: change)
        guard let whole = try? await git.run(args, in: repo, allowedExitCodes: allowed),
            let stagedHalf = try? await git.run(staged, in: repo),
            let unstagedHalf = try? await git.run(unstaged, in: repo)
        else { return .nothing }
        let diff = FileDiff(parsing: whole.stdout)
        guard diff.canSelectLines,
            let picked = diff.selection(
                staged: FileDiff(parsing: stagedHalf.stdout), unstaged: FileDiff(parsing: unstagedHalf.stdout)
            )
        else { return .nothing }
        return .picking(picked, in: diff)
    }

    public func setChecked(_ checked: Bool, _ change: FileChange) {
        draft.selection[change.id] = checked ? .all : FileSelection.nothing
    }

    public func setAllChecked(_ checked: Bool) {
        // One write: each write through `draft` copies the whole selection.
        var d = draft
        for change in status?.files ?? [] where !change.conflicted {
            d.selection[change.id] = checked ? .all : .nothing
        }
        draft = d
    }

    /// Checks the given lines of the shown diff, or unchecks them if they
    /// are all checked already: one line, or a hunk from its header.
    public func toggleLines(_ indices: some Sequence<Int>) {
        guard let diff, diff.canSelectLines,
            let change = status?.files.first(where: { $0.id == selectedFile })
        else { return }
        let changed = Set(diff.changedLines)
        let targets = Set(indices).intersection(changed)
        var picked: Set<Int> =
            switch selection(of: change) {
            case .all: changed
            case .nothing: []
            case .lines(let picked, _): picked
            }
        if targets.isSubset(of: picked) { picked.subtract(targets) } else { picked.formUnion(targets) }
        draft.selection[change.id] = .picking(picked, in: diff)
    }

    /// Why the commit button is disabled, or nil when it is not.
    public var commitBlocker: String? {
        guard let status else { return "" }
        if status.files.contains(where: \.conflicted) { return "Resolve the conflicted files first." }
        if draft.summary.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a summary." }
        let anyChecked = status.files.contains { selection(of: $0) != .nothing }
        if !anyChecked && !draft.amend { return "Check the changes to commit." }
        return nil
    }

    /// Turning Amend on puts the last commit's message in the fields, as
    /// GitHub Desktop does; turning it off brings back what was typed before.
    public func setAmend(_ on: Bool) async {
        guard let git, let repo = selected, on != draft.amend else { return }
        var d = draft
        if on {
            guard
                let body = try? await git.run(
                    ["log", "-1", "--no-show-signature", "--format=%B", "HEAD"], in: repo
                ).text
            else { return }
            d.typed = (d.summary, d.description)
            let (summary, description) = Self.split(message: body)
            (d.summary, d.description) = (summary, description)
        } else if let typed = d.typed {
            (d.summary, d.description) = typed
            d.typed = nil
        }
        d.amend = on
        drafts[repo] = d
    }

    public func commit() async {
        guard let git, let repo = selected, let status, commitBlocker == nil else { return }
        let d = draft
        error = nil
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await git.commit(
                status.files.map { ($0, d.selection[$0.id] ?? .all) }, message: d.message, amend: d.amend,
                hasHead: status.branch.oid != nil, in: repo)
            // Only the unchecked files keep their state; whatever is left of
            // a committed file is a new change.
            var next = CommitDraft()
            next.selection = d.selection.filter { $0.value == .nothing }
            drafts[repo] = next
        } catch CommitError.changedSinceChosen(let path) {
            drafts[repo]?.selection[path] = FileSelection.nothing
            self.error = CommitError.changedSinceChosen(path: path).localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
        let failed = self.error
        await refresh()
        if let failed { self.error = failed }  // refresh clears it
    }

    /// "Summary\n\nBody\n" → ("Summary", "Body").
    static func split(message: String) -> (String, String) {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let summary = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        return (summary, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One repository's next commit: which changes, and its message.
public struct CommitDraft: Sendable {
    /// Every changed file the app has seen; any other counts as checked.
    public var selection: [FileChange.ID: FileSelection] = [:]
    public var summary = ""
    public var description = ""
    public internal(set) var amend = false  // through `AppModel.setAmend`, which swaps the message
    /// What was typed before Amend replaced it with the last commit's message.
    var typed: (String, String)?

    public init() {}

    var message: String {
        let summary = summary.trimmingCharacters(in: .whitespaces)
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? summary : "\(summary)\n\n\(body)"
    }
}
