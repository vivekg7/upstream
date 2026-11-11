import Foundation
import Testing

@testable import UpstreamKit

// Branches, remotes and the stash (docs/plans/005_branches_and_remotes.md):
// the parsers against fixtures/git/, the rest against the installed git in
// scratch repositories whose remotes are bare repositories on disk.

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "fixtures/git/\(name)"))
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Its own identity, hooks folder and no signing, whatever the global config says.
private func configure(_ dir: URL, _ git: Git) async throws {
    for (key, value) in [
        "user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false",
        "core.hooksPath": dir.appending(path: ".git/hooks").path,
    ] {
        try await git.run(["config", key, value], in: dir)
    }
}

/// A repository with `files` committed as "base" on main, pushed to a bare
/// `origin` beside it.
private func repo(_ files: [String: String] = ["f.txt": "1\n"]) async throws -> (Git, URL, URL) {
    let git = try #require(Git.locate(), "no git on this machine")
    let dir = try scratch()
    let origin = try scratch()
    try await git.run(["init", "-q", "--bare", "-b", "main"], in: origin)
    try await git.run(["init", "-q", "-b", "main"], in: dir)
    try await configure(dir, git)
    for (path, text) in files { try write(text, path, in: dir) }
    try await git.run(["add", "."], in: dir)
    try await git.run(["commit", "-qm", "base"], in: dir)
    try await git.run(["remote", "add", "origin", origin.path], in: dir)
    try await git.run(["push", "-qu", "origin", "main"], in: dir)
    return (git, dir, origin)
}

/// Someone else's clone of `origin`.
private func clone(_ origin: URL, _ git: Git) async throws -> URL {
    let dir = try scratch()
    try await git.run(["clone", "-q", origin.path, "."], in: dir)
    try await configure(dir, git)
    return dir
}

private func write(_ text: String, _ path: String, in dir: URL) throws {
    try Data(text.utf8).write(to: dir.appending(path: path))
}

private func read(_ path: String, in dir: URL) throws -> String {
    String(decoding: try Data(contentsOf: dir.appending(path: path)), as: UTF8.self)
}

private func commit(_ path: String, _ text: String, _ message: String, _ git: Git, _ dir: URL) async throws {
    try write(text, path, in: dir)
    try await git.run(["add", "--", path], in: dir)
    try await git.run(["commit", "-qm", message], in: dir)
}

private func rev(_ name: String, _ git: Git, _ dir: URL) async throws -> String {
    try await git.run(["rev-parse", name], in: dir).text.trimmingCharacters(in: .newlines)
}

/// The app on `dir`, with background fetching off so nothing races the test.
@MainActor private func open(_ dir: URL, _ git: Git) async throws -> AppModel {
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    model.branches.fetchInterval = nil
    await model.add(dir)
    await update(model)
    return model
}

@MainActor private func update(_ model: AppModel) async {
    await model.refresh()
    await model.branches.reload()
}

@MainActor private func branch(_ name: String, _ model: AppModel) throws -> Branch {
    try #require(model.branches.all.first { $0.name == name }, "no branch \(name)")
}

private func cleanUp(_ dirs: URL...) {
    for dir in dirs { try? FileManager.default.removeItem(at: dir) }
}

// MARK: Parsers

@Test func theBranchListReadsUpstreamsAndSkipsSymrefs() throws {
    let branches = Branch.parse(try fixture("branches.z"), remotes: ["origin"])
    let byName = Dictionary(uniqueKeysWithValues: branches.map { ($0.name, $0) })
    // origin/HEAD is a symref, not a branch.
    #expect(branches.map(\.name) == ["feature/slash", "gone", "main", "theirs", "origin/main"])
    let main = try #require(byName["main"])
    #expect(main.isHead)
    #expect(main.upstream == "refs/remotes/origin/main")
    #expect(main.upstreamRemote == "origin")
    #expect(main.upstreamMerge == "refs/heads/main")
    #expect(main.track == .diverged)
    #expect(main.date == Date(timeIntervalSince1970: 1_767_225_600))
    #expect(byName["feature/slash"]?.track == .same)
    #expect(byName["theirs"]?.upstream == nil)
    #expect(byName["theirs"]?.upstreamGone == false)
    #expect(byName["gone"]?.upstreamGone == true)
    let remote = try #require(byName["origin/main"])
    #expect(remote.isRemote && remote.remote == "origin" && remote.nameOnRemote == "main")
}

