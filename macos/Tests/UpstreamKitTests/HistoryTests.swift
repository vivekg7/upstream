import Foundation
import Testing

@testable import UpstreamKit

// History against the installed git, in scratch repositories
// (docs/plans/006_history.md).

/// An empty repository with its own identity, hooks folder and no signing,
/// whatever the global config says.
private func repo() async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    for (key, value) in [
        "user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false",
        "tag.gpgsign": "false", "core.hooksPath": dir.appending(path: ".git/hooks").path,
    ] {
        try await git.run(["config", key, value], in: dir)
    }
    return (git, dir)
}

/// Writes `files` and commits everything with `message`, dated `time`
/// seconds after a fixed moment, so commit order can be made to disagree
/// with dates. Returns the new commit's name.
@discardableResult
private func commit(
    _ message: String, _ files: [String: String] = [:], at time: Int? = nil, _ git: Git, _ dir: URL
) async throws -> String {
    for (path, text) in files {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    try await git.run(["add", "-A"], in: dir)
    var env: [String: String] = [:]
    if let time {
        let date = "\(1_700_000_000 + time) +0000"
        env = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
    }
    try await git.run(
        ["commit", "-q", "--allow-empty", "--cleanup=verbatim", "--file=-"], in: dir,
        input: Data(message.utf8), environment: env)
    return try await head(git, dir)
}

private func head(_ git: Git, _ dir: URL) async throws -> String {
    try await git.run(["rev-parse", "HEAD"], in: dir).text.trimmingCharacters(in: .newlines)
}

/// The app on `dir`, with its history read.
@MainActor private func model(_ git: Git, _ dir: URL) async throws -> AppModel {
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()
    await model.history.load()
    return model
}

@Test func messagesAreReadAsWritten() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    // A literal "%x1f" is text; a real 0x1F in the subject must not split it.
    let subject = "Ünïcödé ✓ %x1f and \u{1f} in the middle"
    let message = "\(subject)\n\nFirst paragraph\nsecond line\n\n\nAfter blank lines"
    let first = try await commit("No body", ["a": "a"], git, dir)
    let second = try await commit(message, ["b": "b"], git, dir)

    let log = try await git.log(from: ["HEAD"], excluding: [], count: 10, in: dir)
    #expect(log.map(\.subject) == [subject, "No body"])
    #expect(log.map(\.parents) == [[first], []])
    #expect(log[0].authorName == "Test" && log[0].authorEmail == "test@example.com")

    let detail = try await git.commitDetail(second, in: dir)
    #expect(detail.message == message)
    #expect(detail.parents == [first])
    #expect(try await git.commitDetail(first, in: dir).message == "No body")
}

/// Pages of three over a merge whose first parent is dated before its own
/// parent (clock skew). git's walk shows that parent before the skewed
/// commit, so a page that starts again from the skewed commit walks into
/// it a second time: the case that could repeat. Commits in order:
/// t3 t2 t1 | merge b s | a s(again) base.
@MainActor @Test func pagesNeitherRepeatNorSkip() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await commit("base", ["f": "0"], at: 0, git, dir)
    try await commit("s", ["f": "s"], at: 100, git, dir)
    try await git.run(["switch", "-qc", "side"], in: dir)
    try await commit("b", ["b": "b"], at: 300, git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit("a, dated before its parent", ["a": "a"], at: 50, git, dir)
    try await git.run(["merge", "-q", "--no-ff", "--no-commit", "side"], in: dir)
    try await commit("merge", at: 400, git, dir)
    for k in 1...3 { try await commit("t\(k)", ["f": "\(k)"], at: 500 + k, git, dir) }

    let app = try await model(git, dir)
    app.history.pageSize = 3
    await app.history.reload()
    var pages = 0
    while !app.history.atEnd && pages < 50 {
        await app.history.loadMore()
        pages += 1
    }

    let all = try await git.run(["rev-list", "HEAD"], in: dir).text.split(separator: "\n").map(String.init)
    let listed = app.history.commits.map(\.id)
    #expect(listed.count == Set(listed).count)
    #expect(Set(listed) == Set(all), "\(listed.count) of \(all.count) after \(pages) pages")
    #expect(listed.first == (try await head(git, dir)))
}

