import Foundation
import Observation

/// The repository list beyond the paths themselves: who owns each one, which
/// folders have gone missing, and cloning and creating repositories
/// (docs/plans/009_repositories_and_settings.md).
@MainActor @Observable
public final class LibraryModel: Feature {
    public weak var app: AppModel?

    /// Each repository's owner, from its remote URL. A repository with no
    /// remote on a host has no entry once `update` has read it.
    public private(set) var owners: [URL: RemoteOwner] = [:]
    /// Repositories whose folder is gone: moved, renamed or deleted.
    public private(set) var missing: Set<URL> = []
    /// Whether every repository's remotes have been read once, so the
    /// sidebar does not group them all under "Other" for a moment at launch.
    public private(set) var loaded = false
    public private(set) var gitVersion: GitVersion?
    /// The clone or create sheet, opened from the File menu or the sidebar.
    public var sheet: Sheet?
    private var read: Set<URL> = []
    private var askedVersion = false

    public enum Sheet: String, Identifiable, Sendable {
        case clone, create
        public var id: String { rawValue }
    }

    nonisolated init() {}

    /// Checks which folders exist, and reads the remotes of every repository
    /// not read yet and of the selected one. Remotes are read once per
    /// repository, not on every refresh: the sidebar's grouping is not worth
    /// a process per repository each time the app comes to the front. The
    /// selected one is read again because the user may just have added its
    /// remote, and one `git config` is nothing.
    public func update() async {
        guard let app, let git = app.git else { return }
        let repositories = app.repositories
        let gone = Set(repositories.filter { !Self.isDirectory($0) })
        if gone != missing { missing = gone }
        // A missing folder has nothing to show (its row cannot be selected
        // either), so the selection moves to one that is there.
        if let selected = app.selected, missing.contains(selected) {
            app.selected = repositories.first { !missing.contains($0) }
        }
        if !askedVersion {
            // Set before the await: the sidebar's updates overlap at launch.
            askedVersion = true
            if let version = await git.version() {
                gitVersion = version
                // Once per launch: an older git works until a feature that
                // needs it fails, so say so up front.
                if !version.isSupported { app.error = version.warning }
            }
        }
        let toRead = repositories.filter {
            !missing.contains($0) && (!read.contains($0) || $0 == app.selected)
        }
        let found = await withTaskGroup(of: (URL, RemoteOwner?).self) { group in
            for repo in toRead {
                group.addTask { (repo, RemoteOwner(remotes: (try? await git.remoteURLs(in: repo)) ?? [:])) }
            }
            var found: [(URL, RemoteOwner?)] = []
            for await pair in group { found.append(pair) }
            return found
        }
        // A read cut short by cancellation is not "no remote".
        guard !Task.isCancelled else { return }
        for (repo, owner) in found {
            if owners[repo] != owner { owners[repo] = owner }
            read.insert(repo)
        }
        loaded = true
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The repositories whose name or owner contains `filter`, grouped by
    /// owner in alphabetical order, with the ones that have no owner
    /// ("Other") last.
    public func groups(filter: String = "") -> [(owner: RemoteOwner?, repositories: [URL])] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let shown = (app?.repositories ?? []).filter { url in
            query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || owners[url]?.description.localizedCaseInsensitiveContains(query) == true
        }
        let grouped = Dictionary(grouping: shown) { owners[$0] }
        return grouped.keys.sorted { a, b in
            guard let a else { return false }
            guard let b else { return true }
            return a < b
        }.map { ($0, grouped[$0]!) }
    }

    /// Puts `new` in the list in place of the missing `old`, if it is a
    /// repository.
    public func locate(_ old: URL, at new: URL) async {
        guard let app else { return }
        app.error = nil
        await app.add(new)
        guard app.error == nil else { return }
        app.remove(old)
        await update()
    }

    /// Clones `url` into `directory`, then adds it to the list and selects it.
    /// Cancelling the task stops git and leaves no folder behind.
    public func clone(_ url: String, to directory: URL) async throws {
        guard let app, let git = app.git else { return }
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let network = await app.networkArguments(in: parent, remote: url)
        try await git.clone(url, to: directory, options: network)
        await app.add(directory)
    }

