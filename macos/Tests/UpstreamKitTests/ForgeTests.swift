import Foundation
import Synchronization
import Testing

@testable import UpstreamKit

// The forge layer (docs/plans/002_forges_github_first.md). The network is a
// URLProtocol stub serving JSON in the shape GitHub sends; no test reaches
// GitHub, and none touches the Keychain or uses a real token.

// MARK: Which repository a remote is

@Test func remoteURLsInEveryFormGitAccepts() {
    func repo(_ url: String, _ hosts: [String] = []) -> String? {
        ForgeKind.github.repository(for: url, hosts: hosts).map { "\($0.host) \($0.fullName)" }
    }
    #expect(repo("git@github.com:octo/hello.git") == "github.com octo/hello")
    #expect(repo("github.com:octo/hello") == "github.com octo/hello")
    #expect(repo("ssh://git@github.com:22/octo/hello") == "github.com octo/hello")
    #expect(repo("ssh://git@ssh.github.com:443/octo/hello.git") == "github.com octo/hello")
    #expect(repo("https://someone:secret@github.com/octo/hello.git") == "github.com octo/hello")
    #expect(repo("https://GitHub.com/octo/hello/") == "github.com octo/hello")
    // Enterprise only when signed in there, port or not.
    #expect(repo("https://ghe.example.com/team/app.git") == nil)
    #expect(repo("https://ghe.example.com/team/app.git", ["ghe.example.com"]) == "ghe.example.com team/app")
    #expect(
        repo("git@ghe.example.com:team/app.git", ["ghe.example.com:8443"]) == "ghe.example.com:8443 team/app")
    // Not GitHub, not a repository, not a URL.
    #expect(repo("https://gitlab.com/group/sub/app.git") == nil)
    #expect(repo("https://github.com/octo") == nil)
    #expect(repo("/Users/me/hello") == nil)
    #expect(repo("../hello") == nil)
    #expect(repo("file:///tmp/hello") == nil)

    let withPort = RemoteURL("https://ghe.example.com:8443/team/app")
    #expect(withPort?.host == "ghe.example.com")
    #expect(withPort?.authority == "ghe.example.com:8443")
}

@Test func theNewPullRequestFormEscapesTheBranchAndNamesAForkOwner() {
    let repo = RepoRef(host: "github.com", owner: "octo", name: "hello")
    #expect(
        repo.newChangeRequestURL(branch: "fix/#12", base: "main")?.absoluteString
            == "https://github.com/octo/hello/compare/main...fix/%2312?expand=1")
    let fork = RepoRef(host: "github.com", owner: "me", name: "hello")
    #expect(
        repo.newChangeRequestURL(branch: "topic", base: nil, head: fork)?.absoluteString
            == "https://github.com/octo/hello/compare/me:topic?expand=1")
}

// MARK: Decoding GitHub's answers

private let pullRequestsJSON = Data(
    """
    {"data":{"repository":{"pullRequests":{"nodes":[
      {"number":12,"title":"Add the clone list","isDraft":false,"url":"https://github.com/octo/hello/pull/12",
       "isCrossRepository":false,"headRefName":"clone-list","baseRefName":"main","author":{"login":"octocat"},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
      {"number":11,"title":"Fix a typo","isDraft":true,"url":"https://github.com/octo/hello/pull/11",
       "isCrossRepository":true,"headRefName":"patch-1","baseRefName":"main","author":null,
       "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
      {"number":10,"title":"Waiting on CI","isDraft":false,"url":null,
       "isCrossRepository":false,"headRefName":"ci","baseRefName":"main","author":{"login":"hubot"},
       "commits":{"nodes":[]}},
      null
    ]}}}}
    """.utf8)

@Test func pullRequestsWithTheirRollupAndNullFields() throws {
    let prs = try GitHub.changeRequests(from: pullRequestsJSON)
    #expect(prs.map(\.number) == [12, 11, 10])
    #expect(prs[0].ci == .failure)
    #expect(prs[0].author == "octocat")
    #expect(!prs[0].isFromFork)
    // A deleted author, no checks, a fork, a draft.
    #expect(prs[1].author == nil)
    #expect(prs[1].ci == nil)
    #expect(prs[1].isFromFork && prs[1].isDraft)
    #expect(prs[1].fetchRef == "refs/pull/11/head")
    #expect(prs[2].ci == nil && prs[2].url == nil)
    #expect(GitHub.state(rollup: "EXPECTED") == .pending)
    #expect(GitHub.state(rollup: "ERROR") == .failure)
}

