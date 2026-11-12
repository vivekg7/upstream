import Foundation
import Observation

/// The app's state: the repositories the user added, the one selected, and
/// what its working tree looks like. Views read it; only it, and the feature
/// models it owns (`branches`, `history`, `forge`), run git.
@MainActor @Observable
public final class AppModel {
    public private(set) var repositories: [URL]
    public var selected: URL? {
        didSet {
            guard selected != oldValue else { return }
            countAsOpened()
            status = nil
            selectedFile = nil
            diff = nil
            error = nil
            operation = nil
            discardRequest = nil
            branches.repositoryChanged()
            history.repositoryChanged()
            forge.repositoryChanged()
            watch()
            Task { await refresh() }
        }
    }
    public private(set) var status: RepoStatus?
    public var selectedFile: FileChange.ID? {
        didSet { if selectedFile != oldValue { Task { await loadDiff() } } }
    }
    public private(set) var diff: FileDiff?
    /// Show the diff with `-w`. Lines cannot be checked in it, since it is
    /// not what would be committed (docs/plans/007_the_diff_view.md); the
    /// view keeps the setting and passes it here.
    public var hidesWhitespace = false {
        didSet {
            if hidesWhitespace != oldValue {
                Task { await loadDiff() }
                Task { await history.loadFileDiff() }
            }
        }
    }
    /// The last failure, shown above the window's content until dismissed or
    /// the next operation starts.
    public var error: String?
    public private(set) var isCommitting = false
    /// What is running for the user right now ("Pushing…"), shown in the
    /// toolbar; nil when nothing is.
    public private(set) var activity: String?
    /// The sidebar's tab: the working tree's changes, or the history.
    public var tab: Tab = .changes

    public enum Tab: Hashable, Sendable { case changes, history }

    /// The next commit of each repository as the user is shaping it. Kept
    /// when they switch to another repository and back: the message is
    /// their writing, and an unchecked file quietly checked again would be
    /// committed by surprise.
    var drafts: [URL: CommitDraft] = [:]

    // MARK: Changes state (AppModel+Changes.swift)

    /// The merge, rebase, cherry-pick or revert that has stopped in the
    /// selected repository, if any.
    public internal(set) var operation: RepoOperation?
    /// A discard waiting for the user to confirm it.
    public var discardRequest: DiscardRequest?
    /// Co-author suggestions for the selected repository, once asked for.
    public internal(set) var authorSuggestions: [String] = []
    /// Read once per repository, not on every refresh.
    var gitPaths: [URL: GitPaths] = [:]
    var templates: [URL: CommitDraft.Prefill] = [:]
    var recentAuthors: [URL: [String]] = [:]
    /// Where discarded content goes; tests put it somewhere harmless.
    var trash: Trash = moveToTrash

    public let git: Git?
    public let branches = BranchesModel()
    public let history = HistoryModel()
    public let forge = ForgeModel()
    public let library = LibraryModel()
    public let overview = OverviewModel()
    /// The repositories opened last, most recent first, for the sidebar's
    /// Recent section; the first is opened again at launch.
    public private(set) var recent: [URL]
    let defaults: UserDefaults
    private static let repositoriesKey = "repositories"
    private static let recentKey = "recentRepositories"
    static let recentCount = 3
    /// How long a repository must stay selected to count as opened, so
    /// walking down the sidebar with ↓ does not fill Recent with every
    /// repository passed on the way.
    var recentDwell: Duration = .seconds(1)
    private var recentTask: Task<Void, Never>?

