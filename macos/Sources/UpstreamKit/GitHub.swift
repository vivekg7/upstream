import Foundation

/// GitHub and GitHub Enterprise Server: REST for most things, one GraphQL
/// query for the pull requests with their CI state, since REST needs a
/// call per pull request for that (docs/plans/002_forges_github_first.md).
public struct GitHub: Forge {
    public let account: Account
    let token: String
    let http: HTTP

    /// The OAuth App's client ID for the device flow on github.com. Empty
    /// until the App is registered (002, open questions); while it is, the
    /// browser sign-in is disabled and a personal access token is the way in.
    /// A client ID is not a secret: the device flow has none.
    public static let clientID = ""
    /// `repo` to read private repositories, push over HTTPS and create
    /// repositories; `workflow` to push changes to `.github/workflows`,
    /// which `repo` alone is refused; `read:org` to list the organisations
    /// a repository can be published to.
    public static let scopes = ["repo", "workflow", "read:org"]

    static func api(_ host: String) -> String {
        host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3"
    }

    static func graphQL(_ host: String) -> String {
        host == "github.com" ? "https://api.github.com/graphql" : "https://\(host)/api/graphql"
    }

    /// Where to create a classic token with the right scopes, prefilled.
    public static func newTokenURL(host: String) -> URL? {
        URL(
            string:
                "https://\(host)/settings/tokens/new?scopes=\(scopes.joined(separator: ","))&description=Upstream"
        )
    }

    /// github.com always, signed out too, so a commit's web link works for
    /// any GitHub remote; an Enterprise host only when an account is on it.
    static func repository(for remote: RemoteURL, hosts: some Sequence<String>) -> RepoRef? {
        let parts = remote.path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        // GitHub's SSH over port 443 (ssh://git@ssh.github.com:443/…).
        let host = remote.host == "ssh.github.com" ? "github.com" : remote.host
        let known =
            host == "github.com"
            ? "github.com"
            : hosts.first {
                $0 == remote.authority || $0.split(separator: ":").first.map(String.init) == host
            }
        guard let known else { return nil }
        return RepoRef(host: known, owner: String(parts[0]), name: String(parts[1]))
    }

    // MARK: Requests

