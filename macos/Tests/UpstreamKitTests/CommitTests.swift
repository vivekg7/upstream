import Foundation
import Testing

@testable import UpstreamKit

// The checkbox commit against the installed git, in scratch repositories
// (docs/plans/003_the_checkbox_commit.md).

/// A repository with `files` committed as "base", and its own identity,
/// hooks folder and no signing, whatever the global config says.
private func repo(_ files: [String: String]) async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    for (key, value) in [
        "user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false",
        "core.hooksPath": dir.appending(path: ".git/hooks").path,
    ] {
        try await git.run(["config", key, value], in: dir)
    }
    for (path, text) in files { try write(text, path, in: dir) }
    try await git.run(["add", "."], in: dir)
    try await git.run(["commit", "-qm", "base"], in: dir)
    return (git, dir)
}

private func write(_ text: String, _ path: String, in dir: URL) throws {
    try Data(text.utf8).write(to: dir.appending(path: path))
}

private func status(_ git: Git, _ dir: URL) async throws -> RepoStatus {
    RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout)
}

private func diff(of path: String, _ git: Git, _ dir: URL) async throws -> FileDiff {
    let change = try #require(try await status(git, dir).files.first { $0.path == path })
    let (args, allowed) = FileDiff.arguments(for: change, hasHead: true)
    return FileDiff(parsing: try await git.run(args, in: dir, allowedExitCodes: allowed).stdout)
}

/// The changed lines of `diff` whose text is one of `texts`, marker included ("+x").
private func lines(_ diff: FileDiff, _ texts: Set<String>) -> Set<Int> {
    Set(
        diff.changedLines.filter {
            texts.contains((diff.lines[$0].kind == .added ? "+" : "-") + diff.lines[$0].text)
        })
}

/// Commits with `chosen` for the files it names and every other file unchecked.
private func commit(
    _ chosen: [String: FileSelection], _ git: Git, _ dir: URL, message: String = "test", amend: Bool = false
) async throws {
    let files = try await status(git, dir).files
    try await git.commit(
        files.map { ($0, chosen[$0.path] ?? .nothing) }, message: message, amend: amend, hasHead: true,
        in: dir)
}

private func show(_ object: String, _ git: Git, _ dir: URL) async throws -> String {
    try await git.run(["show", "--format=", object], in: dir).text
}

@Test func onlyTheCheckedFilesAreCommitted() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n", "b.txt": "b\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a2\n", "a.txt", in: dir)
    try write("b2\n", "b.txt", in: dir)
    try await git.run(["add", "b.txt"], in: dir)  // staged in a terminal, then left unchecked
    try write("star\n", "*.txt", in: dir)  // a pathspec, if paths were not literal

    try await commit(["*.txt": .all], git, dir)

    let committed = try await git.run(["show", "--name-only", "--format=", "HEAD"], in: dir).text
    #expect(committed == "*.txt\n")
    let files = try await status(git, dir).files
    #expect(files.first { $0.path == "b.txt" }?.index == .modified)  // still staged
    #expect(files.first { $0.path == "a.txt" }?.worktree == .modified)
}

