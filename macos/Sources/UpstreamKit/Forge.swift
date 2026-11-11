import Foundation
import Observation
import UserNotifications

/// The signed-in forges: accounts, pull requests and CI
/// (docs/plans/002_forges_github_first.md).
///
/// Network budget. Nothing is sent while signed out. While the app is in
/// front, the current branch's checks are asked for about once a minute,
/// with conditional GETs that cost nothing once they settle; the pull
/// request list is read when a repository is opened, when the app comes to
/// the front and when its popover opens, never on a timer. In the
/// background only a pending check on the current branch is followed, for
/// the notification, and that stops when it settles.
@MainActor @Observable
public final class ForgeModel: Feature {
    public weak var app: AppModel? { didSet { loadAccounts() } }

    public internal(set) var accounts: [Account] = []
    /// The selected repository's remotes in config order; nil until read.
    public private(set) var remotes: [Remote]?
    /// The selected repository on its forge, from `origin` if it is on
    /// one, else the first remote that is. Change requests are read here.
    public private(set) var repo: RepoRef?
    public private(set) var remoteName: String?
    /// nil until read, and while signed out of `repo`'s host.
    public private(set) var changeRequests: [ChangeRequest]?
    /// The current branch's checks; nil when not pushed or not known.
    public private(set) var checks: [Check]?
    /// Why the last background request failed, for the toolbar's tooltip:
    /// a failed poll is not worth the error banner.
    public private(set) var problem: String?
    /// Set by the menu or the toolbar; the window shows the publish sheet.
    public var isPublishing = false
    /// The code to enter in the browser while a device-flow sign-in waits.
    public private(set) var deviceCode: GitHub.DeviceCode?

    public struct Remote: Equatable, Sendable {
        public var name: String
        public var url: String
    }

    @ObservationIgnored var store: any TokenStore = Keychain()
    @ObservationIgnored var http = HTTP.live
    /// How git is to run this app as its credential helper.
    @ObservationIgnored var helperCommand = ForgeModel.ownHelperCommand
    /// Tokens read from the Keychain once per run, so a Keychain that asks
    /// before handing one out asks once, not on every poll.
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var lastChecks: ContinuousClock.Instant?
    @ObservationIgnored private var lastChangeRequests: ContinuousClock.Instant?
    @ObservationIgnored private var checksCommit: String?
    /// One minute, doubling after each failure up to fifteen, so an outage
    /// or a rate limit is not hammered.
    @ObservationIgnored private var interval = ForgeModel.pollInterval
    nonisolated static let pollInterval = Duration.seconds(60)

    nonisolated init() {}

    nonisolated static let ownHelperCommand: String = {
        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return CredentialHelper.command(executable: URL(fileURLWithPath: exe).standardizedFileURL.path)
    }()

    // MARK: Accounts

    private static let accountsKey = "forgeAccounts"

