import Foundation
import Observation

/// Branches, remotes and the stash of the selected repository
/// (docs/plans/005_branches_and_remotes.md).
@MainActor @Observable
public final class BranchesModel: Feature {
    public weak var app: AppModel?

    /// Local and remote-tracking branches, as `for-each-ref` lists them.
    public private(set) var all: [Branch] = []
    public private(set) var remotes: [String] = []
    /// The current branch's stash entries left by Upstream, newest first.
    public private(set) var stashes: [StashEntry] = []
    /// When this repository last fetched: the time git wrote `FETCH_HEAD`,
    /// so a fetch in a terminal counts too.
    public private(set) var lastFetched: Date?
    /// Why the last background fetch failed; nil when it did not.
    public private(set) var fetchError: String?
    public private(set) var isFetching = false
    /// The current branch has diverged from its upstream because its own
    /// commits were rewritten (amend, rebase): the upstream's tip is in the
    /// branch's reflog. Then the remote button offers a force push rather
    /// than a pull, which would bring the old commits back.
    public private(set) var upstreamRewritten = false

    /// The branch popover in the toolbar.
    public var showsList = false
    /// The dialog on screen, if any.
    public var sheet: BranchSheet?

    /// How often to fetch while the app is in front; nil for never (tests).
    var fetchInterval: Duration? = .seconds(300)

    nonisolated init() {}

    public var current: Branch? { all.first(where: \.isHead) }

    /// Where Publish pushes: origin, or the only remote. nil when there are
    /// several and none is origin, and the user is asked.
    public var publishRemote: String? {
        remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes[0] : nil
    }

    /// What Fetch fetches: the current branch's remote, else as Publish.
    public var fetchRemote: String? {
        if let r = current?.upstreamRemote, remotes.contains(r) { return r }
        return publishRemote ?? remotes.first
    }

    /// GitHub Desktop's one remote button: what it does now.
    public var action: RemoteAction? {
        guard let status = app?.status, !remotes.isEmpty else { return nil }
        let b = status.branch
        guard b.head != nil else { return .fetch }  // detached: nothing to push
        guard b.oid != nil else { return nil }  // no commit yet: nothing to publish
        if b.upstream == nil || current?.upstreamGone == true { return .publish }
        if b.behind > 0 { return b.ahead > 0 && upstreamRewritten ? .forcePush : .pull }
        return b.ahead > 0 ? .push : .fetch
    }

    // MARK: Following the selected repository

    /// The selected repository changed: forget the old one's state.
    func repositoryChanged() {
        fetchLoop?.cancel()
        fetchLoop = nil
        reloadTask?.cancel()
        reloadTask = nil
        reloadAgain = false
        loaded = false
        fetchHeadPath = nil
        lastAttempt = nil
        (all, remotes, stashes, lastFetched, fetchError, upstreamRewritten) = ([], [], [], nil, nil, false)
        (showsList, sheet) = (false, nil)
    }

    /// The app came to the front or left it. Background fetches happen only
    /// in front.
    func activeChanged(_ active: Bool) {
        if active {
            startFetching()
        } else {
            fetchLoop?.cancel()
            fetchLoop = nil
        }
    }

    /// The status read changed the branch, its upstream, ahead/behind or
    /// the number of stashes.
    func statusChanged() {
        Task { await reload() }
        startFetching()
    }

    private var reloadTask: Task<Void, Never>?
    private var reloadAgain = false
    private var loaded = false