@Test func aRootCommitListsItsFiles() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try await commit("root", ["a.txt": "one\ntwo\n", "dir/b.txt": "b\n"], git, dir)

    let detail = try await git.commitDetail(root, in: dir)
    let files = try await git.files(of: detail, in: dir)
    #expect(files.map(\.path) == ["a.txt", "dir/b.txt"])
    #expect(files.allSatisfy { $0.kind == .added })
    let diff = try await git.diff(of: files[0], in: detail, in: dir)
    #expect(diff.lines.filter { $0.kind == .added }.map(\.text) == ["one", "two"])
}

@Test func aMergeListsWhatItBroughtIn() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await commit("base", ["base": "x"], git, dir)
    try await git.run(["switch", "-qc", "side"], in: dir)
    try await commit("side", ["side.txt": "from side\n"], git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit("main", ["main.txt": "from main\n"], git, dir)
    try await git.run(["merge", "-q", "--no-ff", "-m", "merge", "side"], in: dir)

    let merge = try await git.commitDetail(try await head(git, dir), in: dir)
    #expect(merge.parents.count == 2)
    // Against the first parent: main's own file is not listed.
    let files = try await git.files(of: merge, in: dir)
    #expect(files == [CommitFile(kind: .added, path: "side.txt")])
    let diff = try await git.diff(of: files[0], in: merge, in: dir)
    #expect(diff.lines.filter { $0.kind == .added }.map(\.text) == ["from side"])
}

@Test func aRenameIsOneFileWithBothPaths() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await commit("base", ["old name.txt": "a\nb\nc\nd\n"], git, dir)
    try await git.run(["mv", "old name.txt", "new name.txt"], in: dir)
    let sha = try await commit("rename", [:], git, dir)

    let detail = try await git.commitDetail(sha, in: dir)
    let files = try await git.files(of: detail, in: dir)
    #expect(files == [CommitFile(kind: .renamed, path: "new name.txt", originalPath: "old name.txt")])
}

@MainActor @Test func revertCherryPickAndResetKeepingChanges() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    let base = try await commit("base", ["f": "base\n"], git, dir)
    try await git.run(["switch", "-qc", "side"], in: dir)
    let picked = try await commit("on side", ["s": "side\n"], git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit("change", ["f": "changed\n"], git, dir)
    let app = try await model(git, dir)
    let history = app.history

    #expect(await history.revert(try #require(history.commits.first)))
    #expect(history.commits.first?.subject == "Revert \"change\"")
    #expect(try String(contentsOf: dir.appending(path: "f"), encoding: .utf8) == "base\n")

    history.compare = "refs/heads/side"
    await history.reload()
    #expect(history.compareCounts?.behind == 1)
    #expect(history.commits.map(\.id) == [picked])
    #expect(await history.cherryPick(history.commits[0]))
    #expect(try String(contentsOf: dir.appending(path: "s"), encoding: .utf8) == "side\n")

    history.compare = nil
    await history.reload()
    let target = try #require(history.commits.first { $0.id == base })
    #expect(await history.reset(to: target))
    #expect(try await head(git, dir) == base)
    // The commits are gone from the branch, their changes are not.
    #expect(app.status?.files.map(\.path).sorted() == ["s"])
    #expect(try String(contentsOf: dir.appending(path: "s"), encoding: .utf8) == "side\n")
    #expect(history.commits.map(\.id) == [base])
}

@MainActor @Test func undoPutsTheMessageBackUnlessOneIsTyped() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await commit("base", ["a": "a\n"], git, dir)
    try await commit("Summary\n\nThe body\nof it", ["a": "a2\n"], git, dir)
    let app = try await model(git, dir)

    #expect(await app.history.undo())
    #expect(app.draft.summary == "Summary")
    #expect(app.draft.description == "The body\nof it")
    #expect(app.status?.files.first?.index == .modified)  // the change is back, staged
    #expect(app.history.commits.map(\.subject) == ["base"])

    // The first commit: the branch goes back to unborn. The draft already
    // holds the user's words, so "base" does not replace them.
    #expect(await app.history.undo())
    #expect(app.hasHead == false)
    #expect(app.draft.summary == "Summary")
    #expect(app.status?.files.first?.index == .added)
}