@Test func aRepositoryGraphQLCannotSeeIsAnErrorNotAnEmptyList() {
    let json = Data(
        #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository."}]}"#
            .utf8)
    #expect(throws: ForgeError.http(status: 200, message: "Could not resolve to a Repository.")) {
        try GitHub.changeRequests(from: json)
    }
}

@Test func factsKeepWhatGraphQLCouldSeeAndPutNamesInVariables() throws {
    // Shape from GitHub: a repository it cannot see is null beside an error,
    // and one never pushed to has a null pushedAt.
    let json = Data(
        #"{"data":{"r0":{"isPrivate":true,"pushedAt":"2026-11-12T08:30:00Z"},"r1":null,"r2":{"isPrivate":false,"pushedAt":null}},"errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve to a Repository with the name 'octo/gone'."}]}"#
            .utf8)
    #expect(
        try GitHub.facts(from: json) == [
            0: RepoFacts(isPrivate: true, pushedAt: Date(timeIntervalSince1970: 1_794_472_200)),
            2: RepoFacts(isPrivate: false, pushedAt: nil),
        ])
    #expect(throws: ForgeError.self) {
        try GitHub.facts(from: Data(#"{"errors":[{"message":"Bad query"}]}"#.utf8))
    }
    let query = GitHub.factsQuery([RepoRef(host: "github.com", owner: "o\"x", name: "n")])
    #expect(!(query["query"] as! String).contains("o\"x"))
    #expect(query["variables"] as! [String: String] == ["o0": "o\"x", "n0": "n"])
}

private let checkRunsJSON = Data(
    """
    {"total_count":3,"check_runs":[
      {"name":"build","status":"completed","conclusion":"success","html_url":"https://github.com/octo/hello/runs/1"},
      {"name":"test","status":"completed","conclusion":"timed_out","html_url":"https://github.com/octo/hello/runs/2"},
      {"name":"lint","status":"in_progress","conclusion":null,"html_url":null,"details_url":"https://ci.example.com/3"}
    ]}
    """.utf8)
private let statusesJSON = Data(
    """
    {"state":"failure","sha":"abc","total_count":1,
     "statuses":[{"context":"ci/legacy","state":"error","target_url":null,"description":"boom"}]}
    """.utf8)

@Test func checkRunsAndStatusesBecomeOneListFailingFirst() throws {
    let checks = try GitHub.checks(runs: checkRunsJSON, statuses: statusesJSON)
    #expect(checks.map(\.name) == ["ci/legacy", "test", "lint", "build"])
    #expect(checks.map(\.state) == [.failure, .failure, .pending, .success])
    #expect(checks[2].url?.host() == "ci.example.com")  // no html_url: the CI's own page
    #expect(checks[0].url == nil)
    #expect(CIState(combining: checks.map(\.state)) == .failure)
    #expect(CIState(combining: [.success, .pending]) == .pending)
    #expect(CIState(combining: []) == nil)
}

@Test func theNextPageIsFoundInTheLinkHeader() {
    let link =
        #"<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=5>; rel="last""#
    #expect(GitHub.nextPage(link) == "https://api.github.com/user/repos?page=2")
    #expect(GitHub.nextPage(#"<https://api.github.com/user/repos?page=1>; rel="prev""#) == nil)
    #expect(GitHub.nextPage(nil) == nil)
}

// MARK: The credential helper

/// Tokens in memory: the tests must not touch the user's Keychain.
final class MemoryTokens: TokenStore {
    private let items = Mutex<[String: (String, String)]>([:])
    func token(for host: String) -> (login: String, token: String)? { items.withLock { $0[host] } }
    func save(_ token: String, login: String, host: String) throws {
        items.withLock { $0[host] = (login, token) }
    }
    func delete(host: String) { _ = items.withLock { $0.removeValue(forKey: host) } }
}