    /// Creates the repository, adds it and selects it. A failure after
    /// `git init` (a hook refusing the first commit, no identity set) still
    /// adds it, with the failure in `app.error`: the repository exists, and
    /// the user can finish the commit in it.
    public func create(_ new: NewRepository) async throws {
        guard let app, let git = app.git else { return }
        do {
            try await git.create(new)
        } catch {
            guard !(error is RepositoryError),
                FileManager.default.fileExists(atPath: new.directory.appending(path: ".git").path)
            else { throw error }
            await app.add(new.directory)
            app.error = error.localizedDescription
            return
        }
        await app.add(new.directory)
    }
}

/// Who a repository belongs to, read from a remote URL: its host and owner
/// path, such as github.com and "octocat", or gitlab.com and "group/subgroup".
/// Plain git, so it says nothing about which forge, if any, the host runs.
public struct RemoteOwner: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let host: String
    public let path: String

    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    /// From one of git's URL forms: `scheme://[user@]host[:port]/owner/repo`
    /// (https, ssh, git) or scp-like `[user@]host:owner/repo`. nil for a
    /// local path or a URL without an owner.
    public init?(remoteURL raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if url.contains("://") {
            guard let c = URLComponents(string: url), c.scheme != "file", let h = c.host, !h.isEmpty else {
                return nil
            }
            (host, path) = (h, c.path)
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            // git reads `a:b` as scp-like only when no slash comes before
            // the first colon; otherwise it is a local path.
            let authority = url[..<colon]
            host = String(authority.split(separator: "@").last ?? authority)
            path = String(url[url.index(after: colon)...])
        } else {
            return nil
        }
        var parts = path.split(separator: "/")
        guard !host.isEmpty, parts.count >= 2 else { return nil }
        parts.removeLast()  // the repository itself
        self.init(host: host.lowercased(), path: parts.joined(separator: "/"))
    }

    /// The owner of origin's URL, or else of the first remote by name that
    /// has one.
    init?(remotes: [String: String]) {
        let names = ["origin"] + remotes.keys.sorted()
        guard let owner = names.lazy.compactMap({ remotes[$0].flatMap(RemoteOwner.init(remoteURL:)) }).first
        else { return nil }
        self = owner
    }

    public var description: String { "\(host)/\(path)" }

    public static func < (a: Self, b: Self) -> Bool {
        let byPath = a.path.localizedCaseInsensitiveCompare(b.path)
        return byPath == .orderedSame ? a.host < b.host : byPath == .orderedAscending
    }
}

/// What the Create a Repository sheet asks for.
public struct NewRepository: Sendable {
    public var name: String
    public var parent: URL
    public var defaultBranch: String
    public var readme: Bool
    public var description: String
    /// A key of `Templates.gitignores`, or nil for none.
    public var gitignore: String?
    /// An id from `Templates.licenses`, or nil for none.
    public var license: String?
    /// The copyright holder the licence names.
    public var author: String

    public init(
        name: String, parent: URL, defaultBranch: String = "main", readme: Bool = false,
        description: String = "",
        gitignore: String? = nil, license: String? = nil, author: String = ""
    ) {
        self.name = name
        self.parent = parent
        self.defaultBranch = defaultBranch
        self.readme = readme
        self.description = description
        self.gitignore = gitignore
        self.license = license
        self.author = author
    }

    public var directory: URL {
        parent.appending(path: name.trimmingCharacters(in: .whitespaces), directoryHint: .isDirectory)
    }

    /// The files to write, by name.
    func files(year: Int) -> [(String, String)] {
        var files: [(String, String)] = []
        if readme {
            let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.trimmingCharacters(in: .whitespaces)
            files.append(("README.md", "# \(title)\n" + (about.isEmpty ? "" : "\n\(about)\n")))
        }
        if let gitignore, let text = Templates.gitignores[gitignore] { files.append((".gitignore", text)) }
        if let license, let found = Templates.licenses.first(where: { $0.id == license }) {
            files.append(("LICENSE", found.text(year: year, name: author)))
        }
        return files
    }
}

