import Foundation
import Observation

/// The selected repository's history, paged, and what can be done with a
/// commit in it (docs/plans/006_history.md).
@MainActor @Observable
public final class HistoryModel: Feature {
    public weak var app: AppModel?

    /// The commits shown, newest first: the current branch's, or one side
    /// of a comparison.
    public private(set) var commits: [Commit] = []
    /// Whether every commit has been read.
    public private(set) var atEnd = false
    /// Branches and tags by the commit they point at.
    public private(set) var labels: [String: [RefLabel]] = [:]
    /// The local and remote branches, for "Compare…".
    public private(set) var branches: [RefLabel] = []
    /// The commits of HEAD that its upstream does not have: not pushed yet.
    public private(set) var unpushed: Set<String> = []
    /// Whether the repository has any remote-tracking branch at all.
    private var hasRemotes = false
    /// Whether the forge has a web page for this repository's commits.
    public private(set) var canOpenOnForge = false

    /// Another branch (a full refname) to compare HEAD with, as GitHub
    /// Desktop's compare does; nil shows the current branch's history.
    public var compare: String? {
        didSet { if compare != oldValue { Task { await reload() } } }
    }
    public var compareSide = CompareSide.behind {
        didSet { if compareSide != oldValue { Task { await reload() } } }
    }
    /// How many commits HEAD lacks, and has, relative to `compare`.
    public private(set) var compareCounts: (behind: Int, ahead: Int)?

    public enum CompareSide: Hashable, Sendable {
        /// The other branch's commits HEAD does not have (`HEAD..other`).
        case behind
        /// HEAD's commits the other branch does not have (`other..HEAD`).
        case ahead
    }

    public var selection: Commit.ID? {
        didSet { if selection != oldValue { Task { await loadDetail() } } }
    }
    public private(set) var detail: CommitDetail?
    public private(set) var files: [CommitFile] = []
    public var selectedFile: CommitFile.ID? {
        didSet { if selectedFile != oldValue { Task { await loadFileDiff() } } }
    }
    public private(set) var fileDiff: FileDiff?

    /// Commits per page. The first page costs about 15 ms on a 100,000-commit
    /// branch; the list asks for the next when its end comes into view.
    var pageSize = 200

    /// Commits already listed, and the parents of listed commits that are
    /// not: where the next page starts.
    private var seen: Set<String> = []
    private var frontier: [String] = []
    private var loadingPage = false
    /// Bumped whenever what is shown is replaced, so a slow read for the
    /// old state is dropped instead of landing on the new one.
    private var generation = 0
    /// Whether anyone has looked at the history. Until then, nothing is read:
    /// most visits to a repository never open the tab.
    private var wanted = false

    nonisolated init() {}

    /// The selected repository changed: forget the old one's history.
    func repositoryChanged() {
        generation += 1
        commits = []
        atEnd = false
        labels = [:]
        branches = []
        unpushed = []
        hasRemotes = false
        canOpenOnForge = false
        compare = nil
        compareCounts = nil
        seen = []
        frontier = []
        selection = nil
        detail = nil
        files = []
        selectedFile = nil
        fileDiff = nil
    }

    /// HEAD, the branch or its upstream moved: the first page may be stale.
    func headChanged() {
        if wanted { Task { await reload() } }
    }

    /// The History tab is on screen: read the first page if nothing is shown.
    public func load() async {
        wanted = true
        if commits.isEmpty && !atEnd { await reload() }
    }

    // MARK: Reading

    /// What the list shows, as revisions to walk from and to stop at.
    private var range: (include: [String], exclude: [String]) {
        guard let compare else { return (["HEAD"], []) }
        return compareSide == .behind ? ([compare], ["HEAD"]) : (["HEAD"], [compare])
    }

    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false

