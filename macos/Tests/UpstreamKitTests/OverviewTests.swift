import Foundation
import Testing

@testable import UpstreamKit

// Status on every row and Pull All (docs/plans/011_status_on_every_row.md),
// against the installed git in scratch repositories whose remotes are bare
// repositories on disk.

/// By its real path (`/private/var/…`), as git's `--show-toplevel` names
/// it in the repository list.
private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "upstream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return URL(fileURLWithPath: WatchFilter.real(dir), isDirectory: true)
}

private func configure(_ dir: URL, _ git: Git) async throws {
    for (key, value) in [
        "user.name": "Test", "user.email": "test@example.com", "commit.gpgsign": "false",
        "core.hooksPath": dir.appending(path: ".git/hooks").path,
    ] {
        try await git.run(["config", key, value], in: dir)
    }
}

private func write(_ text: String, _ path: String, in dir: URL) throws {
    try Data(text.utf8).write(to: dir.appending(path: path))
}

private func read(_ path: String, in dir: URL) throws -> String {
    String(decoding: try Data(contentsOf: dir.appending(path: path)), as: UTF8.self)
}

private func commit(_ path: String, _ text: String, _ git: Git, _ dir: URL) async throws {
    try write(text, path, in: dir)
    try await git.run(["add", "--", path], in: dir)
    try await git.run(["commit", "-qm", "change \(path)"], in: dir)
}

private func head(_ git: Git, _ dir: URL) async throws -> String {
    try await git.run(["rev-parse", "HEAD"], in: dir).text.trimmingCharacters(in: .newlines)
}

/// A bare origin with one commit ("f.txt", "g.txt" and a `.gitignore` for
/// `build/`), and a clone of it for `count` users.
private func clones(_ count: Int) async throws -> (Git, origin: URL, [URL]) {
    let git = try #require(Git.locate(), "no git on this machine")
    let origin = try scratch()
    try await git.run(["init", "-q", "--bare", "-b", "main"], in: origin)
    let seed = try scratch()
    try await git.run(["clone", "-q", origin.path, "."], in: seed)
    try await configure(seed, git)
    for (path, text) in ["f.txt": "1\n", "g.txt": "1\n", ".gitignore": "build/\n"] {
        try write(text, path, in: seed)
    }
    try await git.run(["add", "."], in: seed)
    try await git.run(["commit", "-qm", "base"], in: seed)
    try await git.run(["push", "-q", "origin", "HEAD:main"], in: seed)
    var dirs: [URL] = []
    for _ in 0..<count {
        let dir = try scratch()
        try await git.run(["clone", "-q", origin.path, "."], in: dir)
        try await configure(dir, git)
        dirs.append(dir)
    }
    return (git, origin, dirs)
}

/// Someone else pushes a change to `path` to `origin`.
private func push(_ path: String, _ text: String, to origin: URL, _ git: Git) async throws {
    let dir = try scratch()
    try await git.run(["clone", "-q", origin.path, "."], in: dir)
    try await configure(dir, git)
    try await commit(path, text, git, dir)
    try await git.run(["push", "-q", "origin", "HEAD:main"], in: dir)
}

