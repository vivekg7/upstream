import Foundation
import Testing

@testable import UpstreamKit

// Against fixtures/git/, real git output that the Linux parser is tested
// against too. scripts/make-fixtures.sh rebuilds them.

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "fixtures/git/\(name)"))
}

@Test func statusReadsTheBranch() throws {
    let status = RepoStatus(parsing: try fixture("status-v2.z"))
    #expect(
        status.branch
            == BranchInfo(
                oid: "f29f4f40bc20d19c52c4ec5a45681750e72fc36d", head: "main", upstream: "origin/main",
                ahead: 1,
                behind: 1))
}

@Test func statusReadsEveryKindOfChange() throws {
    let files = RepoStatus(parsing: try fixture("status-v2.z")).files
    let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    #expect(files.count == 9)
    #expect(byPath["added.txt"]?.kind == .added)
    #expect(byPath["gone.txt"]?.kind == .deleted)
    #expect(byPath["keep.txt"]?.kind == .modified)
    #expect(byPath["staged.txt"].map { ($0.index, $0.worktree) } ?? (nil, nil) == (.modified, .modified))
    // A rename keeps its old path, and both may hold spaces.
    #expect(byPath["new name.txt"]?.kind == .renamed)
    #expect(byPath["new name.txt"]?.originalPath == "old name.txt")
    #expect(byPath["conflict.txt"]?.conflicted == true)
    // Raw UTF-8, not octal-quoted: core.quotepath does not apply to -z.
    #expect(byPath["ünïcode file.txt"]?.kind == .untracked)
}

@Test func diffNumbersEachLine() throws {
    let diff = FileDiff(parsing: try fixture("diff-modified.patch"))
    #expect(
        diff.lines == [
            DiffLine(kind: .hunk, text: "@@ -1,2 +1,3 @@"),
            DiffLine(kind: .context, text: "a", oldLine: 1, newLine: 1),
            DiffLine(kind: .removed, text: "b", oldLine: 2),
            DiffLine(kind: .added, text: "B", newLine: 2),
            DiffLine(kind: .added, text: "c", newLine: 3),
        ])
}

@Test func diffWithoutCountsOrFinalNewline() throws {
    let diff = FileDiff(parsing: try fixture("diff-no-newline.patch"))
    #expect(diff.lines.map(\.kind) == [.hunk, .removed, .noNewline, .added, .noNewline])
    #expect(diff.lines[1].oldLine == 1)
    #expect(diff.lines[3].newLine == 1)
}

@Test func diffOfAnUntrackedFile() throws {
    let diff = FileDiff(parsing: try fixture("diff-untracked.patch"))
    #expect(diff.lines.last == DiffLine(kind: .added, text: "u", newLine: 1))
}

@Test func diffOfABinaryFile() throws {
    let diff = FileDiff(parsing: try fixture("diff-binary.patch"))
    #expect(diff.isBinary)
    #expect(diff.lines.isEmpty)
}

// Cutting a partial commit out of a diff (docs/plans/003_the_checkbox_commit.md).

private func patch(_ name: String, selecting picked: Set<Int>) throws -> String? {
    let diff = FileDiff(parsing: try fixture(name))
    return diff.patch(selecting: picked).map { String(decoding: $0, as: UTF8.self) }
}

private let keepHeader = """
    diff --git a/keep.txt b/keep.txt
    index 422c2b7..7be73ce 100644
    --- a/keep.txt
    +++ b/keep.txt

    """

@Test func aPatchKeepsOnlyTheChosenLines() throws {
    // [@@, " a", "-b", "+B", "+c"]: only "+c". The unchosen removal stays
    // as context and the counts follow.
    #expect(try patch("diff-modified.patch", selecting: [4]) == keepHeader + "@@ -1,2 +1,3 @@\n a\n b\n+c\n")
    #expect(try patch("diff-modified.patch", selecting: [2]) == keepHeader + "@@ -1,2 +1,1 @@\n a\n-b\n")
    #expect(try patch("diff-modified.patch", selecting: []) == nil)
}

@Test func aPatchAfterALastLineWithoutANewline() throws {
    // [@@, "-no newline", "\\", "+no newline, changed", "\\"]. Keeping the
    // old last line but adding after it gives that line a newline, which
    // only a removal and re-addition can say.
    let marker = "\\ No newline at end of file\n"
    let added = try #require(try patch("diff-no-newline.patch", selecting: [3]))
    #expect(
        added.hasSuffix("@@ -1,1 +1,2 @@\n-no newline\n\(marker)+no newline\n+no newline, changed\n\(marker)")
    )
    let removed = try #require(try patch("diff-no-newline.patch", selecting: [1]))
    #expect(removed.hasSuffix("@@ -1,1 +0,0 @@\n-no newline\n\(marker)"))
}

@Test func whatCanBeCommittedInPart() throws {
    #expect(FileDiff(parsing: try fixture("diff-modified.patch")).canSelectLines)
    #expect(FileDiff(parsing: try fixture("diff-renamed.patch")).canSelectLines)
    #expect(FileDiff(parsing: try fixture("diff-untracked.patch")).canSelectLines)
    #expect(!FileDiff(parsing: try fixture("diff-binary.patch")).canSelectLines)
}

@Test func linesStagedInATerminalAreFound() throws {
    // [@@, " s", "-t", "+s2", "+s3"]: "-t" and "+s2" are staged, "+s3" is not.
    let diff = FileDiff(parsing: try fixture("diff-staged-head.patch"))
    let picked = diff.selection(
        staged: FileDiff(parsing: try fixture("diff-staged-cached.patch")),
        unstaged: FileDiff(parsing: try fixture("diff-staged-worktree.patch")))
    #expect(picked == [2, 3])
}
