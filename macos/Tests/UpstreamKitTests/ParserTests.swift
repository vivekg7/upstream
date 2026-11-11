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
                oid: "88d5962a3508cab01f4e0c5c3aeadd78b44d542c", head: "main", upstream: "origin/main",
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
    let diff = FileDiff(parsing: String(decoding: try fixture("diff-modified.patch"), as: UTF8.self))
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
    let diff = FileDiff(parsing: String(decoding: try fixture("diff-no-newline.patch"), as: UTF8.self))
    #expect(diff.lines.map(\.kind) == [.hunk, .removed, .noNewline, .added, .noNewline])
    #expect(diff.lines[1].oldLine == 1)
    #expect(diff.lines[3].newLine == 1)
}

@Test func diffOfAnUntrackedFile() throws {
    let diff = FileDiff(parsing: String(decoding: try fixture("diff-untracked.patch"), as: UTF8.self))
    #expect(diff.lines.last == DiffLine(kind: .added, text: "u", newLine: 1))
}

@Test func diffOfABinaryFile() throws {
    let diff = FileDiff(parsing: String(decoding: try fixture("diff-binary.patch"), as: UTF8.self))
    #expect(diff.isBinary)
    #expect(diff.lines.isEmpty)
}
