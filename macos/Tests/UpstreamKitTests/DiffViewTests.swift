import Foundation
import Testing

@testable import UpstreamKit

// The diff view's parts that need no window (docs/plans/007_the_diff_view.md):
// word highlights, the split rows, hidden whitespace, the size guards and
// image loading. Against fixtures/git/ and the installed git.

private func fixture(_ name: String) throws -> FileDiff {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return FileDiff(
        parsing: try Data(contentsOf: root.appending(path: "fixtures/git/\(name)")),
        ignoringWhitespace: name.hasSuffix("-w.patch"))
}

/// A scratch folder; a repository with `files` committed when `commit` is set.
private func scratch(_ files: [String: Data] = [:], commit: Bool = true) async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    for (key, value) in ["user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false"] {
        try await git.run(["config", key, value], in: dir)
    }
    for (path, data) in files { try data.write(to: dir.appending(path: path)) }
    if commit {
        try await git.run(["add", "."], in: dir)
        try await git.run(["commit", "-qm", "base"], in: dir)
    }
    return (git, dir)
}

/// What git prints for a file that is new, as an untracked file's diff.
private func newFileDiff(_ text: String) async throws -> FileDiff {
    let (git, dir) = try await scratch(commit: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(text.utf8).write(to: dir.appending(path: "f.txt"))
    let change = FileChange(path: "f.txt", index: nil, worktree: .untracked)
    let (args, allowed) = FileDiff.arguments(for: change, hasHead: false)
    return FileDiff(parsing: try await git.run(args, in: dir, allowedExitCodes: allowed).stdout)
}

/// The parts of `s` at UTF-16 `ranges`.
private func parts(_ s: String, _ ranges: [Range<Int>]) -> [String] {
    let u = Array(s.utf16)
    return ranges.map { String(decoding: u[$0], as: UTF16.self) }
}

/// Waits for `condition`, which the model reaches in a task of its own.
@MainActor private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

// MARK: Word highlights

@Test func theWordsOfAnEditedBlockAreFound() throws {
    // [@@, "-let total = price * count", "-return total",
    //  "+let total = price * quantity", "+return total + tax", " keep"]
    let diff = try fixture("diff-words.patch")
    #expect(diff.partners == [1: 3, 3: 1, 2: 4, 4: 2])
    let first = try #require(WordDiff.changes(old: diff.lines[1].text, new: diff.lines[3].text))
    #expect(parts(diff.lines[1].text, first.old) == ["count"])
    #expect(parts(diff.lines[3].text, first.new) == ["quantity"])
    let second = try #require(WordDiff.changes(old: diff.lines[2].text, new: diff.lines[4].text))
    #expect(second.old.isEmpty)
    #expect(parts(diff.lines[4].text, second.new) == [" + tax"])
}

@Test func wordHighlightsGiveUpWhereTheyWouldCostOrSayNothing() throws {
    // Too long to be written by hand.
    let long = String(repeating: "a ", count: WordDiff.maxLength)
    #expect(WordDiff.changes(old: long, new: long + "b") == nil)
    // Nothing but the spaces in common.
    #expect(WordDiff.changes(old: "alpha beta gamma", new: "one two three") == nil)
    // Half the words changed in a long line: more edits than `maxEdits`,
    // given up on quickly rather than worked through.
    let words = (0..<250).map { "w\($0 % 10)" }
    let old = words.joined(separator: " ")
    let new = words.enumerated().map { $0.offset.isMultiple(of: 2) ? "zz" : $0.element }.joined(
        separator: " ")
    let start = ContinuousClock.now
    #expect(WordDiff.changes(old: old, new: new) == nil)
    #expect(ContinuousClock.now - start < .milliseconds(200))
}

// MARK: Split view

@Test func theSplitViewPairsChangesAndKeepsMarkersOnTheirSide() throws {
    let rows = { (name: String) in try fixture(name).splitRows.map { [$0.old, $0.new] } }
    #expect(try rows("diff-words.patch") == [[0, 0], [1, 3], [2, 4], [5, 5]])
    // [@@, "-no newline", "\", "+no newline, changed", "\"]
    #expect(try rows("diff-no-newline.patch") == [[0, 0], [1, 3], [2, 4]])
    // [@@, " if ok {", "-run()", "+    run()", "+    stop()", " }"]
    #expect(try rows("diff-whitespace.patch") == [[0, 0], [1, 1], [2, 3], [nil, 4], [5, 5]])
}

// MARK: Hidden whitespace

@Test func aDiffWithoutWhitespaceCannotHaveLinesChosen() throws {
    let change = FileChange(path: "f", index: nil, worktree: .modified)
    #expect(FileDiff.arguments(for: change, hasHead: true, ignoringWhitespace: true).args.contains("-w"))
    #expect(try fixture("diff-whitespace.patch").canSelectLines)
    let hidden = try fixture("diff-whitespace-w.patch")
    #expect(hidden.ignoresWhitespace)
    #expect(!hidden.canSelectLines)
    #expect(hidden.changedLines.map { hidden.lines[$0].text } == ["    stop()"])
}

@MainActor @Test func hidingWhitespaceLeavesTheChosenLinesAlone() async throws {
    let (git, dir) = try await scratch(["f.txt": Data("if ok {\nrun()\n}\n".utf8)])
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("if ok {\n    run()\n    stop()\n}\n".utf8).write(to: dir.appending(path: "f.txt"))
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()
    let change = try #require(model.status?.files.first)
    model.selectedFile = change.id
    try await until { model.diff != nil }
    model.toggleLines([4])  // uncheck "+    stop()"
    let chosen = model.selection(of: change)
    guard case .lines = chosen else {
        Issue.record("f.txt should be partly checked")
        return
    }

    model.hidesWhitespace = true
    try await until { model.diff?.ignoresWhitespace == true }
    model.toggleLines([2])  // nothing: lines cannot be chosen in this diff
    #expect(model.selection(of: change) == chosen)

    // The diff shown is not the one the lines were chosen in, yet the file
    // is not unchecked for it, and showing whitespace again finds them.
    model.hidesWhitespace = false
    try await until { model.diff?.ignoresWhitespace == false }
    #expect(model.selection(of: change) == chosen)
}

// MARK: Size

@Test func aLargeDiffIsOneOfManyLinesOrManyBytes() async throws {
    let lines = { (n: Int) in (0..<n).map { "line \($0)\n" }.joined() }
    // One hunk header and the lines: 20,001 is past the threshold, 10,001 not.
    #expect(try await newFileDiff(lines(FileDiff.largeLines)).isLarge)
    #expect(try await !newFileDiff(lines(10_000)).isLarge)
    // Three lines of minified code, but more than `largeBytes`.
    let wide = String(repeating: "x", count: FileDiff.largeBytes / 3 + 1)
    #expect(try await newFileDiff("\(wide)\n\(wide)\n\(wide)\n").isLarge)
}

@Test func gitIsStoppedAtTheByteLimit() async throws {
    let (git, dir) = try await scratch(commit: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(repeating: UInt8(ascii: "x"), count: 4 << 20).write(to: dir.appending(path: "big"))
    let limit = 256 << 10
    // `diff --no-index` exits 1 for a difference; stopped, it is not checked.
    let result = try await git.run(["diff", "--no-index", "--", "/dev/null", "big"], in: dir, limit: limit)
    #expect(result.truncated)
    #expect(result.stdout.count <= limit + (64 << 10))  // at most one read past it
}

@MainActor @Test func aDiffPastTheCeilingIsNotReadWhole() async throws {
    let (git, dir) = try await scratch(["a.txt": Data("a\n".utf8)])
    defer { try? FileManager.default.removeItem(at: dir) }
    let line = Data(repeating: UInt8(ascii: "y"), count: 1023) + Data("\n".utf8)
    var big = Data()
    for _ in 0..<(FileDiff.byteCeiling / 1024 + 1) { big.append(line) }
    try big.write(to: dir.appending(path: "generated.txt"))
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()
    model.selectedFile = "generated.txt"
    try await until { model.diff != nil }
    #expect(model.diff?.exceedsCeiling == true)
    #expect(model.diff?.canSelectLines == false)
    #expect(model.selection(of: try #require(model.status?.files.first)) == .all)  // still commits whole
}

@Test func parsingATenThousandLineDiffIsQuick() async throws {
    let old = (0..<6_700).map { "let value\($0) = compute(\($0))\n" }.joined()
    let new = (0..<6_700).map { "let value\($0) = compute(\($0.isMultiple(of: 2) ? $0 : -$0))\n" }.joined()
    let (git, dir) = try await scratch(["f.swift": Data(old.utf8)])
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(new.utf8).write(to: dir.appending(path: "f.swift"))
    let change = FileChange(path: "f.swift", index: nil, worktree: .modified)
    let bytes = try await git.run(FileDiff.arguments(for: change, hasHead: true).args, in: dir).stdout

    let start = ContinuousClock.now
    let diff = FileDiff(parsing: bytes)
    _ = (diff.splitRows, diff.partners, diff.widestLine(cappedAt: 1_000))
    let elapsed = ContinuousClock.now - start
    #expect(diff.lines.count > 10_000)
    // Some 15 ms in a debug build, 2 ms in release; generous for a busy machine.
    #expect(elapsed < .seconds(1))
}

// MARK: Images

@Test func anImagesSidesComeFromHEADAndTheWorkingTree() async throws {
    let a = Data("old a".utf8)
    let b = Data("b, renamed".utf8)
    let (git, dir) = try await scratch(["a.png": a, "b.png": b, "gone.gif": Data("gone".utf8)])
    defer { try? FileManager.default.removeItem(at: dir) }
    let a2 = Data("new a".utf8)
    try a2.write(to: dir.appending(path: "a.png"))
    try await git.run(["mv", "b.png", "c.png"], in: dir)
    try FileManager.default.removeItem(at: dir.appending(path: "gone.gif"))
    try Data("added".utf8).write(to: dir.appending(path: "new.webp"))
    let files = RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout).files
    func images(_ path: String) async throws -> DiffImages {
        let change = try #require(files.first { $0.path == path })
        #expect(DiffImages.isImage(path))
        return await DiffImages.workingTree(change, hasHead: true, in: dir, git: git)
    }

    #expect(try await images("a.png") == DiffImages(old: a, new: a2))
    #expect(try await images("c.png") == DiffImages(old: b, new: b))  // HEAD's under the old name
    #expect(try await images("gone.gif") == DiffImages(old: Data("gone".utf8), new: nil))
    #expect(try await images("new.webp") == DiffImages(old: nil, new: Data("added".utf8)))
}