/// The app with `repos` in its list and `selected` selected, its folders
/// and remotes read, and no timers.
@MainActor private func open(_ repos: [URL], selected: URL, _ git: Git) async throws -> AppModel {
    let model = AppModel(git: git, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
    model.branches.fetchInterval = nil
    model.overview.fetchInterval = nil
    for repo in repos { await model.add(repo) }
    model.selected = selected
    await model.refresh()
    await model.library.update()
    return model
}

@MainActor private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor @Test func aRepositoryNotSelectedShowsWhatToPushAndPullAndItsChanges() async throws {
    let (git, origin, dirs) = try await clones(2)
    let (selected, other) = (dirs[0], dirs[1])
    try await commit("f.txt", "mine\n", git, other)  // ahead 1
    try await push("g.txt", "theirs\n", to: origin, git)
    try await git.run(["fetch", "-q"], in: other)  // behind 1
    try write("new\n", "new.txt", in: other)  // untracked: a change
    let model = try await open(dirs, selected: selected, git)
    let rows = model.overview
    #expect(await eventually { rows.rows[other] != nil })
    #expect(rows.rows[other] == RowStatus(ahead: 1, behind: 1, hasChanges: true))
    // The selected row is the window's status, not a read of its own.
    #expect(rows.rows[selected] == RowStatus())
    let reads = rows.reads
    try write("x\n", "f.txt", in: selected)
    await model.refresh()
    #expect(rows.rows[selected] == RowStatus(hasChanges: true) && rows.reads == reads)
}

/// The stream reads a repository when something in it changes, and a
/// build writing into an ignored folder costs no read.
@MainActor @Test func aChangeOnDiskIsReadAndABuildIsNot() async throws {
    let (git, _, dirs) = try await clones(2)
    let (selected, other) = (dirs[0], dirs[1])
    let model = try await open(dirs, selected: selected, git)
    let rows = model.overview
    #expect(await eventually { rows.rows[other] == RowStatus() })
    // The stream starts with the first update; let it settle.
    try await Task.sleep(for: .seconds(1.5))
    let reads = rows.reads
    try FileManager.default.createDirectory(
        at: other.appending(path: "build"), withIntermediateDirectories: true)
    for i in 0..<20 { try write("\(i)\n", "build/out\(i).o", in: other) }
    try await Task.sleep(for: .seconds(2.5))
    #expect(rows.reads == reads)
    try write("edited\n", "g.txt", in: other)
    #expect(await eventually { rows.rows[other]?.hasChanges == true })
}

/// A repository fetched recently is not fetched again; one whose last
/// fetch is old is, and its ↓ appears.
@MainActor @Test func onlyARepositoryNotFetchedForAWhileIsFetched() async throws {
    let (git, origin, dirs) = try await clones(2)
    let (selected, other) = (dirs[0], dirs[1])
    try await git.run(["fetch", "-q"], in: other)  // FETCH_HEAD now
    let model = try await open(dirs, selected: selected, git)
    let rows = model.overview
    #expect(await eventually { rows.rows[other] == RowStatus() })
    try await push("g.txt", "theirs\n", to: origin, git)
    let tracked = try await git.run(["rev-parse", "origin/main"], in: other).text
    await rows.fetchDue()
    #expect(try await git.run(["rev-parse", "origin/main"], in: other).text == tracked)

    let fetchHead = other.appending(path: ".git/FETCH_HEAD").path
    try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: fetchHead)
    await rows.fetchDue()
    #expect(await eventually { rows.rows[other]?.behind == 1 })
    // Nothing was pulled: a fetch only.
    #expect(try read("g.txt", in: other) == "1\n")
}

/// Pull All fast-forwards a clean branch and one whose change no incoming
/// commit touches, and leaves alone, and lists, one with local commits and
/// one whose uncommitted change an incoming commit would overwrite.
@MainActor @Test func pullAllOnlyFastForwardsAndListsWhatItSkipped() async throws {
    let (git, origin, dirs) = try await clones(5)
    let (clean, unrelated, ahead, touched, current) = (dirs[0], dirs[1], dirs[2], dirs[3], dirs[4])
    try await commit("g.txt", "local\n", git, ahead)
    try write("my edit\n", "g.txt", in: unrelated)
    try write("my edit\n", "f.txt", in: touched)
    try await push("f.txt", "theirs\n", to: origin, git)
    // `current` is up to date after this, so it is not listed.
    try await git.run(["pull", "-q", "--ff-only"], in: current)
    let before = (ahead: try await head(git, ahead), touched: try await head(git, touched))

    let model = try await open(dirs, selected: clean, git)
    let rows = model.overview
    rows.startPullAll()
    #expect(await eventually(30) { rows.pullAll?.isFinished == true })
    let outcomes = Dictionary(
        uniqueKeysWithValues: (rows.pullAll?.outcomes ?? []).map { ($0.repository, $0.result) })
    #expect(outcomes[clean] == .pulled(commits: 1))
    #expect(outcomes[unrelated] == .pulled(commits: 1))
    #expect(outcomes[current] == nil)
    guard case .skipped = outcomes[ahead], case .skipped = outcomes[touched] else {
        Issue.record("not skipped: \(outcomes)")
        return
    }
    #expect(try read("f.txt", in: clean) == "theirs\n")
    #expect(try read("f.txt", in: unrelated) == "theirs\n" && read("g.txt", in: unrelated) == "my edit\n")
    #expect(try await head(git, ahead) == before.ahead)
    #expect(try await head(git, touched) == before.touched && read("f.txt", in: touched) == "my edit\n")
    // The selected repository's window caught up too.
    #expect(model.status?.branch.behind == 0)
    rows.dismissPullAll()
    #expect(rows.pullAll == nil)
}

@MainActor @Test func turnedOffNothingIsReadOrShown() async throws {
    let (git, _, dirs) = try await clones(2)
    let model = try await open(dirs, selected: dirs[0], git)
    let rows = model.overview
    #expect(await eventually { rows.rows[dirs[1]] != nil })
    rows.setOn(false)
    #expect(rows.rows.isEmpty)
    let reads = rows.reads
    try write("edited\n", "g.txt", in: dirs[1])
    await model.library.update()
    try await Task.sleep(for: .seconds(2))
    #expect(rows.reads == reads && rows.rows.isEmpty)
    // Kept across launches.
    #expect(model.defaults.object(forKey: "showsRepositoryStatus") as? Bool == false)
}
