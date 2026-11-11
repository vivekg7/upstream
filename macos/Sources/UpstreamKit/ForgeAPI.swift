import Foundation

// What the app needs from any forge, in its own terms
// (docs/plans/002_forges_github_first.md). "Change request" is the core's
// word, so neither GitHub's "pull request" nor GitLab's "merge request"
// becomes the model; each forge's UI text uses its own.

/// Which forge software an account or repository is on. GitLab and
/// Bitbucket become cases here, each with its own `Forge` implementation.
public enum ForgeKind: String, Codable, Sendable, CaseIterable {
    case github

    /// The forge's own word for a change request, for UI text.
    public var changeRequestName: String { "Pull Request" }

    /// `remoteURL`'s repository if it is on this forge: on its public host
    /// always, on a self-hosted one only when signed in there (`hosts`).
    public func repository(for remoteURL: String, hosts: some Sequence<String>) -> RepoRef? {
        guard let remote = RemoteURL(remoteURL) else { return nil }
        switch self {
        case .github: return GitHub.repository(for: remote, hosts: hosts)
        }
    }

    public func client(for account: Account, token: String, http: HTTP) -> any Forge {
        switch self {
        case .github: GitHub(account: account, token: token, http: http)
        }
    }
}

/// A signed-in account. The token is in the Keychain, never here: this is
/// what may be kept in `UserDefaults`. One account per host, as in GitHub
/// Desktop, so the credential helper never has to choose between two.
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var kind: ForgeKind
    /// As the user gave it: `github.com`, or an Enterprise host, perhaps with a port.
    public var host: String
    public var login: String

    public var id: String { host }
    public var isPublicHost: Bool { host == "github.com" }

    public init(kind: ForgeKind = .github, host: String, login: String) {
        self.kind = kind
        self.host = host
        self.login = login
    }
}

/// A repository on a forge: `github.com` + `owner/name`.
public struct RepoRef: Hashable, Sendable {
    public var kind: ForgeKind
    public var host: String
    public var owner: String
    public var name: String

    public var fullName: String { "\(owner)/\(name)" }

    public init(kind: ForgeKind = .github, host: String, owner: String, name: String) {
        self.kind = kind
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// The forge's page for a commit.
    public func commitURL(_ sha: String) -> URL? {
        URL(string: "https://\(host)/\(fullName)/commit/\(sha)")
    }

    /// The forge's own form for a new change request from `branch` (in
    /// `head`, when that is a fork) into `base`, or the default branch when
    /// `base` is unknown. The form already has templates, reviewers and
    /// labels, so the app does not repeat it (docs/REQUIREMENTS.md).
    public func newChangeRequestURL(branch: String, base: String?, head: RepoRef? = nil) -> URL? {
        let path = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: path) ?? s }
        var from = enc(branch)
        if let head, head != self { from = "\(head.owner):\(from)" }
        let range = base.map { "\(enc($0))...\(from)" } ?? from
        return URL(string: "https://\(host)/\(fullName)/compare/\(range)?expand=1")
    }
}

public enum CIState: String, Sendable, Equatable {
    case pending, success, failure

    /// Failure as soon as anything has failed; otherwise pending while
    /// anything runs; nil when there are no checks at all.
    public init?(combining states: some Sequence<CIState>) {
        var any = false
        var pending = false
        for state in states {
            any = true
            if state == .failure {
                self = .failure
                return
            }
            if state == .pending { pending = true }
        }
        guard any else { return nil }
        self = pending ? .pending : .success
    }
}

/// An open change request: a pull request on GitHub.
public struct ChangeRequest: Identifiable, Sendable, Equatable {
    public var number: Int
    public var title: String
    /// nil when the author's account was deleted.
    public var author: String?
    public var isDraft: Bool
    public var sourceBranch: String
    public var targetBranch: String
    /// From another repository (a fork): checked out from `fetchRef` into
    /// a branch of its own, since its branch is not on our remote.
    public var isFromFork: Bool
    /// The ref on the base repository that holds its head, which works
    /// for forks too: `refs/pull/<n>/head` on GitHub.
    public var fetchRef: String
    public var url: URL?
    /// The CI state of its head commit; nil when it has no checks.
    public var ci: CIState?

    public var id: Int { number }
}

/// One CI check of a commit: a check run or a commit status on GitHub.
public struct Check: Identifiable, Sendable, Equatable {
    public var name: String
    public var state: CIState
    public var url: URL?

    public var id: String { name }