@Test func theHelperAnswersGetForItsHostOnly() throws {
    let store = MemoryTokens()
    try store.save("t0ken", login: "octocat", host: "github.com")
    try store.save("ent3rprise", login: "me", host: "ghe.example.com")

    let get = "protocol=https\nhost=github.com\nwwwauth[]=Basic realm=\"GitHub\"\n\n"
    #expect(CredentialHelper.answer("get", input: get, store: store) == "username=octocat\npassword=t0ken\n")
    // A username from the remote URL is git's to keep.
    #expect(
        CredentialHelper.answer("get", input: "protocol=https\nhost=github.com\nusername=x\n", store: store)
            == "password=t0ken\n")
    // git sends the port when the URL has one.
    #expect(
        CredentialHelper.answer("get", input: "protocol=https\nhost=ghe.example.com:8443\n", store: store)
            == "username=me\npassword=ent3rprise\n")
    // Other hosts, plain http, and anything after the blank line: nothing.
    #expect(CredentialHelper.answer("get", input: "protocol=https\nhost=gitlab.com\n", store: store).isEmpty)
    #expect(CredentialHelper.answer("get", input: "protocol=http\nhost=github.com\n", store: store).isEmpty)
    #expect(
        CredentialHelper.answer("get", input: "\nprotocol=https\nhost=github.com\n", store: store).isEmpty)
    // store and erase never change the account's token.
    #expect(CredentialHelper.answer("erase", input: get, store: store).isEmpty)
    #expect(store.token(for: "github.com")?.token == "t0ken")

    #expect(
        CredentialHelper.command(executable: "/Apps/It's here/Upstream")
            == #"!'/Apps/It'\''s here/Upstream' credential"#)
}

// MARK: Against the network stub

/// Answers every request of a session built with it; set `handler` first.
final class Stub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)
    static let handler = Mutex<Handler?>(nil)

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (status, headers, body) =
            Stub.handler.withLock { $0 }?(request) ?? (500, [:], Data(#"{"message":"no stub"}"#.utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func json(_ s: String, _ headers: [String: String] = [:]) -> (Int, [String: String], Data) {
    (200, headers, Data(s.utf8))
}

/// A scratch repository with the given remotes; with a push URL after a space.
private func repo(remotes: [(String, String)]) async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    for (name, url) in remotes {
        let urls = url.split(separator: " ").map(String.init)
        try await git.run(["remote", "add", name, urls[0]], in: dir)
        if urls.count > 1 { try await git.run(["remote", "set-url", "--push", name, urls[1]], in: dir) }
    }
    return (git, dir)
}

@MainActor private func model(_ git: Git) throws -> AppModel {
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    model.forge.store = MemoryTokens()
    model.forge.http = HTTP(session: Stub.session)
    model.forge.helperCommand = "!stub credential"
    return model
}

// Serialized: they share the stub's one handler.
@Suite(.serialized) struct Network {
    @Test func aRepeatedGetSendsTheETagAndA304AnswersFromTheKeptCopy() async throws {
        let seen = Mutex<[String?]>([])
        Stub.handler.withLock {
            $0 = { request in
                let tag = request.value(forHTTPHeaderField: "If-None-Match")
                seen.withLock { $0.append(tag) }
                if tag != nil { return (304, ["ETag": tag!], Data()) }
                let body = request.url!.path().hasSuffix("/status") ? statusesJSON : checkRunsJSON
                return (200, ["Etag": "W/\"\(request.url!.lastPathComponent)\""], body)
            }
        }
        let github = GitHub(
            account: Account(host: "github.com", login: "octocat"), token: "x",
            http: HTTP(session: Stub.session))
        let repo = RepoRef(host: "github.com", owner: "octo", name: "hello")
        let first = try await github.checks(in: repo, commit: "abc")
        let second = try await github.checks(in: repo, commit: "abc")
        #expect(first == second && first.count == 4)
        #expect(Set(seen.withLock { $0 }) == [nil, "W/\"check-runs\"", "W/\"status\""])
        #expect(seen.withLock { $0 }.count == 4)
    }