    private func loadAccounts() {
        guard let data = app?.defaults.data(forKey: Self.accountsKey) else { return }
        accounts = (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    private func saveAccounts() {
        accounts.sort { $0.host < $1.host }
        app?.defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.accountsKey)
    }

    public func account(for host: String) -> Account? { accounts.first { $0.host == host } }

    private func client(for account: Account) -> (any Forge)? {
        if tokens[account.host] == nil { tokens[account.host] = store.token(for: account.host)?.token }
        return tokens[account.host].map { account.kind.client(for: account, token: $0, http: http) }
    }

    /// The repository a remote URL points at, on whichever forge knows it.
    func repository(for remoteURL: String) -> RepoRef? {
        ForgeKind.allCases.lazy.compactMap { kind in
            kind.repository(for: remoteURL, hosts: self.accounts.filter { $0.kind == kind }.map(\.host))
        }.first
    }

    private func client(for repo: RepoRef) -> (any Forge)? { account(for: repo.host).flatMap(client(for:)) }

    /// `https://ghe.example.com/` → `ghe.example.com`.
    public static func host(from input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        return String(s.split(separator: "/").first ?? "")
    }

    /// Checks `token` with the forge, then keeps it in the Keychain. An
    /// account already on the host is replaced: one per host.
    public func signIn(host: String, token: String) async throws {
        let host = Self.host(from: host)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = try await GitHub.login(token: token, host: host, http: http)
        try store.save(token, login: login, host: host)
        tokens[host] = token
        accounts.removeAll { $0.host == host }
        accounts.append(Account(host: host, login: login))
        saveAccounts()
        problem = nil
        await resolve()
    }

    /// The device flow on github.com: shows `deviceCode` until the user
    /// approves it in the browser. Cancelling the task stops it.
    public func signInWithBrowser() async throws {
        defer { deviceCode = nil }
        let code = try await GitHub.startDeviceFlow(http: http)
        deviceCode = code
        let token = try await GitHub.finishDeviceFlow(code, http: http)
        try await signIn(host: "github.com", token: token)
    }

    /// Forgets the account and deletes its token from the Keychain. The
    /// token itself stays valid on the forge until the user revokes it
    /// there; the settings say so.
    public func signOut(_ account: Account) {
        store.delete(host: account.host)
        tokens[account.host] = nil
        accounts.removeAll { $0.host == account.host }
        saveAccounts()
        Task { [http] in await http.forget() }
        if repo?.host == account.host {
            poller?.cancel()
            changeRequests = nil
            checks = nil
            problem = nil
        }
    }

    // MARK: The selected repository

    func repositoryChanged() {
        poller?.cancel()
        (remotes, repo, remoteName, changeRequests, checks, problem) = (nil, nil, nil, nil, nil, nil)
        (checksCommit, lastChecks, lastChangeRequests) = (nil, nil, nil)
        Task { await resolve() }
    }

    func activeChanged(_ active: Bool) {
        // Going to the background needs nothing: the poller sees it and
        // stops unless a check is pending.
        guard active else { return }
        Task { await resolve() }
    }

    /// HEAD, the branch or its upstream moved: a push, a commit, a switch.
    func headChanged() {
        lastChecks = nil
        startPolling()
    }

    /// Reads the remotes again (they may have been added in a terminal),
    /// then catches up on what is older than a minute.
    private func resolve() async {
        guard let app, let git = app.git, let dir = app.selected else { return }
        let found = await Self.remotes(git: git, in: dir)
        guard dir == app.selected else { return }
        if found != remotes { remotes = found }
        let ordered = found.filter { $0.name == "origin" } + found.filter { $0.name != "origin" }
        let match = ordered.lazy.compactMap { r in self.repository(for: r.url).map { (r.name, $0) } }.first
        if match?.1 != repo {
            (repo, remoteName, changeRequests, checks) = (match?.1, match?.0, nil, nil)
            lastChangeRequests = nil
        }
        await refreshChangeRequests()
        startPolling()
    }

    /// `git config -z --get-regexp`: `key\nvalue\0` per entry, in config
    /// order. Not `git remote -v`, which is for people.
    static func remotes(git: Git, in dir: URL) async -> [Remote] {
        guard
            let out = try? await git.run(
                ["config", "-z", "--get-regexp", #"^remote\..*\.url$"#], in: dir, allowedExitCodes: [0, 1])
        else { return [] }
        return out.stdout.split(separator: 0).compactMap { entry in
            let s = String(decoding: entry, as: UTF8.self)
            guard let nl = s.firstIndex(of: "\n") else { return nil }
            let key = s[..<nl]
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { return nil }
            return Remote(name: String(key.dropFirst(7).dropLast(4)), url: String(s[s.index(after: nl)...]))
        }
    }

    private func config(_ key: String, in dir: URL) async -> String? {
        guard let git = app?.git,
            let out = try? await git.run(["config", "--get", key], in: dir, allowedExitCodes: [0, 1])
        else { return nil }
        let value = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The forge's page for a commit of the selected repository. No network:
    /// it works signed out, for any GitHub remote.
    public func webURL(commit: String) async -> URL? {
        if remotes == nil { await resolve() }
        return repo?.commitURL(commit)
    }

    // MARK: Credentials for git

    /// `-c credential.https://<host>.helper=…` for a remote (a name or a URL)
    /// on a signed-in host, so HTTPS git operations use the account's token;
    /// empty otherwise, and always for SSH, which uses the user's own keys.
    ///
    /// The empty helper first resets the helper list for that host. Without
    /// it a global helper such as `osxkeychain` is asked first and its old
    /// password wins: git asks helpers in config order, and `-c` comes last
    /// (tested in ForgeTests).
    public func credentialArguments(in dir: URL, remote: String) async -> [String] {
        guard !accounts.isEmpty else { return [] }
        var urls = [remote]
        if RemoteURL(remote) == nil {
            // A name: its push URL too, when it has one.
            urls = [
                await config("remote.\(remote).url", in: dir),
                await config("remote.\(remote).pushurl", in: dir),
            ]
            .compactMap { $0 }
        }
        var args: [String] = []
        var seen: Set<String> = []
        for case let url? in urls.map(RemoteURL.init) where url.scheme == "https" {
            guard accounts.contains(where: { $0.host == url.authority || $0.host == url.host }),
                seen.insert(url.authority).inserted
            else { continue }
            let key = "credential.https://\(url.authority).helper"
            args += ["-c", "\(key)=", "-c", "\(key)=\(helperCommand)"]
        }
        return args
    }

    // MARK: Polling

    private var isActive: Bool { app?.isActive ?? false }
    private var checksPending: Bool { checks?.contains { $0.state == .pending } ?? false }

    /// Polls the current branch's checks, about once a minute, while the
    /// app is in front or a check is pending; nothing when signed out.
    private func startPolling() {
        poller?.cancel()
        guard let repo, account(for: repo.host) != nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = lastChecks.map { $0 + interval } ?? .now
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, isActive || checksPending else { return }
                await refreshChecks()
            }
        }
    }

    private func refreshChecks() async {
        lastChecks = .now
        guard let app, let dir = app.selected, let branch = app.status?.branch, let head = branch.head,
            let sha = branch.oid, branch.upstream != nil, branch.ahead == 0
        else {
            checks = nil  // not pushed: the forge has nothing to say about HEAD
            return
        }
        // The branch's own remote, which may be a fork rather than `repo`.
        let pushed = await config("branch.\(head).remote", in: dir).flatMap { name in
            remotes?.first { $0.name == name }
        }
        let target = pushed.flatMap { repository(for: $0.url) } ?? repo
        guard let target, let client = client(for: target) else { return }
        do {
            let fresh = try await client.checks(in: target, commit: sha)
            guard dir == app.selected, sha == app.status?.branch.oid else { return }
            interval = Self.pollInterval
            problem = nil
            settle(fresh, commit: sha, branch: head)
        } catch {
            failed(error)
        }
    }

    /// Takes a fresh list of checks, and notifies when the ones that were
    /// running on this commit have all finished.
    func settle(_ fresh: [Check], commit: String, branch: String) {
        let wasPending = checksCommit == commit && checksPending
        if fresh != checks { checks = fresh }
        checksCommit = commit
        if checksPending {
            askToNotify()
        } else if wasPending, !fresh.isEmpty {
            let failed = fresh.filter { $0.state == .failure }.count
            notify(
                failed == 0 ? "Checks passed" : "Checks failed",
                failed == 0
                    ? "All \(fresh.count) checks passed on \(branch)."
                    : "\(failed) of \(fresh.count) checks failed on \(branch).")
        }
    }

    private func failed(_ error: Error) {
        if case ForgeError.unauthorized = error {
            poller?.cancel()  // until the user signs in again
        } else {
            interval = min(interval * 2, .seconds(15 * 60))
        }
        // Offline is not news.
        if (error as? URLError)?.code != .notConnectedToInternet { problem = error.localizedDescription }
    }

    /// The open change requests of `repo`, read at most once per half
    /// minute however often the popover opens.
    public func refreshChangeRequests(force: Bool = false) async {
        guard let repo, let client = client(for: repo) else { return }
        if !force, let last = lastChangeRequests, last + .seconds(30) > .now { return }
        lastChangeRequests = .now
        do {
            let fresh = try await client.changeRequests(in: repo)
            guard repo == self.repo else { return }
            if fresh != changeRequests { changeRequests = fresh }
        } catch {
            failed(error)
        }
    }

    // MARK: Notifications

    /// Only a real app bundle may use the notification center: the bare
    /// debug executable and the test runner crash in it.
    private var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    @ObservationIgnored private var askedToNotify = false

    /// Asked the first time a check is seen running, not at launch: someone
    /// who never signs in is never asked.
    private func askToNotify() {
        guard canNotify, !askedToNotify else { return }
        askedToNotify = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// macOS shows it only while the app is in the background, where it is
    /// needed; in front, the toolbar already says it.
    private func notify(_ title: String, _ body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "checks", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    // MARK: Actions

    /// Every signed-in account's repositories, for the clone list.
    public func repositories() async throws -> [ForgeRepository] {
        var all: [ForgeRepository] = []
        for account in accounts {
            guard let client = client(for: account) else { continue }
            all += try await client.repositories()
        }
        return all
    }

    public func owners(for account: Account) async throws -> [String] {
        try await client(for: account)?.owners() ?? [account.login]
    }

    /// Publishes the selected repository: creates it on the forge, adds it
    /// as `origin` and pushes the current branch to it, tracking.
    @discardableResult
    public func publish(account: Account, owner: String, name: String, description: String, isPrivate: Bool)
        async -> Bool
    {
        guard let app, let client = client(for: account) else { return false }
        let ok = await app.perform("Publishing…") { git, dir in
            let created = try await client.createRepository(
                owner: owner, name: name, description: description, isPrivate: isPrivate)
            try await git.run(["remote", "add", "origin", created.cloneURL], in: dir)
            let net = await credentialArguments(in: dir, remote: "origin")
            try await git.run(net + ["push", "-u", "origin", "HEAD"], in: dir)
        }
        await resolve()
        return ok
    }

    /// Checks out a change request. One from this repository becomes its
    /// own branch, tracking it, so pushing works as for any branch. One
    /// from a fork is fetched from the base repository's
    /// `refs/pull/<n>/head` into `pr/<n>`, so no remote is added for the
    /// fork. The fetch is never forced: when the author rewrote the branch
    /// and the local one has commits of its own, git refuses rather than
    /// drop them.
    public func checkOut(_ request: ChangeRequest) async {
        guard let app, let remote = remoteName else { return }
        let current = app.status?.branch.head
        await app.perform("Checking out #\(request.number)…") { git, dir in
            let net = await credentialArguments(in: dir, remote: remote)
            let local = request.isFromFork ? "pr/\(request.number)" : request.sourceBranch
            if request.isFromFork {
                if current == local {
                    try await git.run(net + ["fetch", remote, request.fetchRef], in: dir)
                    try await git.run(["merge", "--ff-only", "FETCH_HEAD"], in: dir)
                } else {
                    try await git.run(
                        net + ["fetch", remote, "\(request.fetchRef):refs/heads/\(local)"], in: dir)
                    try await git.run(["switch", local], in: dir)
                }
            } else {
                let tracking = "refs/remotes/\(remote)/\(local)"
                let exists =
                    (try? await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(local)"], in: dir))
                    != nil
                try await git.run(net + ["fetch", remote, "+refs/heads/\(local):\(tracking)"], in: dir)
                try await git.run(
                    exists ? ["switch", local] : ["switch", "-c", local, "--track", tracking], in: dir)
            }
        }
    }

    /// Why "Create Pull Request" cannot be used now, or nil when it can.
    public var newChangeRequestBlocker: String? {
        guard repo != nil else { return "The repository has no remote on GitHub." }
        guard let branch = app?.status?.branch, branch.head != nil else { return "Switch to a branch first." }
        guard branch.upstream != nil else { return "Push the branch first." }
        return nil
    }

    /// The forge's form for a new change request from the current branch
    /// into the default branch. Needs no sign-in: it opens in the browser.
    public func newChangeRequestURL() async -> URL? {
        guard newChangeRequestBlocker == nil, let app, let dir = app.selected, let repo,
            let head = app.status?.branch.head
        else { return nil }
        let pushRemote = await config("branch.\(head).remote", in: dir)
        let merge = await config("branch.\(head).merge", in: dir)
        let branch = merge.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 } ?? head
        let fork = pushRemote.flatMap { name in remotes?.first { $0.name == name } }
            .flatMap { repository(for: $0.url) }
        // The default branch as the last fetch saw it; GitHub's own default otherwise.
        let prefix = "refs/remotes/\(remoteName ?? "origin")/"
        let base =
            (try? await app.git?.run(["symbolic-ref", "-q", "\(prefix)HEAD"], in: dir, allowedExitCodes: [0]))
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        return repo.newChangeRequestURL(branch: branch, base: base, head: fork)
    }
}
