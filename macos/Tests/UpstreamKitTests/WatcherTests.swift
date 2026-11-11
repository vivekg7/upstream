import Foundation
import Testing

@testable import UpstreamKit

// Refreshing on file changes (docs/plans/004_refreshing_on_file_changes.md).

@Test func onlyTheGitFilesThatChangeWhatIsShownCount() {
    let filter = WatchFilter(
        workTree: URL(fileURLWithPath: "/r"),
        gitDirs: [URL(fileURLWithPath: "/r/.git"), URL(fileURLWithPath: "/r/.git/worktrees/w")])
    let (git, tree) = filter.relevant([
        "/r/.git/objects/ab/cdef", "/r/.git/index.lock", "/r/.git/logs/HEAD", "/r/.git/FETCH_HEAD",
        "/r/.git/index", "/r/.git/refs/heads/main", "/r/.git/MERGE_HEAD",
        "/r/.git/worktrees/w/index",  // a linked worktree's own index, not "worktrees/…" noise
        "/r/src/a.swift", "/elsewhere/x",
    ])
    #expect(git == ["index", "refs/heads/main", "MERGE_HEAD", "index"])
    #expect(tree == ["src/a.swift"])
}

/// Waits up to `seconds` for `condition`, checking every 50 ms.
@MainActor private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor @Test func anEditIsSeenWithoutAskingAndAnIgnoredBuildIsNot() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    // Under /var, which FSEvents reports as /private/var.
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    try Data("build/\n".utf8).write(to: dir.appending(path: ".gitignore"))
    try FileManager.default.createDirectory(
        at: dir.appending(path: "build"), withIntermediateDirectories: true)

    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()
    #expect(model.status?.files.map(\.path) == [".gitignore"])
    try await Task.sleep(for: .milliseconds(500))  // the watcher starts

    try Data("x".utf8).write(to: dir.appending(path: "new.txt"))
    #expect(await eventually { model.status?.files.map(\.path) == [".gitignore", "new.txt"] })

    try await Task.sleep(for: .milliseconds(800))  // let the last batch settle
    let reads = model.statusReads
    for k in 0..<20 { try Data("\(k)".utf8).write(to: dir.appending(path: "build/out-\(k).o")) }
    try await Task.sleep(for: .seconds(1.5))
    #expect(model.statusReads == reads)
}

@MainActor @Test func aBurstOfRefreshesRunsStatusAtMostTwice() async throws {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    await model.add(dir)
    await model.refresh()

    let before = model.statusReads
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 { group.addTask { await model.refresh() } }
    }
    // One round if they all arrive before it starts, two if some arrive
    // while it runs; never one each.
    #expect((1...2).contains(model.statusReads - before))
}