    /// Reads the first page again, with the labels and the unpushed marks,
    /// and replaces what is shown in one step, so the list never blinks
    /// empty. Later pages are read again as they come into view. As with
    /// `AppModel.refresh`, a call while one runs asks for one more round
    /// and returns after it: an action and the refresh it causes both
    /// reload, and the caller must see the later one.
    func reload() async {
        if let running = reloadTask {
            reloadAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                reloadAgain = false
                await reloadOnce()
            } while reloadAgain
            reloadTask = nil
        }
        reloadTask = task
        await task.value
    }

    private func reloadOnce() async {
        guard let app, let git = app.git, let repo = app.selected, let status = app.status else { return }
        generation += 1
        let token = generation
        guard status.branch.oid != nil else {
            // Unborn: nothing to list, no branch to compare with.
            (commits, atEnd, labels, branches, unpushed, frontier, seen) = ([], true, [:], [], [], [], [])
            selection = nil
            return
        }
        let (include, exclude) = range
        async let firstPage = git.log(from: include, excluding: exclude, count: pageSize, in: repo)
        async let refs = git.run(RefLabel.arguments, in: repo)
        async let counts = compareCounts(in: repo)
        async let forgeURL = app.forge.webURL(commit: status.branch.oid ?? "")
        do {
            let parsed = RefLabel.parse(try await refs.stdout)
            if let compare, !parsed.branches.contains(where: { $0.ref == compare }) {
                // Deleted meanwhile: back to the branch's own history.
                guard token == generation else { return }
                self.compare = nil
                return
            }
            let marks = await unpushedCommits(status.branch, hasRemotes: parsed.hasRemotes, in: repo)
            let page = try await firstPage
            let newCounts = await counts
            let forge = await forgeURL != nil
            guard token == generation else { return }
            labels = parsed.labels
            branches = parsed.branches.filter { $0.ref != "refs/heads/\(status.branch.head ?? "")" }
            unpushed = marks
            hasRemotes = parsed.hasRemotes
            compareCounts = newCounts
            canOpenOnForge = forge
            (seen, frontier, commits) = ([], [], [])
            append(page)
            if let selection, !seen.contains(selection) { self.selection = nil }
        } catch {
            guard token == generation else { return }
            app.error = error.localizedDescription
        }
    }

    /// Reads the next page, when the end of the list comes into view.
    public func loadMore() async {
        guard let app, let git = app.git, let repo = app.selected, !atEnd, !loadingPage else { return }
        loadingPage = true
        defer { loadingPage = false }
        let token = generation
        do {
            let page = try await git.log(from: frontier, excluding: range.exclude, count: pageSize, in: repo)
            guard token == generation else { return }
            append(page)
        } catch {
            guard token == generation else { return }
            app.error = error.localizedDescription
        }
    }

    /// Adds a page and moves the frontier past it. A page walked from the
    /// frontier is exactly what one longer `git log` would have printed
    /// next, except that a commit dated before its parent (clock skew) can
    /// come round twice; it is listed once.
    private func append(_ page: [Commit]) {
        let new = page.filter { seen.insert($0.id).inserted }
        commits += new
        var next = Set<String>()
        frontier = (frontier + new.flatMap(\.parents)).filter {
            !seen.contains($0) && next.insert($0).inserted
        }
        // An empty page with a frontier left: the rest is all excluded (compare).
        atEnd = new.isEmpty || frontier.isEmpty
    }

    /// GitHub Desktop's marks: commits not on the upstream, or, for a branch
    /// with none, not on any remote. A repository with no remote at all
    /// has nowhere to push to, and marking every commit would say nothing.
    private func unpushedCommits(_ branch: BranchInfo, hasRemotes: Bool, in repo: URL) async -> Set<String> {
        guard let git = app?.git else { return [] }
        let args: [String]
        if branch.head != nil, branch.upstream != nil {
            guard branch.ahead > 0 else { return [] }
            args = ["rev-list", "@{upstream}..HEAD"]
        } else if hasRemotes {
            args = ["rev-list", "HEAD", "--not", "--remotes"]
        } else {
            return []
        }
        let out = (try? await git.run(args, in: repo).text) ?? ""
        return Set(out.split(separator: "\n").map(String.init))
    }

    private func compareCounts(in repo: URL) async -> (behind: Int, ahead: Int)? {
        guard let compare, let git = app?.git,
            let out = try? await git.run(
                ["rev-list", "--left-right", "--count", "HEAD...\(compare)"], in: repo)
        else { return nil }
        let n = out.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return n.count == 2 ? (behind: n[1], ahead: n[0]) : nil
    }

    private func loadDetail() async {
        guard let app, let git = app.git, let repo = app.selected, let sha = selection else {
            (detail, files, selectedFile, fileDiff) = (nil, [], nil, nil)
            return
        }
        do {
            let d = try await git.commitDetail(sha, in: repo)
            let f = try await git.files(of: d, in: repo)
            guard sha == selection, repo == app.selected else { return }
            (detail, files) = (d, f)
            // As GitHub Desktop: the first file's diff, so there is something to read.
            if selectedFile == f.first?.id { await loadFileDiff() } else { selectedFile = f.first?.id }
        } catch {
            guard sha == selection else { return }
            app.error = error.localizedDescription
        }
    }

    func loadFileDiff() async {
        guard let app, let git = app.git, let repo = app.selected, let detail,
            let file = files.first(where: { $0.id == selectedFile })
        else {
            fileDiff = nil
            return
        }
        do {
            let ignoring = app.hidesWhitespace
            let diff = try await git.diff(of: file, in: detail, in: repo, ignoringWhitespace: ignoring)
            guard detail == self.detail, file.id == selectedFile, ignoring == app.hidesWhitespace else {
                return
            }
            fileDiff = diff
        } catch {
            app.error = error.localizedDescription
        }
    }

    // MARK: Actions

    /// Whether the listed commits are on the current branch, rather than
    /// only on the branch it is compared with. Reset needs the one;
    /// cherry-pick the other, since picking a commit HEAD has is empty.
    public var listedOnHead: Bool { compare == nil || compareSide == .ahead }

    /// The newest commit, when it can be undone: HEAD, not pushed, and
    /// neither a merge (undoing one would drop the merge silently) nor the
    /// first commit of a detached HEAD (there is no branch to empty).
    public var undoable: Commit? {
        guard compare == nil, let head = commits.first, head.id == app?.status?.branch.oid,
            !head.isMerge, !(head.parents.isEmpty && app?.status?.branch.head == nil)
        else { return nil }
        // With no remote at all, nothing has been pushed.
        return unpushed.contains(head.id) || !hasRemotes ? head : nil
    }

    /// Creates a branch at `commit` and switches to it, as GitHub Desktop's
    /// "Create branch from commit" does. Changes in the working tree come
    /// along, unless they conflict, in which case git refuses and says so.
    @discardableResult
    public func createBranch(_ name: String, at commit: Commit) async -> Bool {
        await run("Creating \(name)…") { git, repo in
            // --branch also expands "@{-1}" and the like; only a plain name will do.
            let checked = try await git.run(["check-ref-format", "--branch", name], in: repo).text
            guard checked.trimmingCharacters(in: .newlines) == name else { throw HistoryError.badName(name) }
            try await git.run(["switch", "-c", name, commit.id], in: repo)
        }
    }

    /// A lightweight tag, as GitHub Desktop makes. `tag.gpgSign` is turned
    /// off for it: a signature needs a tag object, which a lightweight tag
    /// is not, and with it on git would open an editor nobody can see.
    @discardableResult
    public func createTag(_ name: String, at commit: Commit) async -> Bool {
        await run("Creating tag \(name)…") { git, repo in
            let valid = try await git.run(
                ["check-ref-format", "refs/tags/\(name)"], in: repo, allowedExitCodes: [0, 1])
            guard valid.status == 0, !name.hasPrefix("-") else { throw HistoryError.badName(name) }
            try await git.run(["-c", "tag.gpgSign=false", "tag", name, commit.id], in: repo)
        }
    }

    /// Applies `commit` onto HEAD. A merge is picked against its first
    /// parent. A conflict leaves the repository mid-cherry-pick, as git does.
    @discardableResult
    public func cherryPick(_ commit: Commit) async -> Bool {
        await run("Cherry-picking \(commit.shortID)…") { git, repo in
            try await git.run(["cherry-pick"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.id], in: repo)
        }
    }

    /// A new commit that undoes `commit`; a merge is reverted against its
    /// first parent, as GitHub Desktop does.
    @discardableResult
    public func revert(_ commit: Commit) async -> Bool {
        await run("Reverting \(commit.shortID)…") { git, repo in
            try await git.run(
                ["revert", "--no-edit"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.id], in: repo)
        }
    }

    /// Moves the branch back to `commit`. The commits after it leave the
    /// branch, but their changes stay in the working tree (`--mixed`, as
    /// GitHub Desktop does; never `--hard`).
    @discardableResult
    public func reset(to commit: Commit) async -> Bool {
        await run("Resetting to \(commit.shortID)…") { git, repo in
            try await git.run(["reset", "--mixed", "-q", commit.id], in: repo)
        }
    }

    /// Takes the last commit off the branch and puts its changes back,
    /// staged, and its message back in the commit fields, as GitHub
    /// Desktop's Undo does. A message the user has started typing is kept
    /// instead; the undone one is still in `git reflog`.
    @discardableResult
    public func undo() async -> Bool {
        guard let head = undoable else { return false }
        return await run("Undoing \(head.shortID)…") { git, repo in
            let message = try await git.run(
                ["log", "-1", "--no-show-signature", "--format=%B", head.id], in: repo
            ).text
            if let parent = head.parents.first {
                try await git.run(["reset", "--soft", parent], in: repo)
            } else {
                // The first commit: the branch goes back to unborn, its files staged.
                try await git.run(["update-ref", "-d", "HEAD", head.id], in: repo)
            }
            guard let app, app.draft.summary.isEmpty, app.draft.description.isEmpty else { return }
            (app.draft.summary, app.draft.description) = CommitDraft.split(message: message)
        }
    }

    /// Runs `body` as a user operation, then reads the history again: a
    /// new tag moves no branch, so no refresh would show it otherwise.
    private func run(_ activity: String, _ body: (Git, URL) async throws -> Void) async -> Bool {
        guard let app else { return false }
        let ok = await app.perform(activity, body)
        await reload()
        return ok
    }
}

