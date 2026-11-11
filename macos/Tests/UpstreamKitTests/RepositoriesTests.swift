import Foundation
import Testing

@testable import UpstreamKit

// The repository list, clone, create and the global settings, against the
// installed git (docs/plans/009_repositories_and_settings.md).

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A global config of the test's own, so neither the owner's real one is
/// touched nor its signing or hooks apply.
private func isolated(in dir: URL) throws -> [String: String] {
    let file = dir.appending(path: "gitconfig")
    try Data("[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n".utf8).write(
        to: file)
    return ["GIT_CONFIG_GLOBAL": file.path, "GIT_CONFIG_NOSYSTEM": "1"]
}

@MainActor private func model(_ git: Git) throws -> AppModel {
    AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
}

@Test func theOwnerIsReadFromEveryURLForm() {
    let cases: [(String, String?)] = [
        ("https://github.com/octocat/hello.git", "github.com/octocat"),
        ("https://user@GitLab.com:8443/group/sub/repo/", "gitlab.com/group/sub"),
        ("ssh://git@github.com:22/octocat/hello.git", "github.com/octocat"),
        ("git://example.org/team/tool", "example.org/team"),
        ("git@github.com:octocat/hello.git", "github.com/octocat"),
        ("example.org:team/tool.git", "example.org/team"),
        ("https://example.org/tool.git", nil),  // no owner
        ("/Users/me/bare.git", nil),
        ("./a:b/repo", nil),  // a slash before the colon: a local path to git
        ("file:///Users/me/team/bare.git", nil),
    ]
    for (url, owner) in cases {
        #expect(RemoteOwner(remoteURL: url)?.description == owner, "\(url)")
    }
}

@MainActor @Test func originDecidesTheGroupAndNoRemoteIsOther() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let (a, b, c) = (root.appending(path: "a"), root.appending(path: "b"), root.appending(path: "c"))
    for dir in [a, b, c] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q"], in: dir)
    }
    try await git.run(["remote", "add", "fork", "git@github.com:me/a.git"], in: a)
    try await git.run(["remote", "add", "origin", "https://github.com/octocat/a.git"], in: a)
    try await git.run(["remote", "add", "my.fork", "https://gitlab.com/me/b"], in: b)  // a dot in the name

    let model = try model(git)
    for dir in [a, b, c] { await model.add(dir) }
    await model.library.update()

    let groups = model.library.groups().map {
        ($0.owner?.description, $0.repositories.map(\.lastPathComponent))
    }
    #expect(groups.map(\.0) == ["gitlab.com/me", "github.com/octocat", nil])
    #expect(groups.map(\.1) == [["b"], ["a"], ["c"]])
    #expect(model.library.groups(filter: "octo").map(\.repositories.count) == [1])
}

@MainActor @Test func recentKeepsTheLastThreeOpenedAndCollapsingIsKept() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let names = (1...LibraryModel.recentThreshold).map { "r\($0)" }
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let model = AppModel(git: git, defaults: defaults)
    model.recentDwell = .milliseconds(50)
    for name in names {
        let dir = root.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q"], in: dir)
        await model.add(dir)
    }
    let url = { (name: String) in model.repositories.first { $0.lastPathComponent == name }! }
    for name in ["r2", "r5", "r3", "r5", "r7"] {
        model.selected = url(name)
        try await Task.sleep(for: .milliseconds(150))
    }
    // Passed on the way with ↓, not opened.
    for name in ["r1", "r4"] { model.selected = url(name) }
    model.selected = url("r7")
    try await Task.sleep(for: .milliseconds(150))
    await model.library.update()

    #expect(model.recent.map(\.lastPathComponent) == ["r7", "r5", "r3"])
    // By name, so picking one or ↓ through them does not reorder the rows.
    #expect(model.library.recent().map(\.lastPathComponent) == ["r3", "r5", "r7"])
    #expect(model.library.recent(filter: "r").isEmpty)  // the matches are the list
    model.library.setExpanded(false, LibraryModel.recentSection)

    let relaunched = AppModel(git: git, defaults: defaults)
    #expect(relaunched.selected?.lastPathComponent == "r7")
    #expect(relaunched.library.collapsed == [LibraryModel.recentSection])
    relaunched.remove(url("r5"))
    #expect(relaunched.recent.map(\.lastPathComponent) == ["r7", "r3"])
    relaunched.remove(url("r1"))  // too short a list to repeat in Recent
    #expect(relaunched.library.recent().isEmpty)
}

@MainActor @Test func aMovedFolderIsShownMissing() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let (old, new) = (root.appending(path: "old"), root.appending(path: "new"))
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try await git.run(["init", "-q"], in: old)
    let model = try model(git)
    await model.add(old)
    let added = try #require(model.repositories.first)

    try FileManager.default.moveItem(at: old, to: new)
    await model.library.update()
    #expect(model.library.missing == [added])
    #expect(model.selected == nil)

    await model.library.locate(added, at: new)
    #expect(model.repositories.map(\.lastPathComponent) == ["new"])
    #expect(model.library.missing.isEmpty)
}

