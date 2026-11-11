import Foundation
import Testing

@testable import UpstreamKit

// A merge or rebase that stopped on a conflict, against the installed git
// (docs/plans/008_discard_ignore_and_conflicts.md).

/// A repository whose `main` and `feature` both changed f.txt from "base":
/// `main` to `ours`, `feature` to `theirs` (nil deletes it). Left on `main`.
private func conflicting(ours: String?, theirs: String?) async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    for (key, value) in [
        "user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false",
        "core.hooksPath": dir.appending(path: ".git/hooks").path, "merge.conflictStyle": "merge",
    ] {
        try await git.run(["config", key, value], in: dir)
    }
    func commit(_ text: String?, _ message: String) async throws {
        let url = dir.appending(path: "f.txt")
        if let text {
            try Data(text.utf8).write(to: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
        try await git.run(["add", "--all"], in: dir)
        try await git.run(["commit", "-qm", message], in: dir)
    }
    try await commit("base\n", "base")
    try await git.run(["switch", "-qc", "feature"], in: dir)
    try await commit(theirs, "theirs")
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit(ours, "ours")
    return (git, dir)
}

private func read(_ path: String, in dir: URL) -> String? {
    (try? Data(contentsOf: dir.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
}

private func rev(_ name: String, _ git: Git, _ dir: URL) async throws -> String {
    try await git.run(["rev-parse", name], in: dir).text.trimmingCharacters(in: .newlines)
}

/// A model on `dir`, with discarded content going to a folder of the test's own.
@MainActor private func model(_ git: Git, _ dir: URL) async throws -> (AppModel, URL) {
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    let (bin, trash) = try trashFolder()
    model.trash = trash
    await model.add(dir)
    await model.refresh()
    return (model, bin)
}

@MainActor @Test func aMergeConflictResolvedWithOursCommitsWithTwoParents() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: "theirs\n")
    try await git.run(["merge", "feature"], in: dir, allowedExitCodes: [1])
    let (model, bin) = try await model(git, dir)
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }

    let operation = try #require(model.operation)
    #expect(operation.title(currentBranch: "main") == "Merging feature into main")
    // MERGE_MSG, without its "# Conflicts:" comment lines.
    #expect(model.draft.summary == "Merge branch 'feature'")
    #expect(model.draft.description == "")
    #expect(model.continueBlocker == "Resolve the conflicted file first.")
    #expect(model.commitBlocker != nil)

    await model.resolve(try #require(model.status?.files.first), taking: .ours)
    #expect(read("f.txt", in: dir) == "ours\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1)  // the markers, kept
    #expect(model.continueBlocker == nil)

    await model.continueOperation()

    #expect(model.error == nil)
    #expect(model.operation == nil)
    let parents = try await git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: dir).text.split(
        separator: " ")
    #expect(parents.count == 3)
    #expect(try await rev("HEAD^2", git, dir) == (try await rev("feature", git, dir)))
    #expect(model.draft.summary == "")
}

@Test func theCheckboxCommitIsRefusedDuringAMerge() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: "theirs\n")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["merge", "feature"], in: dir, allowedExitCodes: [1])
    try await git.run(["checkout", "--ours", "f.txt"], in: dir)
    try await git.run(["add", "f.txt"], in: dir)
    let head = try await rev("HEAD", git, dir)
    let files = RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout).files

    await #expect(throws: CommitError.operationInProgress(.merge)) {
        try await git.commit(files.map { ($0, .all) }, message: "m", amend: false, hasHead: true, in: dir)
    }
    #expect(try await rev("HEAD", git, dir) == head)
}

@MainActor @Test func aRebaseNamesOursAndTheirsByBranch() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: "theirs\n")
    try await git.run(["switch", "-q", "feature"], in: dir)
    try await git.run(["rebase", "main"], in: dir, allowedExitCodes: [1])
    let (model, bin) = try await model(git, dir)
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }

    let operation = try #require(model.operation)
    #expect(operation.title(currentBranch: nil) == "Rebasing feature onto main")
    // git's --ours, during a rebase, is the branch being rebased onto.
    #expect(operation.label(.ours, currentBranch: nil) == "main")
    #expect(operation.label(.theirs, currentBranch: nil) == "feature")

    await model.resolve(try #require(model.status?.files.first), taking: .theirs)
    #expect(read("f.txt", in: dir) == "theirs\n")
    await model.continueOperation()  // with no editor to open

    #expect(model.error == nil)
    #expect(model.operation == nil)
    #expect(try await rev("feature^", git, dir) == (try await rev("main", git, dir)))
}

@MainActor @Test func abortPutsTheBranchBack() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: "theirs\n")
    let head = try await rev("HEAD", git, dir)
    try await git.run(["merge", "feature"], in: dir, allowedExitCodes: [1])
    let (model, bin) = try await model(git, dir)
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }
    #expect(model.operation?.kind == .merge)

    await model.abortOperation()

    #expect(model.operation == nil)
    #expect(model.status?.files.isEmpty == true)
    #expect(try await rev("HEAD", git, dir) == head)
    #expect(read("f.txt", in: dir) == "ours\n")
    #expect(model.draft.summary == "")  // MERGE_MSG's prefill goes with the merge
}

@Test func aFileIsMarkedResolvedOnlyWithoutMarkers() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: "theirs\n")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["merge", "feature"], in: dir, allowedExitCodes: [1])

    await #expect(throws: ConflictError.markersRemain(path: "f.txt")) {
        try await git.markResolved("f.txt", in: dir)
    }
    // A Markdown heading's underline is not a marker.
    try Data("both\n=======\n".utf8).write(to: dir.appending(path: "f.txt"))
    try await git.markResolved("f.txt", in: dir)

    let files = RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout).files
    #expect(files.map(\.conflicted) == [false])
}

@Test func aFileDeletedOnOneSideIsKeptOrDeleted() async throws {
    let (git, dir) = try await conflicting(ours: "ours\n", theirs: nil)
    let (bin, trash) = try trashFolder()
    defer { for d in [dir, bin] { try? FileManager.default.removeItem(at: d) } }
    try await git.run(["merge", "feature"], in: dir, allowedExitCodes: [1])
    let conflict = try #require(
        RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout).files.first)
    #expect(conflict.conflicted && conflict.worktree == .deleted)  // UD: deleted by them

    try await git.resolve("f.txt", taking: .theirs, in: dir, trash: trash)

    #expect(read("f.txt", in: dir) == nil)
    let after = RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout).files
    #expect(after.map(\.conflicted) == [false])
    #expect(after.first?.kind == .deleted)
}