public enum HistoryError: Error, LocalizedError, Equatable {
    case badName(String)

    public var errorDescription: String? {
        switch self {
        case .badName(let name): "“\(name)” is not a valid name."
        }
    }
}

/// One commit as the history list shows it.
public struct Commit: Sendable, Equatable, Identifiable {
    /// The full object name.
    public var id: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var subject: String

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    /// Fields end in %x1f, records in NUL (`-z`). The subject is the one
    /// field of free text and comes last, so a stray 0x1f in it stays in
    /// it. %aN and %aE apply the mailmap, as `git log` in a terminal does.
    static let format = "--format=%H%x1f%P%x1f%aN%x1f%aE%x1f%at%x1f%s"

    static func parse(log data: Data) -> [Commit] {
        data.split(separator: 0).compactMap { record in
            let f = record.split(separator: 0x1f, maxSplits: 5, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard f.count == 6, let time = TimeInterval(f[4]) else { return nil }
            return Commit(
                id: f[0], parents: f[1].split(separator: " ").map(String.init), authorName: f[2],
                authorEmail: f[3], date: Date(timeIntervalSince1970: time), subject: f[5])
        }
    }
}

/// The selected commit in full: the message is read for it alone, never
/// for the list.
public struct CommitDetail: Sendable, Equatable {
    public var id: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var committerName: String
    public var committerEmail: String
    public var committerDate: Date
    public var message: String