@Test func mergeTreeNamesTheConflictedFiles() throws {
    #expect(MergePreview.conflicts(parsing: try fixture("merge-tree-conflict.z")) == ["conflict.txt"])
    #expect(MergePreview.conflicts(parsing: try fixture("merge-tree-clean.z")) == [])
}

@Test func onlyUpstreamsOwnStashesBelongToTheBranch() throws {
    let entries = StashEntry.parse(try fixture("stash-list.z"))
    #expect(entries.count == 2)
    #expect(entries[0].belongs(to: "main"))
    #expect(!entries[0].belongs(to: "mai"))
    #expect(!entries[1].belongs(to: "main"))  // made in a terminal
    #expect(RepoStatus(parsing: try fixture("status-v2-stash.z")).stashCount == 2)
}

// MARK: Switching and the stash

@MainActor @Test func changesComeAlongOrStayBehindInAStash() async throws {
    let (git, dir, origin) = try await repo(["f.txt": "1\n", "g.txt": "g\n"])
    defer { cleanUp(dir, origin) }
    try await git.run(["branch", "other"], in: dir)
    let model = try await open(dir, git)
    try write("changed\n", "f.txt", in: dir)
    try write("new\n", "new.txt", in: dir)

    await model.branches.switchTo(try branch("other", model))  // bring them
    #expect(model.status?.branch.head == "other")
    #expect(model.status?.files.map(\.path) == ["f.txt", "new.txt"])

    await model.branches.switchTo(try branch("main", model), leavingChanges: true)
    #expect(model.error == nil)
    #expect(model.status?.branch.head == "main")
    #expect(model.status?.files == [])  // untracked ones too
    #expect(model.branches.stashes == [])  // the stash is other's

    await model.branches.switchTo(try branch("other", model))
    #expect(model.branches.stashes.count == 1)
    await model.branches.restoreStash()
    #expect(model.error == nil)
    #expect(try read("f.txt", in: dir) == "changed\n")
    #expect(try read("new.txt", in: dir) == "new\n")
    #expect(model.branches.stashes == [])
}

@MainActor @Test func aSwitchGitRefusesChangesNothing() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    try await git.run(["switch", "-qc", "other"], in: dir)
    try await commit("f.txt", "other\n", "other", git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    let model = try await open(dir, git)
    try write("mine\n", "f.txt", in: dir)  // would be overwritten

    await model.branches.switchTo(try branch("other", model))

    #expect(model.error?.contains("f.txt") == true)  // git's own words
    #expect(model.status?.branch.head == "main")
    #expect(try read("f.txt", in: dir) == "mine\n")
}

@MainActor @Test func aConflictingRestoreKeepsTheStash() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    let model = try await open(dir, git)
    try write("stashed\n", "f.txt", in: dir)
    await update(model)
    await model.branches.stashChanges()
    try await commit("f.txt", "committed\n", "meanwhile", git, dir)
    await update(model)

    await model.branches.restoreStash()

    #expect(model.error?.contains("the stash is kept") == true)
    #expect(model.status?.files.first?.conflicted == true)
    #expect(model.branches.stashes.count == 1)
}

@MainActor @Test func checkingOutARemoteBranchTracksIt() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    try await git.run(["branch", "topic"], in: dir)
    try await git.run(["push", "-q", "origin", "topic"], in: dir)
    try await git.run(["branch", "-qD", "topic"], in: dir)
    let model = try await open(dir, git)

    await model.branches.switchTo(try branch("origin/topic", model))

    #expect(model.error == nil)
    #expect(model.status?.branch.head == "topic")
    #expect(model.status?.branch.upstream == "origin/topic")
}

// MARK: Creating and deleting

@MainActor @Test func aBranchCreatedFromARemoteOneIsPublishedNotPushedIntoIt() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    let model = try await open(dir, git)

    await model.branches.create("feature", from: try branch("origin/main", model))

    #expect(model.status?.branch.head == "feature")
    #expect(model.status?.branch.upstream == nil)  // not origin/main, whatever branch.autoSetupMerge says
    #expect(model.branches.action == .publish)
    await model.branches.publish(to: "origin")
    #expect(model.error == nil)
    #expect(model.status?.branch.upstream == "origin/feature")
    #expect(try await rev("feature", git, origin) == rev("HEAD", git, dir))
    #expect(model.branches.action == .fetch)
}