@Test func createWritesTheFilesAndCommitsThemOnTheDefaultBranch() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try isolated(in: root)
    let new = NewRepository(
        name: "tool", parent: root, defaultBranch: "trunk", readme: true, description: "Does things.",
        gitignore: "Swift", license: "MIT", author: "Ada Lovelace")

    try await git.create(new, year: 2026, environment: env)

    let dir = root.appending(path: "tool")
    let run = { (args: [String]) in try await git.run(args, in: dir, environment: env).text }
    #expect(try await run(["symbolic-ref", "--short", "HEAD"]) == "trunk\n")
    #expect(try await run(["ls-tree", "--name-only", "HEAD"]) == ".gitignore\nLICENSE\nREADME.md\n")
    #expect(try await run(["show", "HEAD:README.md"]) == "# tool\n\nDoes things.\n")
    #expect(try await run(["show", "HEAD:LICENSE"]).contains("Copyright (c) 2026 Ada Lovelace\n"))
    #expect(try await run(["show", "HEAD:.gitignore"]) == Templates.gitignores["Swift"])
    #expect(try await run(["status", "--porcelain=v2"]).isEmpty)
}

@Test func createNeverOverwritesOrCommitsWhatWasThere() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try isolated(in: root)
    let dir = root.appending(path: "notes")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("mine\n".utf8).write(to: dir.appending(path: "README.md"))
    try Data("secret\n".utf8).write(to: dir.appending(path: "draft.txt"))

    try await git.create(
        NewRepository(name: "notes", parent: root, readme: true, license: "ISC"), environment: env)

    #expect(try String(contentsOf: dir.appending(path: "README.md"), encoding: .utf8) == "mine\n")
    let tree = try await git.run(["ls-tree", "--name-only", "HEAD"], in: dir, environment: env).text
    #expect(tree == "LICENSE\n")
    await #expect(throws: RepositoryError.alreadyRepository("notes")) {
        try await git.create(NewRepository(name: "notes", parent: root), environment: env)
    }
}

@MainActor @Test func aCloneIsAddedAndSelected() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try isolated(in: root)
    try await git.create(NewRepository(name: "src", parent: root, readme: true), environment: env)
    let bare = root.appending(path: "src.git")
    try await git.run(["clone", "-q", "--bare", "src", bare.path], in: root)

    let model = try model(git)
    try await model.library.clone(bare.path, to: root.appending(path: "clones/src"))

    let added = try #require(model.selected)
    #expect(model.repositories == [added])
    #expect(FileManager.default.fileExists(atPath: added.appending(path: "README.md").path))
}

@Test func aCancelledCloneLeavesNoFolder() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appending(path: "slow")
    // A transport that never answers, so the clone is still running when
    // cancelled. `exec … 2>/dev/null` keeps it off git's stderr, whose pipe
    // would otherwise stay open after git is gone.
    let clone = Task {
        try await git.clone(
            "ext::sh -c exec% sleep% 30% 2>/dev/null", to: dir, options: ["-c", "protocol.ext.allow=always"])
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(FileManager.default.fileExists(atPath: dir.path))  // git made it, and is waiting
    clone.cancel()

    await #expect(throws: CancellationError.self) { try await clone.value }
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func settingsWriteToTheGlobalConfigGitUses() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let env = try isolated(in: root)
    let config = GlobalConfig(git: git, environment: env)

    try await config.set("user.email", "ada@example.com")
    try await config.set("init.defaultBranch", "trunk")
    try await config.set("user.name", "")  // unset
    try await config.set("user.name", "")  // already unset: not an error

    #expect(await config.get("user.email") == "ada@example.com")
    #expect(await config.get("user.name") == nil)
    let file = try await git.run(
        ["config", "--file", root.appending(path: "gitconfig").path, "--list"], in: root)
    #expect(file.text.contains("user.email=ada@example.com\n"))
    #expect(file.text.contains("init.defaultbranch=trunk\n"))
    #expect(GlobalConfig.isValidEmail("ada@example.com"))
    #expect(!GlobalConfig.isValidEmail("Ada <ada@example.com>"))
    #expect(!GlobalConfig.isValidEmail("ada@localhost"))
    #expect(await config.isValidBranch("feature/x"))
    #expect(!(await config.isValidBranch("two words")))
}

@Test func anOldGitIsDetected() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    #expect(await git.version()?.isSupported == true)  // the installed one parses
    // git has no machine-readable version, so these are the shapes its
    // human line takes. 2.9 against 2.38 is the one a string comparison
    // gets wrong.
    #expect(GitVersion(parsing: "git version 2.9.5")?.isSupported == false)
    #expect(GitVersion(parsing: "git version 2.34.1")?.isSupported == false)
    #expect(GitVersion(parsing: "git version 2.38.0")?.isSupported == true)
    #expect(GitVersion(parsing: "git version 2.39.5 (Apple Git-154)")?.description == "2.39.5")
    #expect(GitVersion(parsing: "git version 2.45.1.windows.1")?.description == "2.45.1")
    #expect(GitVersion(parsing: "nonsense") == nil)
}