@MainActor @Test func commitsNotOnTheUpstreamAreMarked() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    let origin = dir.appending(path: ".git/test-origin.git")  // local: no network
    try await git.run(["init", "-q", "--bare", origin.path], in: dir)
    try await git.run(["remote", "add", "origin", origin.path], in: dir)
    let pushed = try await commit("pushed", ["a": "1"], git, dir)
    try await git.run(["push", "-q", "-u", "origin", "main"], in: dir)
    let one = try await commit("one", ["a": "2"], git, dir)
    let two = try await commit("two", ["a": "3"], git, dir)

    let app = try await model(git, dir)
    #expect(app.history.unpushed == [one, two])
    #expect(app.history.labels[pushed]?.map(\.name) == ["origin/main"])
    #expect(app.history.undoable?.id == two)

    try await git.run(["push", "-q"], in: dir)
    await app.refresh()  // ahead 0: the branch moved, so the history reloads
    await app.history.reload()
    #expect(app.history.unpushed.isEmpty)
    #expect(app.history.undoable == nil)  // pushed: undoing it would rewrite what others have
}

@MainActor @Test func branchAndTagNamesAreCheckedByGit() async throws {
    let (git, dir) = try await repo()
    defer { try? FileManager.default.removeItem(at: dir) }
    let base = try await commit("base", ["a": "1"], git, dir)
    try await commit("next", ["a": "2"], git, dir)
    let app = try await model(git, dir)
    let target = try #require(app.history.commits.last)

    #expect(await app.history.createTag("bad..name", at: target) == false)
    #expect(app.error != nil)
    #expect(await app.history.createTag("v1.0", at: target))
    #expect(app.history.labels[base]?.map(\.name) == ["v1.0"])

    #expect(await app.history.createBranch("@{-1}", at: target) == false)
    #expect(await app.history.createBranch("topic", at: target))
    #expect(app.status?.branch.head == "topic")
    #expect(try await head(git, dir) == base)
}

// The same formats in fixtures/git/, which the Linux parser reads too.

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "fixtures/git/\(name)"))
}

@Test func theLogFixtureParses() throws {
    let log = Commit.parse(log: try fixture("log.z"))
    #expect(
        log.map(\.subject) == [
            "Merge side", "Main", "Side", "Rename, no body", "Ünïcode subject, a literal %x1f",
        ])
    #expect(log[0].parents.count == 2)
    #expect(log.last?.parents == [])
    #expect(log.last?.date == Date(timeIntervalSince1970: 1_767_225_600))

    let detail = try #require(CommitDetail(parsing: try fixture("log-detail.z")))
    #expect(detail.id == log.last?.id)
    #expect(detail.message == "Ünïcode subject, a literal %x1f\n\nBody line one\nbody line two")
    #expect(detail.committerName == "Fixture")
}

@Test func theDiffTreeFixturesParse() throws {
    #expect(
        CommitFile.parse(try fixture("diff-tree-root.z")) == [
            CommitFile(kind: .added, path: "a.txt"), CommitFile(kind: .added, path: "old name.txt"),
        ])
    #expect(
        CommitFile.parse(try fixture("diff-tree-rename.z")) == [
            CommitFile(kind: .renamed, path: "new name.txt", originalPath: "old name.txt")
        ])
    #expect(
        CommitFile.parse(try fixture("diff-tree-merge.z")) == [CommitFile(kind: .added, path: "side.txt")])
}

@Test func anAnnotatedTagLabelsTheCommitItPointsAt() throws {
    let log = Commit.parse(log: try fixture("log.z"))
    let refs = RefLabel.parse(try fixture("for-each-ref.z"))
    #expect(refs.labels[log[0].id]?.map(\.name) == ["main", "light"])
    #expect(refs.labels[log[2].id]?.map(\.name) == ["side"])
    #expect(refs.labels[try #require(log.last).id]?.map(\.name) == ["v1"])  // not the tag object
    #expect(refs.branches.map(\.name) == ["main", "side"])
    #expect(!refs.hasRemotes)
}