@MainActor @Test func deletingAnUnmergedBranchSaysWhatIsLost() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    try await git.run(["branch", "merged"], in: dir)
    try await git.run(["switch", "-qc", "unmerged"], in: dir)
    try await commit("u.txt", "u\n", "only here", git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    let model = try await open(dir, git)

    #expect(
        await model.branches.deletion(of: try branch("merged", model)) == Deletion(unmerged: 0, into: "main"))
    let unmerged = try branch("unmerged", model)
    #expect(await model.branches.deletion(of: unmerged) == Deletion(unmerged: 1, into: "main"))

    await model.branches.delete(unmerged, force: false)  // what -d alone would do
    #expect(model.error != nil)
    #expect(model.branches.all.contains { $0.name == "unmerged" })
    await model.branches.delete(unmerged, force: true)
    #expect(model.error == nil)
    #expect(!model.branches.all.contains { $0.name == "unmerged" })
}

@MainActor @Test func deletingAlsoOnTheRemote() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    try await git.run(["branch", "done"], in: dir)
    try await git.run(["push", "-qu", "origin", "done"], in: dir)
    let model = try await open(dir, git)

    await model.branches.delete(try branch("done", model), force: false, alsoRemote: true)

    #expect(model.error == nil)
    let left = try await git.run(["for-each-ref", "--format=%(refname)"], in: origin).text
    #expect(left == "refs/heads/main\n")
    #expect(!model.branches.all.contains { $0.name == "origin/done" })
}

// MARK: Merging

@MainActor @Test func thePreviewFindsAConflictAndACleanMerge() async throws {
    let (git, dir, origin) = try await repo(["f.txt": "1\n", "g.txt": "g\n"])
    defer { cleanUp(dir, origin) }
    try await git.run(["switch", "-qc", "clash"], in: dir)
    try await commit("f.txt", "clash\n", "clash", git, dir)
    try await git.run(["switch", "-qc", "clean", "main"], in: dir)
    try await commit("g.txt", "clean\n", "clean", git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit("f.txt", "main\n", "main", git, dir)
    let model = try await open(dir, git)

    let clash = try await model.branches.preview(.merge, try branch("clash", model))
    #expect(clash == MergePreview(incoming: 1, outgoing: 1, conflicts: ["f.txt"]))
    let clean = try await model.branches.preview(.squash, try branch("clean", model))
    #expect(clean == MergePreview(incoming: 1, outgoing: 1, conflicts: []))
    let rebase = try await model.branches.preview(.rebase, try branch("clean", model))
    #expect(rebase.conflicts == nil)
    #expect(try await rev("HEAD", git, dir) == rev("main", git, dir))  // nothing touched
    #expect(model.status?.files == [])
}

@MainActor @Test func aConflictedMergeIsLeftForTheUserAndASquashIsLeftToCommit() async throws {
    let (git, dir, origin) = try await repo(["f.txt": "1\n", "g.txt": "g\n"])
    defer { cleanUp(dir, origin) }
    try await git.run(["switch", "-qc", "clash"], in: dir)
    try await commit("f.txt", "clash\n", "clash", git, dir)
    try await git.run(["switch", "-qc", "clean", "main"], in: dir)
    try await commit("g.txt", "clean\n", "clean", git, dir)
    try await git.run(["switch", "-q", "main"], in: dir)
    try await commit("f.txt", "main\n", "main", git, dir)
    let model = try await open(dir, git)
    let head = try await rev("HEAD", git, dir)

    await model.branches.merge(.squash, try branch("clean", model))
    #expect(model.error == nil)
    #expect(try await rev("HEAD", git, dir) == head)  // the user commits it
    #expect(model.status?.files.map(\.path) == ["g.txt"])
    try await git.run(["commit", "-qm", "squashed"], in: dir)

    await model.branches.merge(.merge, try branch("clash", model))
    #expect(model.error != nil)
    #expect(model.status?.files.first?.conflicted == true)
    _ = try await git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: dir)  // still merging
}