    /// Reads the branches, remotes, stash and last fetch again. Coalesced as
    /// `AppModel.refresh` is: a call while one runs waits for one more round.
    public func reload() async {
        if let running = reloadTask {
            reloadAgain = true
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                reloadAgain = false
                await reloadOnce()
            } while reloadAgain && !Task.isCancelled
            reloadTask = nil
        }
        reloadTask = task
        await task.value
    }

    private func reloadOnce() async {
        guard let app, let git = app.git, let repo = app.selected else { return }
        do {
            async let refs = git.run(Branch.arguments, in: repo)
            async let names = git.run(["remote"], in: repo)
            async let stash = git.run(StashEntry.arguments, in: repo)
            let (r, n, s) = try await (refs, names, stash)
            guard repo == app.selected, !Task.isCancelled else { return }
            let remotes = n.text.split(separator: "\n").map(String.init)
            let all = Branch.parse(r.stdout, remotes: remotes)
            let head = all.first(where: \.isHead)
            let stashes = head.map { h in StashEntry.parse(s.stdout).filter { $0.belongs(to: h.name) } } ?? []
            let rewritten = await isRewritten(head, git, repo)
            let fetched = await readLastFetched(git, repo)
            guard repo == app.selected else { return }
            if all != self.all { self.all = all }
            if remotes != self.remotes { self.remotes = remotes }
            if stashes != self.stashes { self.stashes = stashes }
            if rewritten != upstreamRewritten { upstreamRewritten = rewritten }
            if fetched != lastFetched { lastFetched = fetched }
            loaded = true
        } catch {
            // A repository being deleted or moved; the status read says so.
        }
    }

    /// Whether the upstream's tip was once on `branch`: reachable from one
    /// of its reflog entries, which is the test `--force-if-includes` makes.
    /// Asked only when the branch has diverged, so it costs nothing usually.
    private func isRewritten(_ branch: Branch?, _ git: Git, _ repo: URL) async -> Bool {
        guard let branch, branch.track == .diverged, let upstream = branch.upstream,
            let log = try? await git.run(
                ["log", "-g", "--no-show-signature", "--format=%H", branch.ref, "--"], in: repo)
        else { return false }
        let input = log.text.split(separator: "\n").map { "^\($0)\n" }.joined()
        // Lists the upstream's tip unless some reflog entry reaches it.
        let left = try? await git.run(
            ["rev-list", "--max-count=1", "--stdin", upstream, "--"], in: repo, input: Data(input.utf8))
        return left?.stdout.isEmpty == true
    }

    private var fetchHeadPath: String?

    private func readLastFetched(_ git: Git, _ repo: URL) async -> Date? {
        if fetchHeadPath == nil {
            fetchHeadPath = try? await git.run(
                ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], in: repo
            ).text.trimmingCharacters(in: .newlines)
        }
        guard let fetchHeadPath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: fetchHeadPath))?[.modificationDate] as? Date
    }

    // MARK: Background fetch

    private var fetchLoop: Task<Void, Never>?
    private var loopRepo: URL?
    /// When a background fetch last started, so a failing one (offline)
    /// waits a whole interval too instead of retrying at once.
    private var lastAttempt: Date?

    /// Fetches the selected repository every `fetchInterval` while the app
    /// is in front, and at once if it has not fetched for that long. Nothing
    /// runs in the background: the owner audits idle CPU and network. The
    /// other repositories are fetched for their rows, more rarely
    /// (`OverviewModel`, docs/plans/011_status_on_every_row.md).
    private func startFetching() {
        guard let app, app.isActive, let repo = app.selected, let interval = fetchInterval,
            fetchLoop == nil || loopRepo != repo
        else { return }
        fetchLoop?.cancel()
        loopRepo = repo
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.untilNextFetch(interval) else { return }
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                await self?.backgroundFetch()
            }
        }
    }

    private func untilNextFetch(_ interval: Duration) async -> TimeInterval {
        // The status read that started this loop has usually started a
        // reload too: wait for that one rather than asking for another.
        if let running = reloadTask { await running.value } else if !loaded { await reload() }
        if let app, let git = app.git, let repo = app.selected {
            let fetched = await readLastFetched(git, repo)
            if fetched != lastFetched { lastFetched = fetched }
        }
        let last = max(lastFetched ?? .distantPast, lastAttempt ?? .distantPast)
        return last.addingTimeInterval(interval / .seconds(1)).timeIntervalSinceNow
    }

    private func backgroundFetch() async {
        lastAttempt = .now  // even when there is nothing to fetch, so the loop sleeps
        guard let app, let git = app.git, let repo = app.selected, app.isActive, app.activity == nil,
            let remote = fetchRemote
        else { return }
        isFetching = true
        defer { isFetching = false }
        let env = await Self.batchMode(git, repo)
        let net = await app.networkArguments(in: repo, remote: remote)
        do {
            // credential.interactive: Git Credential Manager must not open a
            // sign-in window every five minutes; git itself ignores the key.
            try await git.run(
                net + ["-c", "credential.interactive=false", "fetch", "--prune", "--quiet", remote], in: repo,
                environment: env)
            fetchError = nil
        } catch {
            fetchError = error.localizedDescription
        }
        guard repo == app.selected else { return }
        await app.refresh()
        await reload()
    }

    /// `GIT_SSH_COMMAND` with `-o BatchMode=yes` added to whatever ssh the
    /// user set, so a background fetch fails rather than waits on a
    /// passphrase or host key question nobody sees. A `GIT_SSH` program
    /// takes no ssh options, so it is left alone.
    static func batchMode(_ git: Git, _ repo: URL) async -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        if env["GIT_SSH_COMMAND"] == nil, env["GIT_SSH"] != nil { return [:] }
        let configured = try? await git.run(["config", "--get", "core.sshCommand"], in: repo).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ssh = env["GIT_SSH_COMMAND"] ?? (configured.flatMap { $0.isEmpty ? nil : $0 } ?? "ssh")
        return ["GIT_SSH_COMMAND": ssh + " -o BatchMode=yes"]
    }

    // MARK: Branches

    /// Switches to `branch`. A remote branch with no local one becomes a
    /// new local branch tracking it. Changes come along unless
    /// `leavingChanges`, which stashes them on the current branch first;
    /// they come back when the user restores the stash there.
    public func switchTo(_ branch: Branch, leavingChanges: Bool = false) async {
        guard let app else { return }
        let target = branch.isRemote ? (localBranch(for: branch) ?? branch) : branch
        let from = current?.name
        showsList = false
        let label = target.nameOnRemote ?? target.name
        await app.perform("Switching to \(label)…") { git, repo in
            var stashed = false
            if leavingChanges, let from {
                let before = try? await git.run(["rev-parse", "-q", "--verify", "refs/stash"], in: repo)
                try await git.run(
                    ["stash", "push", "--include-untracked", "--message", StashEntry.tag(for: from)], in: repo
                )
                let after = try? await git.run(["rev-parse", "-q", "--verify", "refs/stash"], in: repo)
                stashed = after?.text != before?.text
            }
            do {
                if let local = target.nameOnRemote {
                    try await git.run(["switch", "-c", local, "--track", target.ref], in: repo)
                } else {
                    try await git.run(["switch", target.name], in: repo)
                }
            } catch {
                // Put the changes back where they were rather than leave them in a stash.
                if stashed { _ = try? await git.run(["stash", "pop"], in: repo) }
                throw error
            }
        }
        await reload()
    }

    /// The local branch a remote branch is checked out as: the one tracking
    /// it, or one of the same name.
    public func localBranch(for remote: Branch) -> Branch? {
        all.first { !$0.isRemote && $0.upstream == remote.ref }
            ?? all.first { !$0.isRemote && $0.name == remote.nameOnRemote }
    }

    /// Creates `name` from `start` (the current branch when nil) and
    /// switches to it, changes and all. It tracks nothing, even from a
    /// remote branch, so the remote button offers to publish it, as in
    /// GitHub Desktop, rather than to push into the branch it started from.
    @discardableResult
    public func create(_ name: String, from start: Branch? = nil) async -> Bool {
        guard let app else { return false }
        let ok = await app.perform("Creating \(name)…") { git, repo in
            try await git.run(
                ["switch", "--no-track", "-c", name] + (start.map { [$0.ref] } ?? []), in: repo)
        }
        await reload()
        return ok
    }

    @discardableResult
    public func rename(_ branch: Branch, to name: String) async -> Bool {
        guard let app else { return false }
        let ok = await app.perform("Renaming \(branch.name)…") { git, repo in
            try await git.run(["branch", "-m", branch.name, name], in: repo)
        }
        await reload()
        return ok
    }

    /// What deleting a local branch would lose: its commits not in its
    /// upstream (or, without one, in HEAD), which is what `branch -d` checks.
    public func deletion(of branch: Branch) async -> Deletion? {
        guard let app, let git = app.git, let repo = app.selected else { return nil }
        let base = branch.upstream.flatMap { branch.upstreamGone ? nil : $0 } ?? "HEAD"
        guard
            let count = try? await git.run(["rev-list", "--count", "\(base)..\(branch.ref)", "--"], in: repo)
        else { return nil }
        let into = base == "HEAD" ? (current?.name ?? "HEAD") : Branch.shortName(base)
        return Deletion(
            unmerged: Int(count.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, into: into)
    }

    /// Deletes a local branch: `-d`, or `-D` when the user confirmed losing
    /// its unmerged commits. `alsoRemote` deletes its upstream branch too.
    public func delete(_ branch: Branch, force: Bool, alsoRemote: Bool = false) async {
        guard let app else { return }
        await app.perform("Deleting \(branch.name)…") { git, repo in
            try await git.run(["branch", force ? "-D" : "-d", branch.name], in: repo)
            if alsoRemote, !branch.upstreamGone, let remote = branch.upstreamRemote,
                let ref = branch.upstreamMerge
            {
                let net = await app.networkArguments(in: repo, remote: remote)
                try await git.run(net + ["push", remote, "--delete", ref], in: repo)
            }
        }
        await reload()
    }

    /// Deletes a branch on its remote, for everyone who uses it.
    public func deleteRemote(_ branch: Branch) async {
        guard let app, let remote = branch.remote, let name = branch.nameOnRemote else { return }
        await app.perform("Deleting \(branch.name)…") { git, repo in
            let net = await app.networkArguments(in: repo, remote: remote)
            try await git.run(net + ["push", remote, "--delete", "refs/heads/\(name)"], in: repo)
        }
        await reload()
    }

    // MARK: Merging

    /// What merging (or rebasing onto) `branch` would do, before doing it:
    /// how many commits each side has that the other lacks and, for a merge,
    /// which files would conflict. `merge-tree --write-tree` (git 2.38)
    /// merges in memory, without touching the working tree or the index.
    public func preview(_ kind: MergeKind, _ branch: Branch) async throws -> MergePreview {
        guard let app, let git = app.git, let repo = app.selected else { throw CancellationError() }
        func count(_ range: String) async throws -> Int {
            let r = try await git.run(["rev-list", "--count", range, "--"], in: repo)
            return Int(r.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let incoming = try await count("HEAD..\(branch.ref)")
        let outgoing = try await count("\(branch.ref)..HEAD")
        guard kind != .rebase, incoming > 0 else {
            return MergePreview(incoming: incoming, outgoing: outgoing, conflicts: kind == .rebase ? nil : [])
        }
        let result = try await git.run(
            ["merge-tree", "--write-tree", "--name-only", "-z", "--no-messages", "HEAD", branch.ref],
            in: repo,
            allowedExitCodes: [0, 1])
        return MergePreview(
            incoming: incoming, outgoing: outgoing,
            conflicts: result.status == 0 ? [] : MergePreview.conflicts(parsing: result.stdout))
    }

    /// Merges `branch` into the current one, squashes it into changes to
    /// commit, or rebases the current one onto it. A conflict leaves the
    /// repository conflicted, as git does, for the user to resolve.
    public func merge(_ kind: MergeKind, _ branch: Branch) async {
        guard let app else { return }
        // The short name, so the merge commit says "Merge branch 'x'", as git's own does.
        let args: [String] =
            switch kind {
            case .merge: ["merge", "--no-edit", branch.name]
            case .squash: ["merge", "--squash", branch.name]
            case .rebase: ["rebase", branch.name]
            }
        let verb = kind == .rebase ? "Rebasing onto" : "Merging"
        await app.perform("\(verb) \(branch.name)…") { git, repo in try await git.run(args, in: repo) }
        await reload()
    }

    // MARK: Remotes

    public func fetch() async {
        guard let remote = fetchRemote else { return }
        await network("Fetching \(remote)…", remote, ["fetch", "--prune", remote])
    }

    /// `git pull`, nothing added: the user's `pull.rebase` (or its absence)
    /// decides between merge, rebase and fast-forward only.
    public func pull() async {
        guard let remote = current?.upstreamRemote else { return }
        await network("Pulling \(remote)…", remote, ["pull"])
    }

    /// Pushes the current branch to its upstream, whatever its name there.
    public func push() async {
        guard let b = current, let remote = b.upstreamRemote, let ref = b.upstreamMerge else { return }
        await network("Pushing to \(remote)…", remote, ["push", remote, "HEAD:\(ref)"])
    }

    /// Pushes a branch that has no upstream yet and makes the pushed one its
    /// upstream.
    public func publish(to remote: String) async {
        guard let name = app?.status?.branch.head else { return }
        await network(
            "Publishing \(name)…", remote, ["push", "--set-upstream", remote, "HEAD:refs/heads/\(name)"])
    }

    /// Replaces the upstream with the current branch. `--force-with-lease`
    /// refuses if the remote moved since the last fetch; `--force-if-includes`
    /// also refuses if what was fetched was never in this branch, which a
    /// background fetch would otherwise turn into a silent overwrite.
    public func forcePush() async {
        guard let b = current, let remote = b.upstreamRemote, let ref = b.upstreamMerge else { return }
        await network(
            "Force pushing to \(remote)…", remote,
            ["push", "--force-with-lease", "--force-if-includes", remote, "HEAD:\(ref)"])
    }

    /// The subjects of the upstream's commits that a force push would take
    /// off it, newest first, at most `limit`.
    public func forcePushOverwrites(limit: Int = 10) async -> [String] {
        guard let app, let git = app.git, let repo = app.selected, let upstream = current?.upstream,
            let log = try? await git.run(
                [
                    "log", "-z", "--no-show-signature", "--format=%s", "--max-count=\(limit)",
                    "HEAD..\(upstream)", "--",
                ],
                in: repo)
        else { return [] }
        return log.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    private func network(_ activity: String, _ remote: String, _ args: [String]) async -> Bool {
        guard let app else { return false }
        let ok = await app.perform(activity) { git, repo in
            let net = await app.networkArguments(in: repo, remote: remote)
            try await git.run(net + args, in: repo)
        }
        await reload()
        return ok
    }

    // MARK: Stash

    /// Stashes every change, untracked files too, on the current branch.
    public func stashChanges() async {
        guard let app, let from = current?.name else { return }
        await app.perform("Stashing changes…") { git, repo in
            try await git.run(
                ["stash", "push", "--include-untracked", "--message", StashEntry.tag(for: from)], in: repo)
        }
        await reload()
    }

    /// `stash pop` of the newest entry. On a conflict git keeps the entry,
    /// and the error says so in words rather than git's.
    public func restoreStash() async {
        guard let app, let entry = stashes.first else { return }
        let conflictsBefore = app.status?.files.filter(\.conflicted).count ?? 0
        let ok = await app.perform("Restoring stashed changes…") { git, repo in
            try await git.run(["stash", "pop", try await Self.stashRef(entry, git, repo)], in: repo)
        }
        if !ok, (app.status?.files.filter(\.conflicted).count ?? 0) > conflictsBefore {
            app.error =
                "The stashed changes conflict with this branch. Resolve the conflicted files; the stash is kept until you discard it."
        }
        await reload()
    }

    /// `stash drop` of the newest entry, after the user confirmed.
    public func discardStash() async {
        guard let app, let entry = stashes.first else { return }
        await app.perform("Discarding stashed changes…") { git, repo in
            try await git.run(["stash", "drop", try await Self.stashRef(entry, git, repo)], in: repo)
        }
        await reload()
    }

    /// `stash@{n}` for the entry now: pushing another stash renumbers them,
    /// and `pop` and `drop` take nothing else.
    private static func stashRef(_ entry: StashEntry, _ git: Git, _ repo: URL) async throws -> String {
        let list = StashEntry.parse(try await git.run(StashEntry.arguments, in: repo).stdout)
        guard let n = list.firstIndex(where: { $0.oid == entry.oid }) else {
            throw GitError(arguments: ["stash"], status: 1, message: "The stash entry is gone.")
        }
        return "stash@{\(n)}"
    }
}

public enum RemoteAction: Sendable, Equatable { case publish, pull, push, forcePush, fetch }

public enum MergeKind: Sendable, Hashable { case merge, squash, rebase }

/// The dialogs the branch menu, the remote button and the menu bar open.
public enum BranchSheet: Identifiable, Sendable, Equatable {
    case create(from: Branch?)
    case rename(Branch)
    case delete(Branch)
    case deleteRemote(Branch)
    case merge(MergeKind, Branch?)
    case switching(to: Branch)
    case forcePush
    case publish
    case discardStash

    public var id: String { String(describing: self) }
}

public struct Deletion: Sendable, Equatable {
    /// Commits on the branch that are not in `into`.
    public var unmerged: Int
    public var into: String
}

/// One local or remote-tracking branch, as `git for-each-ref` describes it.
public struct Branch: Sendable, Equatable, Hashable, Identifiable {
    /// `refs/heads/main` or `refs/remotes/origin/main`.
    public var ref: String
    public var isHead = false
    /// The upstream's ref here (`refs/remotes/origin/main`), its remote and
    /// its ref on the remote (`refs/heads/main`).
    public var upstream: String?
    public var upstreamRemote: String?
    public var upstreamMerge: String?
    /// Against the upstream; nil without one, or when it is gone.
    public var track: Track?
    /// Of its last commit.
    public var date: Date
    /// A remote-tracking branch's remote.
    public var remote: String?

    public var id: String { ref }
    public var isRemote: Bool { ref.hasPrefix("refs/remotes/") }
    /// "main", or "origin/main": what git's own messages call it.
    public var name: String { Self.shortName(ref) }
    /// A remote branch's name on its remote: "main" of "origin/main".
    public var nameOnRemote: String? { remote.map { String(name.dropFirst($0.count + 1)) } }
    /// It has an upstream configured that no longer exists, usually because
    /// the branch was deleted on the remote after a merge.
    public var upstreamGone: Bool { upstream != nil && track == nil }

    public enum Track: String, Sendable { case same = "=", ahead = ">", behind = "<", diverged = "<>" }

    static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// Each field ends in NUL. `trackshort` (`=`, `>`, `<`, `<>`) rather
    /// than `track`, whose "ahead 2" and "gone" are translated.
    static let format = [
        "HEAD", "refname", "symref", "upstream", "upstream:remotename", "upstream:remoteref",
        "upstream:trackshort", "committerdate:unix",
    ].map { "%(\($0))%00" }.joined()
    public static let arguments = ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"]

    /// `for-each-ref` has no `-z`: git ends each record with a newline,
    /// which lands at the start of the next record's first field. A refname
    /// cannot hold a newline or a NUL, so this cannot misread.
    public static func parse(_ data: Data, remotes: [String]) -> [Branch] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        let n = 8
        var branches: [Branch] = []
        var i = 0
        while i + n <= fields.count {
            let f = Array(fields[i..<i + n])
            i += n
            let head = f[0].hasPrefix("\n") ? f[0].dropFirst() : f[0][...]
            guard f[2].isEmpty, let seconds = TimeInterval(f[7]) else { continue }  // origin/HEAD
            var b = Branch(ref: f[1], date: Date(timeIntervalSince1970: seconds))
            b.isHead = head == "*"
            b.upstream = f[3].isEmpty ? nil : f[3]
            b.upstreamRemote = f[4].isEmpty ? nil : f[4]
            b.upstreamMerge = f[5].isEmpty ? nil : f[5]
            b.track = Track(rawValue: f[6])
            if b.isRemote {
                // The longest remote whose name prefixes it: remote names may hold slashes.
                b.remote = remotes.filter { b.name.hasPrefix($0 + "/") }.max { $0.count < $1.count }
                guard b.remote != nil else { continue }
            }
            branches.append(b)
        }
        return branches
    }
}

/// What a merge or rebase would do, from `Branch.preview`.
public struct MergePreview: Sendable, Equatable {
    /// Commits on the other branch that are not on this one.
    public var incoming: Int
    /// Commits on this branch that are not on the other.
    public var outgoing: Int
    /// The files a merge would leave conflicted; nil for a rebase, which
    /// replays commit by commit and cannot be previewed in one step.
    public var conflicts: [String]?

    /// `merge-tree --write-tree --name-only -z --no-messages`: the tree,
    /// then each conflicted path once, every field ending in NUL.
    static func conflicts(parsing data: Data) -> [String] {
        data.split(separator: 0).dropFirst().map { String(decoding: $0, as: UTF8.self) }
    }
}

/// One stash entry (`git stash list`).
public struct StashEntry: Sendable, Equatable, Identifiable {
    public var oid: String
    public var date: Date
    /// The reflog subject: "On main: <message>".
    public var subject: String

    public var id: String { oid }

    /// Records end in NUL; the subject comes last, so a stray 0x1f in a
    /// message the user typed cannot shift a field.
    static let arguments = ["stash", "list", "-z", "--no-show-signature", "--format=%H%x1f%ct%x1f%gs"]

    static func parse(_ data: Data) -> [StashEntry] {
        data.split(separator: 0).compactMap { record in
            let f = String(decoding: record, as: UTF8.self).split(
                separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3, let seconds = TimeInterval(f[1]) else { return nil }
            return StashEntry(
                oid: String(f[0]), date: Date(timeIntervalSince1970: seconds), subject: String(f[2]))
        }
    }

    /// The message Upstream gives a stash it makes on `branch`. The Changes
    /// list offers only the current branch's, as GitHub Desktop does with
    /// its own tag: an entry made in a terminal is the user's to manage, and
    /// restoring it on whatever branch is current would be a surprise.
    public static func tag(for branch: String) -> String { "!!Upstream<\(branch)>" }

    /// Whether Upstream, or GitHub Desktop (whose tag this copies), left it
    /// on `branch`: a GitHub Desktop user's stashes stay where they left them.
    public func belongs(to branch: String) -> Bool {
        subject.hasSuffix(Self.tag(for: branch)) || subject.hasSuffix("!!GitHub_Desktop<\(branch)>")
    }
}