    public init(git: Git? = Git.locate(), defaults: UserDefaults = .standard) {
        self.git = git
        self.defaults = defaults
        let repositories = (defaults.stringArray(forKey: Self.repositoriesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        self.repositories = repositories
        recent = (defaults.stringArray(forKey: Self.recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }.filter(repositories.contains)
        // The storage, not the property: under @Observable the property's
        // didSet would run here and read the status before the window asks
        // for it, which then read it a second time at every launch.
        _selected = recent.first ?? repositories.first
        for feature in [branches, history, forge, library, overview] as [any Feature] { feature.app = self }
        library.restore()
        overview.restore()
        watch()
        forge.repositoryChanged()  // which forge repository this is
        // The first status is read now, while the window is still being
        // built, rather than when it appears: 0.2 s sooner at launch.
        if selected != nil { Task { await refresh() } }
    }

    /// Whether HEAD points at a commit; false in a repository before its first.
    public var hasHead: Bool { status?.branch.oid != nil }

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
        recent.removeAll { $0 == url }
        drafts[url] = nil
        defaults.set(repositories.map(\.path), forKey: Self.repositoriesKey)
        defaults.set(recent.map(\.path), forKey: Self.recentKey)
        if selected == url { selected = repositories.first }
    }

    private func countAsOpened() {
        recentTask?.cancel()
        guard let url = selected else { return }
        recentTask = Task { [weak self, recentDwell] in
            try? await Task.sleep(for: recentDwell)
            guard let self, !Task.isCancelled, selected == url, repositories.contains(url) else { return }
            recent = Array(([url] + recent.filter { $0 != url }).prefix(Self.recentCount))
            defaults.set(recent.map(\.path), forKey: Self.recentKey)
        }
    }

    // MARK: Refreshing (docs/plans/004_refreshing_on_file_changes.md)

    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// How many times `git status` has run: what the watcher's filtering and
    /// the coalescing exist to keep low, so the tests count it.
    private(set) var statusReads = 0

    /// Reads the status again, and the shown diff. At most one runs at a
    /// time: a call while one is running asks for one more round after it
    /// and returns when that round is done, so a burst of calls costs two
    /// `git status` runs, not one each, and every caller still sees a status
    /// read after it asked.
    public func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                refreshAgain = false
                await refreshOnce()
            } while refreshAgain
            refreshTask = nil  // in the same step as the last check, so no call slips between
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce() async {
        guard let git, let repo = selected else { return }
        statusReads += 1
        do {
            let result = try await git.run(RepoStatus.arguments, in: repo)
            guard repo == selected else { return }  // the user moved on meanwhile
            let fresh = RepoStatus(parsing: result.stdout)
            await chooseDefaults(for: fresh, in: repo)
            await refreshChanges(in: repo)
            guard repo == selected else { return }
            let old = status
            if fresh != status { status = fresh }
            overview.selectedRead(repo, fresh)
            if let file = selectedFile, !fresh.files.contains(where: { $0.id == file }) {
                selectedFile = nil
            } else {
                await loadDiff()
            }
            if old?.branch != fresh.branch {
                history.headChanged()
                forge.headChanged()
            }
            if old?.branch != fresh.branch || old?.stashCount != fresh.stashCount { branches.statusChanged() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var watcher: Watcher?
    private var watchedRepo: URL?
    /// Whether the app is in front. In the background a change only marks
    /// the repository stale; it is read when the user comes back, so an app
    /// left open behind a build costs nothing.
    public private(set) var isActive = true
    private var stale = false
    /// No watcher could be set up, so coming to the front always refreshes.
    private var unwatched = false

    /// Called when the app becomes active or inactive.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active && (stale || unwatched) {
            stale = false
            Task { await refresh() }
        }
        branches.activeChanged(active)
        forge.activeChanged(active)
        overview.activeChanged(active)
    }

    /// Watches the selected repository's working tree and git directories.
    private func watch() {
        guard watchedRepo != selected else { return }
        watcher = nil
        watchedRepo = selected
        unwatched = false
        guard let git, let repo = selected else { return }
        Task { [weak self] in
            let dirs = try? await git.run(
                ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: repo
            ).text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            guard let self, repo == selected else { return }
            guard let dirs else {
                unwatched = true
                return
            }
            let filter = WatchFilter(workTree: repo, gitDirs: dirs)
            let roots = [repo.path] + filter.gitDirs.filter { !$0.hasPrefix(repo.path + "/") }
            watcher = Watcher(paths: roots) { [weak self] paths in
                Task { @MainActor in await self?.changed(paths, in: repo, filter) }
            }
            unwatched = watcher == nil
        }
    }

    /// FSEvents saw `paths` change (nil: anything may have).
    private func changed(_ paths: [String]?, in repo: URL, _ filter: WatchFilter) async {
        guard repo == selected, let git, await filter.worthReading(paths, git: git),
            repo == selected
        else { return }
        guard isActive else {
            stale = true
            return
        }
        await refresh()
    }

    // MARK: Running an operation

    /// Runs one user-visible operation in the selected repository: shows
    /// `activity` while it runs, puts a failure in `error`, and refreshes
    /// afterwards either way, since a failed git command can still have
    /// changed things. Returns whether it succeeded.
    @discardableResult
    public func perform(_ activity: String, _ body: (Git, URL) async throws -> Void) async -> Bool {
        guard let git, let repo = selected else { return false }
        error = nil
        self.activity = activity
        var failure: String?
        do {
            try await body(git, repo)
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
        self.activity = nil
        await refresh()
        if let failure { error = failure }
        return failure == nil
    }

    /// Extra arguments for a git command that talks to `remote` (a name or a
    /// URL): the signed-in forge's credential helper for its own host
    /// (docs/plans/002_forges_github_first.md). Empty when no forge answers.
    public func networkArguments(in repo: URL, remote: String) async -> [String] {
        await forge.credentialArguments(in: repo, remote: remote)
    }

    private func loadDiff() async {
        guard let git, let repo = selected, let status,
            let change = status.files.first(where: { $0.id == selectedFile })
        else {
            diff = nil
            return
        }
        let ignoring = hidesWhitespace
        let (args, allowed) = FileDiff.arguments(
            for: change, hasHead: status.branch.oid != nil, ignoringWhitespace: ignoring)
        do {
            let result = try await git.run(
                args, in: repo, allowedExitCodes: allowed, limit: FileDiff.byteCeiling)
            guard repo == selected, change.id == selectedFile, ignoring == hidesWhitespace else { return }
            let fresh =
                result.truncated
                ? FileDiff.tooLarge : FileDiff(parsing: result.stdout, ignoringWhitespace: ignoring)
            // Lines chosen in a diff that has since changed would point at
            // other lines. Uncheck the file rather than guess. A diff without
            // whitespace cannot be compared; the commit checks again anyway.
            if !ignoring, case .lines(_, let chosenIn) = selection(of: change), chosenIn != fresh {
                drafts[repo, default: CommitDraft()].selection[change.id] = FileSelection.nothing
            }
            if fresh != diff { diff = fresh }
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
        var both: [FileChange] = []
        for change in status.files where selection[change.id] == nil {
            if !anyStaged || (change.index != nil && change.worktree == nil) {
                selection[change.id] = .all
            } else if change.index == nil {
                selection[change.id] = .nothing
            } else {
                both.append(change)
            }
        }
        // Unchecked unless the staged lines can be told apart.
        let picked = await stagedLines(of: both, hasHead: status.branch.oid != nil, in: repo)
        for change in both { selection[change.id] = picked[change.id] ?? .nothing }
        drafts[repo, default: CommitDraft()].selection = selection
    }

    /// For files with both staged and unstaged changes: the staged lines,
    /// checked. Unchecked when they cannot be told apart, which keeps
    /// whatever is staged out of the commit and untouched. Three diffs in
    /// all, each over every such file, then cut per file: a terminal that
    /// staged five thousand files and edited them again costs three
    /// processes, not fifteen thousand. Each read stops at
    /// `FileDiff.byteCeiling`; a batch that reaches it is read again file by
    /// file, and a single file past it starts unchecked.
    private func stagedLines(of changes: [FileChange], hasHead: Bool, in repo: URL) async
        -> [FileChange.ID: FileSelection]
    {
        guard let git, !changes.isEmpty else { return [:] }
        // Before the first commit each file's diff is its own `--no-index`
        // run (FileDiff.arguments), which a batch cannot reproduce.
        guard hasHead else { return await stagedLinesOneByOne(changes, hasHead: false, in: repo) }
        let limit = FileDiff.byteCeiling
        let paths = changes.flatMap(\.paths)
        async let whole = try? git.run(
            FileDiff.base + ["--find-renames", "HEAD", "--"] + paths, in: repo, limit: limit)
        async let staged = try? git.run(
            FileDiff.base + ["--cached", "--find-renames", "--"] + paths, in: repo, limit: limit)
        async let unstaged = try? git.run(
            FileDiff.base + ["--"] + changes.map(\.path), in: repo, limit: limit)
        let (w, s, u) = await (whole, staged, unstaged)
        guard let w, let s, let u else { return [:] }
        if w.truncated || s.truncated || u.truncated {
            return await stagedLinesOneByOne(changes, hasHead: true, in: repo)
        }
        let (wholes, stageds, unstageds) = (
            FileDiff.sections(w.stdout), FileDiff.sections(s.stdout), FileDiff.sections(u.stdout)
        )
        var result: [FileChange.ID: FileSelection] = [:]
        for change in changes {
            // A rename git did not pair is two sections, which a file's own
            // diff shows as one diff of two files: committed whole.
            if let old = change.originalPath, wholes[old] != nil { continue }
            guard let w = wholes[change.path], let s = stageds[change.path], let u = unstageds[change.path]
            else { continue }
            result[change.id] = Self.picked(w, s, u)
        }
        return result
    }

    private func stagedLinesOneByOne(_ changes: [FileChange], hasHead: Bool, in repo: URL) async
        -> [FileChange.ID: FileSelection]
    {
        guard let git else { return [:] }
        var result: [FileChange.ID: FileSelection] = [:]
        let limit = FileDiff.byteCeiling
        for change in changes {
            let (args, allowed) = FileDiff.arguments(for: change, hasHead: hasHead)
            let (staged, unstaged) = FileDiff.indexArguments(for: change)
            guard let whole = try? await git.run(args, in: repo, allowedExitCodes: allowed, limit: limit),
                !whole.truncated,
                let s = try? await git.run(staged, in: repo, limit: limit), !s.truncated,
                let u = try? await git.run(unstaged, in: repo, limit: limit), !u.truncated
            else { continue }
            result[change.id] = Self.picked(whole.stdout, s.stdout, u.stdout)
        }
        return result
    }

    private static func picked(_ whole: Data, _ staged: Data, _ unstaged: Data) -> FileSelection {
        let diff = FileDiff(parsing: whole)
        guard diff.canSelectLines,
            let picked = diff.selection(
                staged: FileDiff(parsing: staged), unstaged: FileDiff(parsing: unstaged))
        else { return .nothing }
        return .picking(picked, in: diff)
    }

    public func setChecked(_ checked: Bool, _ change: FileChange) {
        draft.selection[change.id] = checked ? .all : FileSelection.nothing
    }

    /// Space on the selected files: checks them all, unless every one is
    /// checked already, then unchecks them. A partly checked file counts as
    /// unchecked, as a click on its box does; flipping each file on its own
    /// would leave a mixed selection mixed. Conflicted files are left out.
    public func toggleChecked(_ changes: [FileChange]) {
        let changes = changes.filter { !$0.conflicted }
        let check = !changes.allSatisfy { selection(of: $0) == .all }
        var d = draft
        for change in changes { d.selection[change.id] = check ? .all : .nothing }
        draft = d
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
        if let operation { return CommitError.operationInProgress(operation.kind).localizedDescription }
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
            let (summary, description) = CommitDraft.split(message: body)
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
                status.files.map { ($0, d.selection[$0.id] ?? .all) }, message: d.message,
                trailers: d.trailers,
                amend: d.amend, hasHead: status.branch.oid != nil, in: repo)
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
        await refresh()
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
    /// "Name <email>" each, credited with `Co-authored-by:` trailers.
    public var coAuthors: [String] = []
    /// The message the app put in the fields (commit.template, or MERGE_MSG
    /// during a merge), kept to tell whether the user has typed over it.
    var prefill: Prefill?

    struct Prefill: Equatable, Sendable {
        enum Source: Sendable { case template, merge }
        var source: Source
        var summary = ""
        var description = ""
    }

    public init() {}

    var message: String {
        let summary = summary.trimmingCharacters(in: .whitespaces)
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? summary : "\(summary)\n\n\(body)"
    }

    var trailers: [String] { coAuthors.map { "Co-authored-by: \($0)" } }

    /// "Name <email>" tidied, or nil when `text` is not one: the form a
    /// Co-authored-by trailer needs for a forge to credit the person.
    public static func coAuthor(_ text: String) -> String? {
        guard let m = text.wholeMatch(of: /\s*([^<>\n]*[^<>\s])\s*<([^<>\s@]+@[^<>\s@]+\.[^<>\s@]+)>\s*/)
        else { return nil }
        return "\(m.1) <\(m.2)>"
    }

    /// "Summary\n\nBody\n" → ("Summary", "Body").
    static func split(message: String) -> (String, String) {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let summary = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        return (summary, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