    @Test func aTokenWithoutTheRepoScopeIsRefusedAtSignIn() async throws {
        Stub.handler.withLock {
            $0 = { _ in json(#"{"login":"octocat"}"#, ["X-OAuth-Scopes": "read:user, gist"]) }
        }
        await #expect(throws: ForgeError.missingScope("repo")) {
            try await GitHub.login(token: "x", host: "github.com", http: HTTP(session: Stub.session))
        }
        Stub.handler.withLock { $0 = { _ in (401, [:], Data(#"{"message":"Bad credentials"}"#.utf8)) } }
        await #expect(throws: ForgeError.unauthorized(host: "ghe.example.com")) {
            try await GitHub.login(token: "x", host: "ghe.example.com", http: HTTP(session: Stub.session))
        }
    }

    @Test func theDeviceFlowWaitsAndSlowsDownWhenTold() async throws {
        let answers = Mutex([
            #"{"error":"authorization_pending"}"#, #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#,
        ])
        Stub.handler.withLock {
            $0 = { request in
                if request.url!.path() == "/login/device/code" {
                    return json(
                        #"{"device_code":"d","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
                    )
                }
                return json(answers.withLock { $0.removeFirst() })
            }
        }
        let http = HTTP(session: Stub.session)
        let code = try await GitHub.startDeviceFlow(http: http)
        #expect(code.userCode == "ABCD-1234")
        let waits = Mutex<[Duration]>([])
        let token = try await GitHub.finishDeviceFlow(code, http: http) { d in waits.withLock { $0.append(d) }
        }
        #expect(token == "gho_x")
        #expect(waits.withLock { $0 } == [.seconds(5), .seconds(5), .seconds(10)])
    }

    @Test func theCloneListFollowsEveryPage() async throws {
        Stub.handler.withLock {
            $0 = { request in
                if request.url!.query()?.contains("page=2") == true {
                    return json(
                        #"[{"full_name":"org/b","clone_url":"https://github.com/org/b.git","private":true,"description":null}]"#
                    )
                }
                return json(
                    #"[{"full_name":"octo/a","clone_url":"https://github.com/octo/a.git","private":false,"description":"A"}]"#,
                    ["Link": #"<https://api.github.com/user/repos?per_page=100&page=2>; rel="next""#])
            }
        }
        let github = GitHub(
            account: Account(host: "github.com", login: "octo"), token: "x", http: HTTP(session: Stub.session)
        )
        #expect(
            try await github.repositories().map(\.cloneURL) == [
                "https://github.com/octo/a.git", "https://github.com/org/b.git",
            ])
    }

    @MainActor @Test func credentialsOnlyForHTTPSRemotesOnSignedInHosts() async throws {
        Stub.handler.withLock {
            $0 = { request in
                request.url!.path() == "/user"
                    ? json(#"{"login":"octocat"}"#, ["X-OAuth-Scopes": "repo, workflow"])
                    : json(#"{"data":{"repository":{"pullRequests":{"nodes":[]}}}}"#)
            }
        }
        let (git, dir) = try await repo(remotes: [
            ("origin", "https://github.com/octo/hello.git"), ("mirror", "git@github.com:octo/hello.git"),
            ("lab", "https://gitlab.com/octo/hello.git"),
            ("split", "git@github.com:octo/hello.git https://github.com/octo/hello.git"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = try model(git)
        let forge = model.forge
        #expect(await forge.credentialArguments(in: dir, remote: "origin") == [])  // signed out

        try await forge.signIn(host: "https://GitHub.com/", token: " t0ken\n")
        #expect(forge.accounts == [Account(host: "github.com", login: "octocat")])
        #expect(forge.store.token(for: "github.com")?.token == "t0ken")
        let ours = [
            "-c", "credential.https://github.com.helper=", "-c",
            "credential.https://github.com.helper=!stub credential",
        ]
        #expect(await forge.credentialArguments(in: dir, remote: "origin") == ours)
        #expect(await forge.credentialArguments(in: dir, remote: "split") == ours)  // pushes over HTTPS
        #expect(await forge.credentialArguments(in: dir, remote: "https://github.com/x/y") == ours)
        #expect(await forge.credentialArguments(in: dir, remote: "mirror") == [])  // SSH: the user's keys
        #expect(await forge.credentialArguments(in: dir, remote: "git@github.com:x/y.git") == [])
        #expect(await forge.credentialArguments(in: dir, remote: "lab") == [])

        forge.signOut(forge.accounts[0])
        #expect(forge.store.token(for: "github.com") == nil)
        #expect(await forge.credentialArguments(in: dir, remote: "origin") == [])
    }

    /// The sidebar's icons cost one GraphQL query per signed-in host per
    /// launch, and nothing while signed out.
    @MainActor @Test func privacyIsAskedOncePerHostAndNeverSignedOut() async throws {
        let queries = Mutex(0)
        Stub.handler.withLock {
            $0 = { request in
                if request.url!.path() == "/user" { return json(#"{"login":"octocat"}"#) }
                queries.withLock { $0 += 1 }
                return json(#"{"data":{"r0":{"isPrivate":true},"r1":{"isPrivate":true}}}"#)
            }
        }
        let (git, dir) = try await repo(remotes: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let forge = try model(git).forge
        let refs = [
            RepoRef(host: "github.com", owner: "octo", name: "a"),
            RepoRef(host: "github.com", owner: "octo", name: "b"),
            RepoRef(host: "ghe.example.com", owner: "octo", name: "c"),
        ]
        await forge.readPrivacy(of: refs)
        #expect(queries.withLock { $0 } == 0 && forge.privacy.isEmpty)

        try await forge.signIn(host: "github.com", token: "t")
        await forge.readPrivacy(of: refs)
        await forge.readPrivacy(of: refs)
        #expect(queries.withLock { $0 } == 1)
        #expect(forge.privacy == [refs[0]: true, refs[1]: true])  // nothing asked of ghe.example.com

        forge.signOut(forge.accounts[0])
        #expect(forge.privacy.isEmpty)
    }
}

// MARK: Against the installed git

@MainActor @Test func theCommitLinkNeedsNoAccountAndPrefersOrigin() async throws {
    let (git, dir) = try await repo(remotes: [
        ("fork", "git@github.com:me/hello.git"), ("origin", "https://github.com/octo/hello.git"),
    ])
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = try model(git)
    await model.add(dir)
    #expect(
        await model.forge.webURL(commit: "abc")?.absoluteString == "https://github.com/octo/hello/commit/abc")
    try await git.run(["remote", "remove", "origin"], in: dir)
    model.forge.repositoryChanged()
    #expect(
        await model.forge.webURL(commit: "abc")?.absoluteString == "https://github.com/me/hello/commit/abc")
}

/// 002's open question, answered: git asks credential helpers in config
/// order and `-c` comes last, so a host-scoped helper passed with `-c` is
/// asked only after a global one, whose stale password then wins. The
/// empty helper that `credentialArguments` puts first resets the list.
@MainActor @Test func ourHelperWinsOverAGlobalOneOnlyBecauseOfTheReset() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appending(path: "a b"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func helper(_ path: String, _ password: String, actionAt n: Int) throws {
        let url = dir.appending(path: path)
        try Data(
            "#!/bin/sh\n[ \"$\(n)\" = get ] && printf 'username=u\\npassword=\(password)\\n'\nexit 0\n".utf8
        )
        .write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try helper("old", "OLD", actionAt: 1)  // stands in for osxkeychain holding an old token
    try helper("a b/Upstream", "NEW", actionAt: 2)  // run as `Upstream credential get`
    let global = dir.appending(path: "gitconfig")
    try Data("[credential]\n\thelper = \(dir.appending(path: "old").path)\n".utf8).write(to: global)

    let model = try model(git)
    model.forge.helperCommand = CredentialHelper.command(executable: dir.appending(path: "a b/Upstream").path)
    try model.forge.store.save("t", login: "u", host: "github.com")
    model.forge.accounts = [Account(host: "github.com", login: "u")]  // signed in, without the request
    let ours = await model.forge.credentialArguments(in: dir, remote: "https://github.com/octo/hello.git")

    func fill(_ args: [String]) async throws -> String {
        try await git.run(
            args + ["credential", "fill"], in: dir, input: Data("protocol=https\nhost=github.com\n\n".utf8),
            environment: ["GIT_CONFIG_GLOBAL": global.path, "GIT_CONFIG_NOSYSTEM": "1"]
        ).text
    }
    #expect(try await fill(ours).contains("password=NEW\n"))
    let withoutReset = Array(ours.suffix(2))
    #expect(try await fill(withoutReset).contains("password=OLD\n"))
}