public enum RepositoryError: Error, LocalizedError, Equatable {
    case invalidName
    case alreadyRepository(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name for the folder, without a slash."
        case .alreadyRepository(let name): "“\(name)” is already a git repository. Add it instead (⌘O)."
        }
    }
}

/// The templates offered when creating a repository. Embedded rather than
/// fetched, so creating a repository talks to no one (Templates.swift has
/// the texts and their sources).
public enum Templates {
    public static let gitignores = Dictionary(uniqueKeysWithValues: gitignoreTexts.map { ($0.name, $0.text) })
    public static var gitignoreNames: [String] { gitignoreTexts.map(\.name) }
    public static let licenses = licenseTexts.map { License(id: $0.id, name: $0.name, template: $0.text) }
}

public struct License: Identifiable, Sendable {
    /// The SPDX identifier.
    public let id: String
    public let name: String
    let template: String

    /// The text with `[year]` and `[fullname]` filled in, as GitHub fills them.
    public func text(year: Int, name holder: String) -> String {
        template.replacingOccurrences(of: "[year]", with: String(year))
            .replacingOccurrences(of: "[fullname]", with: holder)
    }
}

extension Git {
    /// The repository's remote URLs by remote name, from one `git config`
    /// call (`-z`: each entry is "key\nvalue\0"). It exits 1 when there are
    /// none.
    func remoteURLs(in repo: URL) async throws -> [String: String] {
        let out = try await run(
            ["config", "-z", "--get-regexp", #"^remote\..*\.url$"#], in: repo, allowedExitCodes: [0, 1]
        ).stdout
        var urls: [String: String] = [:]
        for entry in out.split(separator: 0) {
            let parts = String(decoding: entry, as: UTF8.self).split(
                separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].dropFirst("remote.".count).dropLast(".url".count)
            if urls[String(name)] == nil { urls[String(name)] = String(parts[1]) }
        }
        return urls
    }

    /// `git clone` into `directory`, with submodules as GitHub Desktop
    /// clones them. `options` go before `clone`: the forge's credential
    /// helper (`AppModel.networkArguments`). git removes its half-made
    /// folder when it fails or is terminated; this also removes it when
    /// the task was cancelled before git could start, but never a folder
    /// that was there before.
    public func clone(
        _ url: String, to directory: URL, options: [String] = [], environment: [String: String] = [:]
    ) async throws {
        let existed = FileManager.default.fileExists(atPath: directory.path)
        do {
            try Task.checkCancellation()
            try await run(
                options + ["clone", "--recurse-submodules", "--", url, directory.path],
                in: directory.deletingLastPathComponent(), environment: environment)
        } catch {
            if !existed { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    /// `git init -b <default branch>` in a new or existing folder, then the
    /// chosen README, .gitignore and LICENSE, and a first commit of those
    /// files alone, through `git commit` so the user's hooks and signing
    /// apply. A file already in the folder is never overwritten, and files
    /// already there are not committed: the user checks them in Changes.
    public func create(_ new: NewRepository, year: Int? = nil, environment: [String: String] = [:])
        async throws
    {
        let name = new.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw RepositoryError.invalidName
        }
        let dir = new.directory
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appending(path: ".git").path) {
            throw RepositoryError.alreadyRepository(name)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try await run(["init", "-q", "-b", new.defaultBranch], in: dir, environment: environment)
        let year = year ?? Calendar.current.component(.year, from: Date())
        var written: [String] = []
        for (file, text) in new.files(year: year) where !fm.fileExists(atPath: dir.appending(path: file).path)
        {
            try Data(text.utf8).write(to: dir.appending(path: file))
            written.append(file)
        }
        guard !written.isEmpty else { return }
        try await run(["--literal-pathspecs", "add", "--"] + written, in: dir, environment: environment)
        try await run(["commit", "-q", "-m", "Initial commit"], in: dir, environment: environment)
    }
}

/// The folder name `git clone` would choose for `url`: its last path part
/// without `.git`.
public func cloneDirectoryName(for url: String) -> String {
    var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    if s.hasSuffix(".git") { s.removeLast(4) }
    while s.hasSuffix("/") { s.removeLast() }
    return String(s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
}
