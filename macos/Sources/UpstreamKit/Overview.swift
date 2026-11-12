import Foundation
import Observation

/// What a sidebar row shows: commits to push and to pull, and whether
/// anything is uncommitted (docs/plans/011_status_on_every_row.md).
public struct RowStatus: Sendable, Equatable {
    public var ahead: Int
    public var behind: Int
    /// Changed, staged or untracked files: uncommitted work.
    public var hasChanges: Bool

    public init(ahead: Int = 0, behind: Int = 0, hasChanges: Bool = false) {
        self.ahead = ahead
        self.behind = behind
        self.hasChanges = hasChanges
    }

    init(_ status: RepoStatus) {
        self.init(ahead: status.branch.ahead, behind: status.branch.behind, hasChanges: !status.files.isEmpty)
    }
}

/// A Pull All in progress, or its summary until dismissed.
public struct PullAllRun: Sendable, Equatable {
    public var total: Int
    public var done = 0
    /// What was pulled and what was skipped, by repository name once
    /// finished. An up-to-date repository is not listed.
    public var outcomes: [Outcome] = []
    public var isStopping = false
    public var isFinished = false

    public init(total: Int) { self.total = total }

    public struct Outcome: Sendable, Equatable, Identifiable {
        public let repository: URL
        public let result: Result
        public var id: URL { repository }
    }

    public enum Result: Sendable, Equatable {
        case pulled(commits: Int)
        /// Why, in git's words where git refused.
        case skipped(String)
    }
}

/// Every repository's row status, the fetches that keep its ↓ honest, and
/// Pull All. The selected repository's row copies the window's own status;
/// the others are read at launch and when FSEvents says something in them
/// changed, never on a timer.
@MainActor @Observable
public final class OverviewModel: Feature {
    public weak var app: AppModel?

    public private(set) var rows: [URL: RowStatus] = [:]
    /// Settings → General → "Show status in the repository list". Off,
    /// nothing here runs but Pull All.
    public private(set) var isOn = true
    public private(set) var pullAll: PullAllRun?

    /// How often to look for repositories to fetch while in front; nil for
    /// never (tests).
    var fetchInterval: Duration? = .seconds(15 * 60)
    /// A repository fetched more recently than this is not fetched again.
    var fetchAge: TimeInterval = 30 * 60
    /// How many statuses were read for rows: what the filtering exists to
    /// keep low, so the tests count it.
    private(set) var reads = 0