    /// A commit message cannot hold NUL, so NUL separates the fields.
    static let format = "--format=%H%x00%P%x00%aN%x00%aE%x00%at%x00%cN%x00%cE%x00%ct%x00%B"

    init?(parsing data: Data) {
        let f = data.split(separator: 0, maxSplits: 8, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard f.count == 9, let at = TimeInterval(f[4]), let ct = TimeInterval(f[7]) else { return nil }
        (id, parents) = (f[0], f[1].split(separator: " ").map(String.init))
        (authorName, authorEmail, authorDate) = (f[2], f[3], Date(timeIntervalSince1970: at))
        (committerName, committerEmail, committerDate) = (f[5], f[6], Date(timeIntervalSince1970: ct))
        message = f[8].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As a list row, for the actions on it: a parent followed from the
    /// header may not be in the pages read so far.
    public var commit: Commit {
        Commit(
            id: id, parents: parents, authorName: authorName, authorEmail: authorEmail, date: authorDate,
            subject: String(message.prefix { $0 != "\n" }))
    }
}

/// A file a commit changed.
public struct CommitFile: Sendable, Equatable, Identifiable {
    public var kind: ChangeKind
    public var path: String
    /// Where a renamed or copied file came from.
    public var originalPath: String?

    public var id: String { path }
    public var paths: [String] { [originalPath, path].compactMap { $0 } }

    /// `diff-tree --name-status -z`: a status, then one path, or two for a
    /// rename or copy ("R100", old, new), each ending in NUL.
    static func parse(_ data: Data) -> [CommitFile] {
        var fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }[...]
        var files: [CommitFile] = []
        while let status = fields.popFirst(), let first = fields.popFirst() {
            let kind = status.first.flatMap(ChangeKind.init) ?? .modified
            if kind == .renamed || kind == .copied, let second = fields.popFirst() {
                files.append(CommitFile(kind: kind, path: second, originalPath: first))
            } else {
                files.append(CommitFile(kind: kind, path: first))
            }
        }
        return files
    }
}

/// A branch or tag name shown on the commit it points at.
public struct RefLabel: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable { case branch, remote, tag }

