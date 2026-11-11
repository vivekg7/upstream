import Foundation
import Testing

@testable import UpstreamKit

// Discarding to the Trash and ignoring, against the installed git
// (docs/plans/008_discard_ignore_and_conflicts.md).

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
    let url = dir.appending(path: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ path: String, in dir: URL) -> String? {
    (try? Data(contentsOf: dir.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
}

private func status(_ git: Git, _ dir: URL) async throws -> RepoStatus {
    RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout)
}

/// A stand-in for the Trash: a folder of the test's own, which, like the
/// Trash, numbers a second item of the same name.
func trashFolder() throws -> (URL, Trash) {
    let bin = FileManager.default.temporaryDirectory.appending(path: "upstream-trash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    return (
        bin,
        { item in
            var target = bin.appending(path: item.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = bin.appending(path: "\(item.lastPathComponent) \(n)")
                n += 1
            }
            try FileManager.default.moveItem(at: item, to: target)
        }
    )
}

/// The one folder a discard put in the trash.
private func trashed(_ bin: URL) throws -> URL {
    let items = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)
    #expect(items.count == 1)
    let folder = try #require(items.first)
    #expect(folder.lastPathComponent.hasPrefix("Upstream discarded changes "))
    return folder
}

@Test func discardKeepsACopyInTheTrashAndRestoresEveryKindOfChange() async throws {
    let (git, dir) = try await repo(["mod.txt": "m\n", "del.txt": "d\n", "old.txt": "x\ny\nz\n"])
    let (bin, trash) = try trashFolder()
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }
    try write("m2\n", "mod.txt", in: dir)
    try FileManager.default.removeItem(at: dir.appending(path: "del.txt"))
    try write("new\n", "added.txt", in: dir)
    try await git.run(["add", "added.txt"], in: dir)
    try await git.run(["mv", "old.txt", "new.txt"], in: dir)
    try write("x\ny\nz\nw\n", "new.txt", in: dir)
    try write("mine\n", "sub dir/u*.txt", in: dir)  // a pathspec, if paths were not literal
    let files = try await status(git, dir).files
    #expect(Set(files.map(\.kind)) == [.modified, .deleted, .added, .renamed, .untracked])

    try await git.discard(files, hasHead: true, in: dir, trash: trash)

    #expect(try await status(git, dir).files.isEmpty)
    #expect(read("mod.txt", in: dir) == "m\n")
    #expect(read("del.txt", in: dir) == "d\n")
    #expect(read("old.txt", in: dir) == "x\ny\nz\n")
    #expect(read("added.txt", in: dir) == nil)
    #expect(read("new.txt", in: dir) == nil)
    let kept = try trashed(bin)
    #expect(read("mod.txt", in: kept) == "m2\n")
    #expect(read("added.txt", in: kept) == "new\n")
    #expect(read("new.txt", in: kept) == "x\ny\nz\nw\n")
    #expect(read("sub dir/u*.txt", in: kept) == "mine\n")
}