    static let concurrency = 4
    /// `normal`, not the window's `all`: the dot needs to know a new file
    /// is there, not to list every file in a new folder.
    static let arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]
    private static let key = "showsRepositoryStatus"

    @ObservationIgnored private var pending: Set<URL> = []
    /// Changed while the app was behind: read on coming to the front.
    @ObservationIgnored private var stale: Set<URL> = []
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var watcher: Watcher?
    /// Each watched folder by its real path, as FSEvents reports it.
    @ObservationIgnored private var watched: [String: (repo: URL, filter: WatchFilter)] = [:]
    @ObservationIgnored private var fetchLoop: Task<Void, Never>?
    /// Two minutes after launch, as GitHub Desktop waits, so launch stays quiet.
    @ObservationIgnored private var nextFetch = Date.now.addingTimeInterval(120)
    @ObservationIgnored private var fetchHeads: [URL: String] = [:]

    nonisolated init() {}

    func restore() {
        isOn = app?.defaults.object(forKey: Self.key) as? Bool ?? true
    }

    public func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        app?.defaults.set(on, forKey: Self.key)
        if on {
            if let app, let repo = app.selected, let status = app.status { selectedRead(repo, status) }
            libraryChanged()
        } else {
            (watcher, watched, pending, stale, rows) = (nil, [:], [], [], [:])
            fetchLoop?.cancel()
            fetchLoop = nil
        }
    }

    // MARK: Following the app

    /// The sidebar read its folders and remotes: watch the ones there and
    /// read those without a row yet.
    func libraryChanged() {
        guard isOn, let app, app.library.loaded else { return }
        let present = app.repositories.filter { !app.library.missing.contains($0) }
        let kept = rows.filter { present.contains($0.key) }
        if kept.count != rows.count { rows = kept }
        watch(present)
        read(present.filter { rows[$0] == nil })
        startFetching()
    }

    /// The window read the selected repository's status.
    func selectedRead(_ repo: URL, _ status: RepoStatus) {
        guard isOn else { return }
        let row = RowStatus(status)
        if rows[repo] != row { rows[repo] = row }
    }

    func activeChanged(_ active: Bool) {
        guard isOn else { return }
        if active {
            let changed = stale
            stale = []
            read(changed)
            startFetching()
        } else {
            fetchLoop?.cancel()
            fetchLoop = nil
        }
    }

    // MARK: Reading rows

    /// Reads the rows of `repos`, four at a time. The selected one is the
    /// window's to read.
    func read(_ repos: some Sequence<URL>) {
        guard isOn, let app else { return }
        pending.formUnion(repos.filter { $0 != app.selected })
        guard reading == nil, !pending.isEmpty else { return }
        reading = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        let arguments = Self.arguments
        while isOn, let app, let git = app.git, !pending.isEmpty {
            let batch = Array(pending.prefix(Self.concurrency))
            pending.subtract(batch)
            reads += batch.count
            let results = await withTaskGroup(of: (URL, RowStatus?).self) { group in
                for repo in batch {
                    group.addTask {
                        let out = try? await git.run(arguments, in: repo)
                        return (repo, out.map { RowStatus(RepoStatus(parsing: $0.stdout)) })
                    }
                }
                var found: [(URL, RowStatus?)] = []
                for await pair in group { found.append(pair) }
                return found
            }
            guard isOn else { break }
            for (repo, row) in results where repo != app.selected && app.repositories.contains(repo) {
                if rows[repo] != row { rows[repo] = row }
            }
        }
        reading = nil  // in the same step as the last check, so no call slips between
    }

    // MARK: Watching

    /// One FSEvents stream over every repository's folder. Its git
    /// directory is `.git` inside it; a linked worktree's lies elsewhere
    /// and is not watched (the plan's open question).
    private func watch(_ repos: [URL]) {
        var roots: [String: (repo: URL, filter: WatchFilter)] = [:]
        for repo in repos {
            let filter = WatchFilter(workTree: repo, gitDirs: [repo.appending(path: ".git")])
            roots[filter.workTree] = (repo, filter)
        }
        guard Set(roots.keys) != Set(watched.keys) else { return }
        watched = roots
        watcher = nil
        guard !roots.isEmpty else { return }
        // A second's latency: a row can wait, and a save storm costs one read.
        watcher = Watcher(paths: Array(roots.keys), latency: 1) { [weak self] paths in
            Task { @MainActor in await self?.changed(paths) }
        }
    }

    /// FSEvents saw `paths` change (nil: anything may have, in any of them).
    private func changed(_ paths: [String]?) async {
        guard isOn, let app, let git = app.git else { return }
        var touched: [URL] = []
        if let paths {
            let byRoot = Dictionary(grouping: paths) { path in
                watched.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            }
            for case let (root?, paths) in byRoot {
                guard let (repo, filter) = watched[root], repo != app.selected else { continue }
                if await filter.worthReading(paths, git: git) { touched.append(repo) }
            }
        } else {
            touched = watched.values.map(\.repo)
        }
        if app.isActive { read(touched) } else { stale.formUnion(touched) }
    }

    // MARK: Fetching the others

    private func startFetching() {
        guard isOn, let app, app.isActive, let interval = fetchInterval, fetchLoop == nil else { return }
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.nextFetch.timeIntervalSinceNow else { return }
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let self else { return }
                await fetchDue()
                nextFetch = .now.addingTimeInterval(interval / .seconds(1))
            }
        }
    }

    /// Fetches, one at a time, each repository but the selected one whose
    /// last fetch is older than `fetchAge`, skipping one the forge says
    /// nobody pushed to since. The selected one has its own fetch
    /// (docs/plans/005_branches_and_remotes.md).
    func fetchDue() async {
        guard isOn, let app, let git = app.git else { return }
        let library = app.library
        let candidates = app.repositories.filter {
            $0 != app.selected && !library.missing.contains($0) && !library.remoteURLs(of: $0).isEmpty
        }
        var last: [URL: Date] = [:]
        for repo in candidates { last[repo] = await lastFetched(git, repo) }
        let cutoff = Date.now.addingTimeInterval(-fetchAge)
        let old = candidates.filter { (last[$0] ?? .distantPast) < cutoff }
        guard !old.isEmpty else { return }
        let pushes = await app.forge.lastPushes(of: old.compactMap { library.forgeRepositories[$0] })
        for repo in old {
            if let ref = library.forgeRepositories[repo], let pushed = pushes[ref], let fetched = last[repo],
                pushed <= fetched
            {
                continue
            }
            guard isOn, app.isActive, repo != app.selected, !Task.isCancelled else { return }
            _ = await fetch(repo)
            read([repo])
        }
    }

    /// When git last wrote the repository's `FETCH_HEAD`: git's own record,
    /// so a fetch in a terminal counts.
    private func lastFetched(_ git: Git, _ repo: URL) async -> Date? {
        if fetchHeads[repo] == nil {
            fetchHeads[repo] = try? await git.run(
                ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], in: repo
            ).text.trimmingCharacters(in: .newlines)
        }
        guard let path = fetchHeads[repo] else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The background fetch, without prompts. No remote is named, so git
    /// fetches the current branch's remote, else origin. Every remote's URL
    /// gets the signed-in forge's credential helper. git's error, or nil.
    private func fetch(_ repo: URL) async -> String? {
        guard let app, let git = app.git else { return nil }
        let env = await BranchesModel.batchMode(git, repo)
        var net: [String] = []
        for url in Set(app.library.remoteURLs(of: repo)).sorted() {
            net += await app.networkArguments(in: repo, remote: url)
        }
        do {
            try await git.run(
                net + ["-c", "credential.interactive=false", "fetch", "--prune", "--quiet"], in: repo,
                environment: env)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Pull All

    /// Fetches every repository with a remote, four at a time, and
    /// fast-forwards each whose branch is behind and not ahead. Anything
    /// else is skipped and listed: a pull that would merge or rebase is the
    /// user's to make (the plan's Pull All).
    public func startPullAll() {
        guard let app, pullAll == nil else { return }
        let repos = app.repositories.filter {
            !app.library.missing.contains($0) && !app.library.remoteURLs(of: $0).isEmpty
        }
        pullAll = PullAllRun(total: repos.count)
        Task { await runPullAll(repos) }
    }

    /// Finishes the repositories already started, and starts no more: a
    /// fast-forward killed halfway could leave an index lock behind.
    public func stopPullAll() { pullAll?.isStopping = true }

    public func dismissPullAll() {
        if pullAll?.isFinished == true { pullAll = nil }
    }

    func runPullAll(_ repos: [URL]) async {
        var queue = repos[...]
        await withTaskGroup(of: (URL, PullAllRun.Result?).self) { group in
            var running = 0
            while true {
                while running < Self.concurrency, pullAll?.isStopping != true, let repo = queue.popFirst() {
                    group.addTask { await (repo, self.pull(repo)) }
                    running += 1
                }
                guard let (repo, result) = await group.next() else { break }
                running -= 1
                pullAll?.done += 1
                if let result { pullAll?.outcomes.append(.init(repository: repo, result: result)) }
            }
        }
        pullAll?.outcomes.sort {
            $0.repository.lastPathComponent.localizedStandardCompare($1.repository.lastPathComponent)
                == .orderedAscending
        }
        pullAll?.isFinished = true
        read(repos)
        if let selected = app?.selected, repos.contains(selected) { await app?.refresh() }
    }

    /// nil when there is nothing to say: up to date, no upstream, detached.
    private func pull(_ repo: URL) async -> PullAllRun.Result? {
        guard let app, let git = app.git else { return nil }
        if repo == app.selected, app.activity != nil {
            return .skipped("Another operation is running in it.")
        }
        if let failure = await fetch(repo) { return .skipped("Could not fetch. \(failure)") }
        guard let out = try? await git.run(Self.arguments, in: repo) else {
            return .skipped("Could not read its status.")
        }
        let branch = RepoStatus(parsing: out.stdout).branch
        guard branch.head != nil, branch.upstream != nil, branch.behind > 0 else { return nil }
        guard branch.ahead == 0 else {
            return .skipped("Has local commits too. Pull it yourself to merge or rebase them.")
        }
        // git refuses when an uncommitted change touches an incoming file,
        // or a merge is in progress: its decision, not ours.
        do {
            try await git.run(["merge", "--ff-only", "--quiet", "@{upstream}"], in: repo)
            return .pulled(commits: branch.behind)
        } catch {
            return .skipped(error.localizedDescription)
        }
    }
}