    public init(name: String, state: CIState, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// A repository of the signed-in account, for the clone list.
public struct ForgeRepository: Identifiable, Sendable, Equatable {
    public var fullName: String
    public var cloneURL: String
    public var isPrivate: Bool
    public var description: String?

    public var id: String { cloneURL }
}

/// What one signed-in account can do. Each forge maps its API onto this.
public protocol Forge: Sendable {
    var account: Account { get }
    /// Every repository the account can clone, all pages.
    func repositories() async throws -> [ForgeRepository]
    /// Where a new repository may be created: the account itself first, then its organisations.
    func owners() async throws -> [String]
    func createRepository(owner: String, name: String, description: String, isPrivate: Bool) async throws
        -> ForgeRepository
    func changeRequests(in repo: RepoRef) async throws -> [ChangeRequest]
    func checks(in repo: RepoRef, commit: String) async throws -> [Check]
}

public enum ForgeError: Error, LocalizedError, Equatable {
    /// The token was revoked or expired.
    case unauthorized(host: String)
    case http(status: Int, message: String)
    case missingScope(String)
    case signIn(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let host):
            "\(host) rejected the saved token. Sign in again in Settings → Accounts."
        case .http(let status, let message): message.isEmpty ? "The server answered \(status)." : message
        case .missingScope(let scope): "The token lacks the \(scope) scope."
        case .signIn(let message): message
        }
    }
}

/// A git remote URL taken apart. The git layer never does this: which
/// forge and repository a remote belongs to is the forge layer's question.
public struct RemoteURL: Equatable, Sendable {
    public var scheme: String
    /// Without the port.
    public var host: String
    /// `host:port` as written, which is what git matches credential config against.
    public var authority: String
    /// Without leading or trailing slashes, and without `.git`.
    public var path: String

    /// `https://[user@]host[:port]/path`, `ssh://[user@]host[:port]/path`,
    /// `git://…`, or the scp-like `[user@]host:path`.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        var rest: Substring
        if let r = s.range(of: "://") {
            scheme = s[..<r.lowerBound].lowercased()
            rest = s[r.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var auth = rest[..<slash]
            if let at = auth.lastIndex(of: "@") { auth = auth[auth.index(after: at)...] }
            authority = auth.lowercased()
            host = String(authority.split(separator: ":", maxSplits: 1).first ?? "")
            rest = rest[slash...]
        } else {
            // scp-like: a colon before any slash. A local path has none.
            guard let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") else { return nil }
            scheme = "ssh"
            var auth = s[..<colon]
            if let at = auth.lastIndex(of: "@") { auth = auth[auth.index(after: at)...] }
            host = auth.lowercased()
            authority = host
            rest = s[s.index(after: colon)...]
        }
        var p = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p.hasSuffix(".git") { p.removeLast(4) }
        guard !host.isEmpty, !p.isEmpty else { return nil }
        path = p
    }
}

// MARK: HTTP

/// The forges' HTTP: JSON over `URLSession`, with conditional GETs. A
/// repeated GET sends the last `ETag` as `If-None-Match`; a 304 answers
/// from the copy kept here, and on GitHub costs nothing against the rate
/// limit, which is what makes polling once a minute affordable.
public final class HTTP: Sendable {
    let session: URLSession
    private let cache = ETagCache()

    /// No `URLCache`: it would answer 304s itself and hide them from us.
    public static let live = HTTP(
        session: {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }())

    public init(session: URLSession) { self.session = session }

    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        public var headers: [String: String]
        /// Answered by a 304 from the kept copy.
        public var notModified = false

        public func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Sends `request`. A GET is conditional when an earlier answer to the
    /// same URL carried an `ETag`. Statuses are the caller's to judge.
    public func send(_ request: URLRequest) async throws -> Response {
        var request = request
        let key = request.url?.absoluteString ?? ""
        let conditional = request.httpMethod == nil || request.httpMethod == "GET"
        let kept = conditional ? await cache.get(key) : nil
        if let kept { request.setValue(kept.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
        var answer = Response(data: data, status: http.statusCode, headers: headers)
        if http.statusCode == 304, let kept {
            answer.data = kept.data
            answer.status = 200
            answer.notModified = true
        } else if conditional, http.statusCode == 200, let etag = answer.header("ETag") {
            await cache.set(key, etag: etag, data: data)
        }
        return answer
    }

    /// Forgets every kept answer, as on sign-out.
    public func forget() async { await cache.clear() }
}

private actor ETagCache {
    private var entries: [String: (etag: String, data: Data)] = [:]

    func get(_ key: String) -> (etag: String, data: Data)? { entries[key] }

    func set(_ key: String, etag: String, data: Data) {
        // The keys are per commit, so they only accumulate; a few dozen
        // cover the polling, and starting over costs one full answer each.
        if entries.count >= 64 { entries.removeAll() }
        entries[key] = (etag, data)
    }

    func clear() { entries.removeAll() }
}