@Test func aDiscardThatCannotKeepACopyChangesNothing() async throws {
    let (git, dir) = try await repo(["a.txt": "a\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("a2\n", "a.txt", in: dir)
    struct Full: Error {}

    await #expect(throws: Full.self) {
        try await git.discard(
            try await status(git, dir).files, hasHead: true, in: dir, trash: { _ in throw Full() })
    }
    #expect(read("a.txt", in: dir) == "a2\n")
}

/// The changed lines of `path`'s diff whose text is one of `texts`, marker included ("+x").
private func diff(of path: String, _ git: Git, _ dir: URL) async throws -> (FileChange, FileDiff) {
    let change = try #require(try await status(git, dir).files.first { $0.path == path })
    let (args, allowed) = FileDiff.arguments(for: change, hasHead: true)
    return (change, FileDiff(parsing: try await git.run(args, in: dir, allowedExitCodes: allowed).stdout))
}

private func discard(_ texts: Set<String>, of path: String, _ git: Git, _ dir: URL, _ trash: Trash)
    async throws
{
    let (change, d) = try await diff(of: path, git, dir)
    let picked = Set(
        d.changedLines.filter { texts.contains((d.lines[$0].kind == .added ? "+" : "-") + d.lines[$0].text) })
    #expect(picked.count == texts.count)
    try await git.discardLines(picked, of: change, in: d, hasHead: true, in: dir, trash: trash)
}

@Test func discardingLinesLeavesTheOtherLines() async throws {
    let (git, dir) = try await repo([
        "two.txt": "1\n2\n3\n4\n5\n6\n7\n8\n9\n", "mixed.txt": "a\nb\nc\n", "back.txt": "a\nb\nc\n",
        "tail.txt": "1\n2",
    ])
    let (bin, trash) = try trashFolder()
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }
    try write("1\nX\n3\n4\n5\n6\n7\n8\nY\n", "two.txt", in: dir)  // two hunks
    try write("a\nB\nc\nd\n", "mixed.txt", in: dir)  // one hunk: -b +B, then +d
    try write("a\nB\nc\nd\n", "back.txt", in: dir)
    try write("1\n3", "tail.txt", in: dir)  // [" 1", "-2", "\", "+3", "\"]
    try write("one\ntwo\n", "new file.txt", in: dir)  // untracked

    try await discard(["-2", "+X"], of: "two.txt", git, dir, trash)
    try await discard(["+B"], of: "mixed.txt", git, dir, trash)  // the removal of b stays
    try await discard(["-b", "+d"], of: "back.txt", git, dir, trash)  // b comes back, B stays
    try await discard(["-2"], of: "tail.txt", git, dir, trash)  // 2 comes back, and needs a newline
    try await discard(["+two"], of: "new file.txt", git, dir, trash)

    #expect(read("two.txt", in: dir) == "1\n2\n3\n4\n5\n6\n7\n8\nY\n")
    #expect(read("mixed.txt", in: dir) == "a\nc\nd\n")
    #expect(read("back.txt", in: dir) == "a\nb\nB\nc\n")
    #expect(read("tail.txt", in: dir) == "1\n2\n3")
    #expect(read("new file.txt", in: dir) == "one\n")
    let copies = try FileManager.default.contentsOfDirectory(atPath: bin.path)
    #expect(copies.count == 5)
}

@Test func linesChosenInAnOlderDiffAreNotDiscarded() async throws {
    let (git, dir) = try await repo(["f.txt": "1\n"])
    let (bin, trash) = try trashFolder()
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }
    try write("1\n2\n3\n", "f.txt", in: dir)
    let (change, d) = try await diff(of: "f.txt", git, dir)
    try write("1\n3\n", "f.txt", in: dir)

    await #expect(throws: DiscardError.changedSinceShown(path: "f.txt")) {
        try await git.discardLines(
            Set(d.changedLines.prefix(1)), of: change, in: d, hasHead: true, in: dir, trash: trash)
    }
    #expect(read("f.txt", in: dir) == "1\n3\n")
}

@Test func ignoredNamesAreMatchedLiterally() async throws {
    let (git, dir) = try await repo(["keep.txt": "k\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("old", ".gitignore", in: dir)  // no newline at the end
    let ignored = ["#notes", "!bang", "a*b.txt", "x[1].log", "back\\slash", "trail ", "sub/f.txt"]
    // What each pattern would also match if it were not escaped and anchored.
    let decoys = ["aXb.txt", "x1.log", "trail", "other/sub/f.txt"]
    for name in ignored + decoys { try write("x", name, in: dir) }

    for name in ignored { try Ignore.add(Ignore.pattern(forFile: name), in: dir) }
    try Ignore.add(Ignore.pattern(forFile: "a*b.txt"), in: dir)  // already there

    let untracked = try await status(git, dir).files.filter { $0.kind == .untracked }.map(\.path)
    #expect(Set(untracked) == Set(decoys + [".gitignore"]))
    let text = try #require(read(".gitignore", in: dir))
    #expect(text.hasPrefix("old\n/#notes\n"))
    #expect(text.hasSuffix("/trail\\ \n/sub/f.txt\n"))
    #expect(text.components(separatedBy: "a\\*b.txt").count == 2)
}

@Test func ignoringAnExtensionCreatesTheFile() async throws {
    let (git, dir) = try await repo(["keep.txt": "k\n"])
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["a.log", "deep/b.log", "c.txt"] { try write("x", name, in: dir) }

    try Ignore.add(
        Ignore.pattern(forExtension: try #require(Ignore.fileExtension(of: "deep/b.log"))), in: dir)

    #expect(read(".gitignore", in: dir) == "*.log\n")
    let untracked = try await status(git, dir).files.map(\.path)
    #expect(untracked == [".gitignore", "c.txt"])
}
