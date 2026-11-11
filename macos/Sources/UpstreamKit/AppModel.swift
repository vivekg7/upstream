import Foundation
import Observation

/// The app's state: the repositories the user added, the one selected, and
/// what its working tree looks like. Views read it; only it runs git.
@MainActor @Observable
public final class AppModel {
    public private(set) var repositories: [URL]
    public var selected: URL? {
        didSet {
            guard selected != oldValue else { return }
            status = nil
            selectedFile = nil
            Task { await refresh() }
        }
    }
    public private(set) var status: RepoStatus?
    public var selectedFile: FileChange.ID? {
        didSet { if selectedFile != oldValue { Task { await loadDiff() } } }
    }
    public private(set) var diff: FileDiff?
    public private(set) var error: String?

    public let git: Git?
    private let defaults: UserDefaults
    private static let repositoriesKey = "repositories"

    public init(git: Git? = Git.locate(), defaults: UserDefaults = .standard) {
        self.git = git
        self.defaults = defaults
        repositories = (defaults.stringArray(forKey: Self.repositoriesKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        selected = repositories.first
    }

    /// Adds a folder that is inside a git working tree, by its top level,
    /// so a subfolder picked by mistake still opens the whole repository.
    public func add(_ folder: URL) async {
        guard let git else { return }
        do {
            let top = try await git.run(["rev-parse", "--show-toplevel"], in: folder).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: top)
            if !repositories.contains(url) {
                repositories.append(url)
                repositories.sort {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                defaults.set(repositories.map(\.path), forKey: Self.repositoriesKey)
            }
            selected = url
        } catch {
            self.error = "\(folder.lastPathComponent) is not a git repository."
        }
    }

    /// Takes a repository off the list. Its folder is left alone.
    public func remove(_ url: URL) {
        repositories.removeAll { $0 == url }
        defaults.set(repositories.map(\.path), forKey: Self.repositoriesKey)
        if selected == url { selected = repositories.first }
    }

    public func refresh() async {
        guard let git, let repo = selected else { return }
        do {
            let result = try await git.run(RepoStatus.arguments, in: repo)
            guard repo == selected else { return }  // the user moved on meanwhile
            let fresh = RepoStatus(parsing: result.stdout)
            if fresh != status { status = fresh }
            error = nil
            if let file = selectedFile, !fresh.files.contains(where: { $0.id == file }) {
                selectedFile = nil
            } else {
                await loadDiff()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard let git, let repo = selected, let status,
            let change = status.files.first(where: { $0.id == selectedFile })
        else {
            diff = nil
            return
        }
        let (args, allowed) = FileDiff.arguments(for: change, hasHead: status.branch.oid != nil)
        do {
            let result = try await git.run(args, in: repo, allowedExitCodes: allowed)
            guard repo == selected, change.id == selectedFile else { return }
            diff = FileDiff(parsing: result.text)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