    public var kind: Kind
    /// The full refname: `refs/heads/main`.
    public var ref: String

    public var id: String { ref }
    /// As the user knows it: `main`, `origin/main`, `v1.0`.
    public var name: String {
        String(ref.dropFirst(kind == .branch ? 11 : kind == .remote ? 13 : 10))
    }

    /// One call for every label: an annotated tag's own object is not a
    /// commit, so `%(*objectname)`, the commit it points at, wins when set.
    static let arguments = [
        "for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)", "refs/heads", "refs/remotes",
        "refs/tags",
    ]

    static func parse(_ data: Data) -> (labels: [String: [RefLabel]], branches: [RefLabel], hasRemotes: Bool)
    {
        var labels: [String: [RefLabel]] = [:]
        var branches: [RefLabel] = []
        var hasRemotes = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let f = line.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard f.count == 3 else { continue }
            let ref = f[2]
            let kind: Kind
            if ref.hasPrefix("refs/heads/") {
                kind = .branch
            } else if ref.hasPrefix("refs/remotes/") {
                hasRemotes = true
                if ref.hasSuffix("/HEAD") { continue }  // origin/HEAD only names the default branch
                kind = .remote
            } else {
                kind = .tag
            }
            let label = RefLabel(kind: kind, ref: ref)
            labels[f[1].isEmpty ? f[0] : f[1], default: []].append(label)
            if kind != .tag { branches.append(label) }
        }
        return (labels, branches, hasRemotes)
    }
}

extension Git {
    /// Up to `count` commits reachable from `starts` and not from
    /// `excluding`, newest first, in git's default order. Never
    /// `--topo-order` or `--graph`: both walk the whole history before
    /// printing the first line. The revisions go on stdin, since a page's
    /// starting points can be many.
    public func log(from starts: [String], excluding: [String], count: Int, in repo: URL) async throws
        -> [Commit]
    {
        let revs = (starts + excluding.map { "^" + $0 }).map { $0 + "\n" }.joined()
        let out = try await run(
            ["log", "--no-show-signature", "-z", Commit.format, "--max-count=\(count)", "--stdin"], in: repo,
            input: Data(revs.utf8))
        return Commit.parse(log: out.stdout)
    }

    public func commitDetail(_ sha: String, in repo: URL) async throws -> CommitDetail {
        let out = try await run(
            ["log", "-1", "--no-show-signature", CommitDetail.format, sha, "--"], in: repo)
        guard let detail = CommitDetail(parsing: out.stdout) else {
            throw GitError(arguments: ["log"], status: 0, message: "Could not read commit \(sha).")
        }
        return detail
    }

    /// The files `commit` changed. A merge is compared with its first
    /// parent, as GitHub Desktop shows it: what the merge brought in.
    public func files(of commit: CommitDetail, in repo: URL) async throws -> [CommitFile] {
        let out = try await run(
            ["diff-tree", "-r", "-z", "--name-status", "-M", "--root", "--no-commit-id"]
                + commit.parents.prefix(1) + [commit.id], in: repo)
        return CommitFile.parse(out.stdout)
    }

    /// One file's diff in `commit`, against its first parent, or against
    /// nothing for a first commit. Stops at `FileDiff.byteCeiling`.
    public func diff(
        of file: CommitFile, in commit: CommitDetail, in repo: URL, ignoringWhitespace: Bool = false
    ) async throws -> FileDiff {
        var base = commit.parents.first
        if base == nil {
            // The empty tree's name depends on the repository's hash (SHA-1 or SHA-256).
            base = try await run(["hash-object", "-t", "tree", "--stdin"], in: repo, input: Data()).text
                .trimmingCharacters(in: .newlines)
        }
        let out = try await run(
            FileDiff.base + (ignoringWhitespace ? ["-w"] : []) + [
                "--find-renames", base ?? "", commit.id, "--",
            ]
                + file.paths, in: repo, limit: FileDiff.byteCeiling)
        return out.truncated
            ? .tooLarge : FileDiff(parsing: out.stdout, ignoringWhitespace: ignoringWhitespace)
    }
}
