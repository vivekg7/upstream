import Foundation
import Testing

@testable import UpstreamKit

// Against the git installed on this machine: the fixtures pin the parsers,
// these pin how we call git.

private func scratchRepo() async throws -> (Git, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try await git.run(["init", "-q", "-b", "main"], in: dir)
    return (git, dir)
}

@Test func statusOfARealRepository() async throws {
    let (git, dir) = try await scratchRepo()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("hi\n".utf8).write(to: dir.appending(path: "new file.txt"))

    let status = RepoStatus(parsing: try await git.run(RepoStatus.arguments, in: dir).stdout)
    #expect(status.branch.head == "main")
    #expect(status.branch.oid == nil)
    #expect(status.files.map(\.path) == ["new file.txt"])

    let change = status.files[0]
    let (args, allowed) = FileDiff.arguments(for: change, hasHead: false)
    let diff = FileDiff(parsing: try await git.run(args, in: dir, allowedExitCodes: allowed).text)
    #expect(diff.lines.last == DiffLine(kind: .added, text: "hi", newLine: 1))
}

@Test func aFailingCommandThrowsWithGitsMessage() async throws {
    let (git, dir) = try await scratchRepo()
    defer { try? FileManager.default.removeItem(at: dir) }
    let error = await #expect(throws: GitError.self) {
        try await git.run(["rev-parse", "HEAD"], in: dir)
    }
    #expect(error?.status == 128)
    #expect(error?.message.isEmpty == false)
}

@Test func largeOutputDoesNotDeadlock() async throws {
    let (git, dir) = try await scratchRepo()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Far beyond a pipe's 64 KB buffer, on stderr first: read in turn
    // rather than together, stderr would fill while we wait on stdout.
    let result = try await git.run(
        ["-c", "alias.both=!yes | head -c 1000000 >&2; yes | head -c 1000000", "both"], in: dir)
    #expect(result.stdout.count == 1_000_000)
    #expect(result.stderr.count == 1_000_000)
}