    private func request(_ url: String, method: String = "GET", json: [String: Any]? = nil) throws
        -> URLRequest
    {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ url: String, method: String = "GET", json: [String: Any]? = nil) async throws
        -> HTTP.Response
    {
        let response = try await http.send(try request(url, method: method, json: json))
        try Self.check(response, host: account.host)
        return response
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(url).data)
    }

    /// Throws for anything but a 2xx, with GitHub's own message.
    static func check(_ response: HTTP.Response, host: String) throws {
        guard !(200..<300).contains(response.status) else { return }
        if response.status == 401 { throw ForgeError.unauthorized(host: host) }
        struct Message: Decodable {
            struct Detail: Decodable { var message: String? }
            var message: String?
            var errors: [Detail]?
        }
        let body = try? JSONDecoder().decode(Message.self, from: response.data)
        let parts = [body?.message] + (body?.errors ?? []).map(\.message)
        throw ForgeError.http(
            status: response.status, message: parts.compactMap { $0 }.joined(separator: " "))
    }

    /// Every page of a list, following the `Link` header's `rel="next"`.
    private func pages<T: Decodable>(_ type: T.Type, _ url: String) async throws -> [T] {
        var all: [T] = []
        var next: String? = url
        while let url = next {
            let response = try await send(url)
            all += try JSONDecoder().decode([T].self, from: response.data)
            next = Self.nextPage(response.header("Link"))
        }
        return all
    }

    /// `<https://…?page=2>; rel="next", <…>; rel="last"` → the first URL.
    static func nextPage(_ link: String?) -> String? {
        for part in (link ?? "").split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">") else { continue }
            return String(part[part.index(after: open)..<close])
        }
        return nil
    }

    // MARK: Signing in

    /// The login a token belongs to. A classic or OAuth token names its
    /// scopes in `X-OAuth-Scopes`, and one without `repo` cannot push, so
    /// it is refused now rather than on the first push. Fine-grained tokens
    /// send no such header and are taken on trust.
    public static func login(token: String, host: String, http: HTTP) async throws -> String {
        let probe = GitHub(account: Account(host: host, login: ""), token: token, http: http)
        let response = try await probe.send("\(api(host))/user")
        if let scopes = response.header("X-OAuth-Scopes") {
            let granted = Set(scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            if !granted.contains("repo") { throw ForgeError.missingScope("repo") }
        }
        struct User: Decodable { var login: String }
        return try JSONDecoder().decode(User.self, from: response.data).login
    }

    public struct DeviceCode: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        public var interval: Int
    }

    /// The OAuth device flow, step one: a code for the user to enter in
    /// the browser. Needs no client secret, so none is in the app.
    public static func startDeviceFlow(host: String = "github.com", http: HTTP) async throws -> DeviceCode {
        struct Answer: Decodable {
            var device_code: String
            var user_code: String
            var verification_uri: String
            var interval: Int?
        }
        let data = try await form(
            "https://\(host)/login/device/code",
            ["client_id": clientID, "scope": scopes.joined(separator: " ")],
            http: http)
        let a = try JSONDecoder().decode(Answer.self, from: data)
        guard let url = URL(string: a.verification_uri) else { throw URLError(.badURL) }
        return DeviceCode(
            deviceCode: a.device_code, userCode: a.user_code, verificationURL: url, interval: a.interval ?? 5)
    }

    /// Step two: asks for the token at the interval GitHub set, slowing
    /// down when told to, until the user approves, refuses, or the code
    /// expires.
    public static func finishDeviceFlow(
        _ code: DeviceCode, host: String = "github.com", http: HTTP,
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        struct Answer: Decodable {
            var access_token: String?
            var error: String?
            var error_description: String?
            var interval: Int?
        }
        var interval = code.interval
        while true {
            try await sleep(.seconds(interval))
            let data = try await form(
                "https://\(host)/login/oauth/access_token",
                [
                    "client_id": clientID, "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ], http: http)
            let a = try JSONDecoder().decode(Answer.self, from: data)
            if let token = a.access_token { return token }
            switch a.error {
            case "authorization_pending": continue
            case "slow_down": interval = a.interval ?? interval + 5
            case "access_denied": throw ForgeError.signIn("Sign-in was declined in the browser.")
            case "expired_token": throw ForgeError.signIn("The code expired. Start again.")
            default: throw ForgeError.signIn(a.error_description ?? a.error ?? "Sign-in failed.")
            }
        }
    }

    private static func form(_ url: String, _ fields: [String: String], http: HTTP) async throws -> Data {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let response = try await http.send(r)
        try check(response, host: u.host() ?? url)
        return response.data
    }

    // MARK: Forge

    private struct Repo: Decodable {
        var full_name: String
        var clone_url: String
        var `private`: Bool
        var description: String?

        var model: ForgeRepository {
            ForgeRepository(
                fullName: full_name, cloneURL: clone_url, isPrivate: `private`, description: description)
        }
    }

    public func repositories() async throws -> [ForgeRepository] {
        try await pages(Repo.self, "\(Self.api(account.host))/user/repos?per_page=100&sort=full_name").map(
            \.model)
    }

    public func owners() async throws -> [String] {
        struct Org: Decodable { var login: String }
        let orgs = try await pages(Org.self, "\(Self.api(account.host))/user/orgs?per_page=100")
        return [account.login] + orgs.map(\.login)
    }

    public func createRepository(owner: String, name: String, description: String, isPrivate: Bool)
        async throws
        -> ForgeRepository
    {
        let path = owner == account.login ? "/user/repos" : "/orgs/\(owner)/repos"
        let response = try await send(
            Self.api(account.host) + path, method: "POST",
            json: ["name": name, "description": description, "private": isPrivate])
        return try JSONDecoder().decode(Repo.self, from: response.data).model
    }

    /// The open pull requests, newest activity first, each with its head
    /// commit's status rollup: checks and commit statuses in one state.
    static let pullRequestsQuery = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title isDraft url isCrossRepository headRefName baseRefName
                author { login }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
        }
        """

    public func changeRequests(in repo: RepoRef) async throws -> [ChangeRequest] {
        let response = try await send(
            Self.graphQL(account.host), method: "POST",
            json: ["query": Self.pullRequestsQuery, "variables": ["owner": repo.owner, "name": repo.name]])
        return try Self.changeRequests(from: response.data)
    }

    static func changeRequests(from data: Data) throws -> [ChangeRequest] {
        struct Answer: Decodable {
            struct Message: Decodable { var message: String }
            struct Body: Decodable { var repository: Repository? }
            struct Repository: Decodable { var pullRequests: Connection<PR> }
            struct Connection<T: Decodable>: Decodable { var nodes: [T?] }
            struct PR: Decodable {
                var number: Int
                var title: String
                var isDraft: Bool
                var url: String?
                var isCrossRepository: Bool
                var headRefName: String
                var baseRefName: String
                var author: Login?
                var commits: Connection<CommitNode>
            }
            struct Login: Decodable { var login: String }
            struct CommitNode: Decodable { var commit: Commit }
            struct Commit: Decodable { var statusCheckRollup: Rollup? }
            struct Rollup: Decodable { var state: String }
            var data: Body?
            var errors: [Message]?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        // GraphQL answers 200 with `errors` for a repository it cannot see.
        guard let repository = answer.data?.repository else {
            throw ForgeError.http(
                status: 200, message: answer.errors?.map(\.message).joined(separator: " ") ?? "")
        }
        return repository.pullRequests.nodes.compactMap { $0 }.map { pr in
            let rollup = pr.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
            return ChangeRequest(
                number: pr.number, title: pr.title, author: pr.author?.login, isDraft: pr.isDraft,
                sourceBranch: pr.headRefName, targetBranch: pr.baseRefName, isFromFork: pr.isCrossRepository,
                fetchRef: "refs/pull/\(pr.number)/head", url: pr.url.flatMap(URL.init(string:)),
                ci: rollup.flatMap(Self.state(rollup:)))
        }
    }

    /// A hundred repositories to a query, one alias each (`r0`, `r1`, …),
    /// so a sidebar of any size costs a request or two per launch rather
    /// than a GET per repository. Names go in variables, never into the
    /// query text.
    public func privacy(of repos: [RepoRef]) async throws -> [RepoRef: Bool] {
        var found: [RepoRef: Bool] = [:]
        for start in stride(from: 0, to: repos.count, by: 100) {
            let chunk = Array(repos[start..<min(start + 100, repos.count)])
            let response = try await send(
                Self.graphQL(account.host), method: "POST", json: Self.privacyQuery(chunk))
            for (i, isPrivate) in try Self.privacy(from: response.data) where i < chunk.count {
                found[chunk[i]] = isPrivate
            }
        }
        return found
    }

    static func privacyQuery(_ repos: [RepoRef]) -> [String: Any] {
        var parameters: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]
        for (i, repo) in repos.enumerated() {
            parameters += ["$o\(i): String!", "$n\(i): String!"]
            fields.append("r\(i): repository(owner: $o\(i), name: $n\(i)) { isPrivate }")
            (variables["o\(i)"], variables["n\(i)"]) = (repo.owner, repo.name)
        }
        return [
            "query": "query(\(parameters.joined(separator: ", "))) { \(fields.joined(separator: " ")) }",
            "variables": variables,
        ]
    }

    /// Alias index → isPrivate. A repository GraphQL cannot see (deleted,
    /// never shared with the account, behind SSO) is null beside an entry in
    /// `errors`, and is left out; only an answer with no data at all throws.
    static func privacy(from data: Data) throws -> [Int: Bool] {
        struct Answer: Decodable {
            struct Message: Decodable { var message: String }
            struct Repository: Decodable { var isPrivate: Bool }
            var data: [String: Repository?]?
            var errors: [Message]?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        guard let repositories = answer.data else {
            throw ForgeError.http(
                status: 200, message: answer.errors?.map(\.message).joined(separator: " ") ?? "")
        }
        var found: [Int: Bool] = [:]
        for (alias, repository) in repositories {
            guard alias.hasPrefix("r"), let i = Int(alias.dropFirst()), let repository else { continue }
            found[i] = repository.isPrivate
        }
        return found
    }

    /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED.
    static func state(rollup: String) -> CIState? {
        switch rollup {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .pending
        default: nil
        }
    }

    /// A commit's checks: its check runs (Actions and other apps) and its
    /// commit statuses (older CI services), which GitHub keeps apart. Both
    /// GETs are conditional, so polling a settled commit costs two 304s.
    public func checks(in repo: RepoRef, commit: String) async throws -> [Check] {
        let base = "\(Self.api(account.host))/repos/\(repo.fullName)/commits/\(commit)"
        async let runs = send("\(base)/check-runs?per_page=100")
        async let statuses = send("\(base)/status?per_page=100")
        return try Self.checks(runs: try await runs.data, statuses: try await statuses.data)
    }

    static func checks(runs: Data, statuses: Data) throws -> [Check] {
        struct Runs: Decodable {
            struct Run: Decodable {
                var name: String
                var status: String
                var conclusion: String?
                var html_url: String?
                var details_url: String?
            }
            var check_runs: [Run]
        }
        struct Combined: Decodable {
            struct Status: Decodable {
                var context: String
                var state: String
                var target_url: String?
            }
            var statuses: [Status]
        }
        let r = try JSONDecoder().decode(Runs.self, from: runs).check_runs.map { run in
            let state: CIState =
                switch (run.status, run.conclusion) {
                case ("completed", "success"), ("completed", "neutral"), ("completed", "skipped"): .success
                case ("completed", _): .failure  // failure, cancelled, timed_out, action_required, stale
                default: .pending  // queued, in_progress, waiting, requested
                }
            return Check(
                name: run.name, state: state,
                url: (run.html_url ?? run.details_url).flatMap(URL.init(string:)))
        }
        let s = try JSONDecoder().decode(Combined.self, from: statuses).statuses.map { status in
            Check(
                name: status.context,
                state: status.state == "success" ? .success : status.state == "pending" ? .pending : .failure,
                url: status.target_url.flatMap(URL.init(string:)))
        }
        let order: [CIState: Int] = [.failure: 0, .pending: 1, .success: 2]
        return (r + s).sorted {
            (order[$0.state]!, $0.name.localizedLowercase) < (order[$1.state]!, $1.name.localizedLowercase)
        }
    }
}