// MARK: Remotes

@MainActor @Test func fetchPullAndPushAgainstABareRemote() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    let other = try await clone(origin, git)
    defer { cleanUp(other) }
    try await commit("theirs.txt", "t\n", "theirs", git, other)
    try await git.run(["push", "-q"], in: other)
    let model = try await open(dir, git)
    #expect(model.branches.action == .fetch)

    await model.branches.fetch()
    #expect(model.status?.branch.behind == 1)
    #expect(model.branches.lastFetched != nil)
    #expect(model.branches.action == .pull)

    await model.branches.pull()
    #expect(model.error == nil)
    #expect(model.status?.branch.behind == 0)

    try await commit("mine.txt", "m\n", "mine", git, dir)
    await update(model)
    #expect(model.branches.action == .push)
    await model.branches.push()
    #expect(model.error == nil)
    #expect(try await rev("main", git, origin) == rev("HEAD", git, dir))
}

@MainActor @Test func aForcePushNeverOverwritesWorkItHasNotSeen() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    try await commit("f.txt", "2\n", "pushed", git, dir)
    try await git.run(["push", "-q"], in: dir)
    let model = try await open(dir, git)

    // Amend a pushed commit: diverged, and the upstream's tip was ours.
    try await git.run(["commit", "-q", "--amend", "-m", "amended"], in: dir)
    await update(model)
    #expect(model.branches.upstreamRewritten)
    #expect(model.branches.action == .forcePush)
    #expect(await model.branches.forcePushOverwrites() == ["pushed"])
    await model.branches.forcePush()
    #expect(model.error == nil)
    #expect(try await rev("main", git, origin) == rev("HEAD", git, dir))

    // Someone pushes on top; we amend again without having fetched.
    let other = try await clone(origin, git)
    defer { cleanUp(other) }
    try await commit("theirs.txt", "t\n", "theirs", git, other)
    try await git.run(["push", "-q"], in: other)
    try await git.run(["commit", "-q", "--amend", "-m", "amended again"], in: dir)
    await update(model)
    let theirs = try await rev("main", git, origin)

    await model.branches.forcePush()  // --force-with-lease: the remote moved
    #expect(model.error != nil)
    #expect(try await rev("main", git, origin) == theirs)

    // A background fetch makes the lease match; their commit is still not ours.
    await model.branches.fetch()
    await model.branches.forcePush()  // --force-if-includes
    #expect(model.error != nil)
    #expect(try await rev("main", git, origin) == theirs)
    #expect(model.branches.action == .pull)  // their commit was never on this branch
}

@MainActor @Test func aRepositoryNeverFetchedIsFetchedWhenItOpens() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    let other = try await clone(origin, git)
    defer { cleanUp(other) }
    try await commit("theirs.txt", "t\n", "theirs", git, other)
    try await git.run(["push", "-q"], in: other)

    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    model.branches.fetchInterval = .seconds(3600)
    await model.add(dir)

    let end = Date().addingTimeInterval(10)
    while model.status?.branch.behind != 1 || model.branches.lastFetched == nil, Date() < end {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.status?.branch.behind == 1)
    #expect(model.branches.lastFetched != nil)
    model.setActive(false)  // stops the loop; nothing runs in the background
}

/// The background fetch repeats while the app is in front and stops the
/// moment it is not: behind other apps it costs no network at all.
@MainActor @Test func theBackgroundFetchRepeatsInFrontAndStopsBehind() async throws {
    let (git, dir, origin) = try await repo()
    defer { cleanUp(dir, origin) }
    let fetchHead = dir.appending(path: ".git/FETCH_HEAD")
    func fetched() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fetchHead.path))?[.modificationDate] as? Date
    }
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    model.branches.fetchInterval = .seconds(1)
    await model.add(dir)

    let end = Date().addingTimeInterval(10)
    while fetched() == nil, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    let first = try #require(fetched())
    while fetched() == first, Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    #expect(fetched() != first)  // fetched again a second later

    model.setActive(false)
    try await Task.sleep(for: .milliseconds(300))  // a fetch already running finishes
    let behind = fetched()
    try await Task.sleep(for: .seconds(2.5))
    #expect(fetched() == behind)
}