@Test func onlyTheCheckedLinesAreCommitted() async throws {
    let (git, dir) = try await repo(["f.txt": "1\n2\n3\n4\n5\n6\n7\n8\n9\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("1\nX\n3\n4\n5\n6\n7\n8\nY\n", "f.txt", in: dir)  // two hunks
    let d = try await diff(of: "f.txt", git, dir)

    try await commit(["f.txt": .lines(lines(d, ["-2", "+X"]), of: d)], git, dir)

    #expect(try await show("HEAD:f.txt", git, dir) == "1\nX\n3\n4\n5\n6\n7\n8\n9\n")
    let rest = try await diff(of: "f.txt", git, dir)
    #expect(rest.lines.filter { $0.kind != .context && $0.kind != .hunk }.map(\.text) == ["9", "Y"])
}

@Test func partOfAFileWithoutAFinalNewline() async throws {
    let (git, dir) = try await repo(["f.txt": "1\n2"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("1\n2\n3", "f.txt", in: dir)  // [" 1", "-2", "\", "+2", "+3", "\"]
    let d = try await diff(of: "f.txt", git, dir)

    try await commit(["f.txt": .lines(lines(d, ["+3"]), of: d)], git, dir)

    #expect(try await show("HEAD:f.txt", git, dir) == "1\n2\n3")
}

@Test func partOfANewFile() async throws {
    let (git, dir) = try await repo(["base.txt": "base\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("one\ntwo\n", "new file.txt", in: dir)  // untracked, with a space
    let d = try await diff(of: "new file.txt", git, dir)

    try await commit(["new file.txt": .lines(lines(d, ["+one"]), of: d)], git, dir)

    #expect(try await show("HEAD:new file.txt", git, dir) == "one\n")
    #expect(try await status(git, dir).files.map(\.path) == ["new file.txt"])  // "two" is still to commit
}

@Test func partOfARenamedFile() async throws {
    let (git, dir) = try await repo(["old.txt": "x\ny\nz\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["mv", "old.txt", "new.txt"], in: dir)
    try write("x\ny\nz\nw\nv\n", "new.txt", in: dir)
    let d = try await diff(of: "new.txt", git, dir)

    try await commit(["new.txt": .lines(lines(d, ["+w"]), of: d)], git, dir)

    let tree = try await git.run(["ls-tree", "--name-only", "HEAD"], in: dir).text
    #expect(tree == "new.txt\n")
    #expect(try await show("HEAD:new.txt", git, dir) == "x\ny\nz\nw\n")
}

@Test func amendReplacesTheLastCommit() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n", "b.txt": "b\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a2\n", "a.txt", in: dir)
    try await commit(["a.txt": .all], git, dir, message: "first")
    try write("b2\n", "b.txt", in: dir)

    try await commit(["b.txt": .all], git, dir, message: "second\n\nbody", amend: true)

    let log = try await git.run(["log", "--format=%s", "HEAD"], in: dir).text
    #expect(log == "second\nbase\n")
    #expect(try await show("HEAD:a.txt", git, dir) == "a2\n")
    #expect(try await show("HEAD:b.txt", git, dir) == "b2\n")
}

@Test func aRejectedCommitLeavesTheIndexAsItWas() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n", "b.txt": "b\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let hook = dir.appending(path: ".git/hooks/pre-commit")
    try write("#!/bin/sh\necho 'no, says the hook' >&2\nexit 1\n", ".git/hooks/pre-commit", in: dir)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try write("a2\n", "a.txt", in: dir)
    try write("b2\n", "b.txt", in: dir)
    try await git.run(["add", "b.txt"], in: dir)
    let before = try await status(git, dir)

    let error = await #expect(throws: GitError.self) { try await commit(["a.txt": .all], git, dir) }

    #expect(error?.message.contains("no, says the hook") == true)
    #expect(try await status(git, dir) == before)
}

@Test func linesChosenInAnOlderDiffAreRefused() async throws {
    let (git, dir) = try await repo(["f.txt": "1\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("1\n2\n3\n", "f.txt", in: dir)
    let d = try await diff(of: "f.txt", git, dir)
    try write("1\n3\n", "f.txt", in: dir)  // edited after choosing "+2"

    await #expect(throws: CommitError.changedSinceChosen(path: "f.txt")) {
        try await commit(["f.txt": .lines(lines(d, ["+2"]), of: d)], git, dir)
    }
}

@MainActor @Test func aCommitPreparedInATerminalIsTheOneOffered() async throws {
    let (git, dir) = try await repo(["a": "a\n", "b": "b\n", "c": "c\n", "d": "d\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a2\n", "a", in: dir)
    try write("b2\n", "b", in: dir)
    try write("c\nstaged\n", "c", in: dir)
    try write("d\nfoo\n", "d", in: dir)
    try await git.run(["add", "a", "c", "d"], in: dir)
    try write("c\nstaged\nnot\n", "c", in: dir)
    try write("d\nbar\n", "d", in: dir)  // the staged "foo" is in neither HEAD nor the file

    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()

    let files = Dictionary(uniqueKeysWithValues: (model.status?.files ?? []).map { ($0.path, $0) })
    #expect(model.selection(of: try #require(files["a"])) == .all)
    #expect(model.selection(of: try #require(files["b"])) == .nothing)
    #expect(model.selection(of: try #require(files["d"])) == .nothing)
    guard case .lines(let picked, let d) = model.selection(of: try #require(files["c"])) else {
        Issue.record("c should be partly checked")
        return
    }
    #expect(picked.map { d.lines[$0].text } == ["staged"])
}

@Test func coAuthorsAreTrailersThatGitFormats() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a2\n", "a.txt", in: dir)
    var draft = CommitDraft()
    for text in ["  Ada Lovelace <ada@example.com> ", "Grace Hopper<grace@example.org>"] {
        draft.coAuthors.append(try #require(CommitDraft.coAuthor(text)))
    }
    #expect(CommitDraft.coAuthor("just a name") == nil)
    #expect(CommitDraft.coAuthor("<nobody@example.com>") == nil)

    let files = try await status(git, dir).files
    try await git.commit(
        files.map { ($0, .all) }, message: "Summary\n\nBody", trailers: draft.trailers, amend: false,
        hasHead: true,
        in: dir)

    let message = try await git.run(["log", "-1", "--format=%B"], in: dir).text
    #expect(
        message
            == "Summary\n\nBody\n\nCo-authored-by: Ada Lovelace <ada@example.com>\nCo-authored-by: Grace Hopper <grace@example.org>\n\n"
    )
}

@MainActor @Test func theTemplatePrefillsAnEmptyDraftWithoutItsComments() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(
        "; a comment, with commentChar ;\nFix: \n\n# not a comment here\nWhy:\n", "template.txt", in: dir)
    try await git.run(["config", "commit.template", "template.txt"], in: dir)  // relative to the top level
    try await git.run(["config", "core.commentChar", ";"], in: dir)

    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()

    #expect(model.draft.summary == "Fix:")
    #expect(model.draft.description == "# not a comment here\nWhy:")
    model.draft.summary = ""  // cleared on purpose: not filled in again
    model.draft.description = ""
    await model.refresh()
    #expect(model.draft.summary == "")
}

@MainActor @Test func stagedLinesOfManyFilesAreReadInOneBatchAndMatchEachFilesDiff() async throws {
    // A rename and names git C-quotes (a tab, a quote), all staged then edited.
    let names = ["plain.txt", "with space.txt", "tab\there.txt", "quo\"te.txt", "old.txt"]
    let base = (1...20).map { "line \($0)\n" }.joined()  // enough for git to pair the rename
    let (git, dir) = try await repo(Dictionary(uniqueKeysWithValues: names.map { ($0, base) }))
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["mv", "old.txt", "new.txt"], in: dir)
    let current = names.dropLast() + ["new.txt"]
    for name in current {
        try write(base + "staged\n", name, in: dir)
        try await git.run(["add", "--", name], in: dir)
        try write(base + "staged\nnot\n", name, in: dir)
    }
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()

    for name in current {
        let change = try #require(model.status?.files.first { $0.path == name }, "\(name) missing")
        guard case .lines(let picked, let d) = model.selection(of: change) else {
            Issue.record("\(name) should be partly checked: \(model.selection(of: change))")
            continue
        }
        #expect(picked.map { d.lines[$0].text } == ["staged"])
        // The file's own diff, which the diff view loads and the commit
        // checks against, is the same: so showing it keeps the lines.
        model.selectedFile = change.id
        await model.refresh()
        #expect(model.diff == d, "\(name)")
        if case .lines = model.selection(of: change) {
        } else {
            Issue.record("\(name) was unchecked on reload")
        }
    }
}
