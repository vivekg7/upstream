import CoreServices
import Foundation

/// Reports which paths changed under some folders, through FSEvents
/// (docs/plans/004_refreshing_on_file_changes.md). The kernel batches the
/// events for `latency` seconds, so a checkout that writes ten thousand
/// files arrives as a handful of callbacks, not ten thousand.
public final class Watcher: @unchecked Sendable {
    /// What the handler is told: the paths that changed, or nil when FSEvents
    /// dropped events and says to rescan everything.
    public typealias Handler = @Sendable ([String]?) -> Void

    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "upstream.watcher", qos: .utility)
    private let box: Box

    private final class Box {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    public init?(paths: [String], latency: TimeInterval = 0.3, handler: @escaping Handler) {
        box = Box(handler)
        // The stream keeps its own reference to the box. FSEvents can still
        // call back after Invalidate (the WatchRoot check runs on its own
        // queue), and with an unretained box that call read freed memory:
        // the test suite crashed in about one run in three.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let rescan = (0..<count).contains {
                flags[$0]
                    & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
            }
            box.handler(rescan ? nil : list)
        }
        // File events, so `.git/objects/…` can be told from `.git/index`;
        // NoDefer delivers the first event of a quiet spell at once and
        // batches what follows it.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency, flags)
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Which changed paths are worth a `git status`. Inside the git directory
/// only the files that change what the app shows count: the index, HEAD, the
/// refs, and the markers of a merge, rebase, cherry-pick or revert. Objects,
/// logs and lock files churn on every git command and say nothing new.
public struct WatchFilter: Sendable {
    public let workTree: String
    public let gitDirs: [String]

    public init(workTree: URL, gitDirs: [URL]) {
        self.workTree = Self.real(workTree)
        // Longest first: a linked worktree's own git directory sits inside
        // the common one (`.git/worktrees/<name>`), and its index counts.
        self.gitDirs = Set(gitDirs.map(Self.real)).sorted { $0.count > $1.count }
    }

    /// The path FSEvents will report: every symlink resolved, `/var` as
    /// `/private/var` included, which `URL.resolvingSymlinksInPath` strips.
    static func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The paths in `paths` that matter, split into git-directory ones and
    /// working-tree ones (relative to the top level, for `check-ignore`).
    public func relevant(_ paths: [String]) -> (git: [String], workTree: [String]) {
        var git: [String] = []
        var tree: [String] = []
        for raw in paths {
            let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if let dir = gitDirs.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                let inner = path == dir ? "" : String(path.dropFirst(dir.count + 1))
                if Self.matters(gitPath: inner) { git.append(inner) }
            } else if path.hasPrefix(workTree + "/") {
                tree.append(String(path.dropFirst(workTree.count + 1)))
            } else if path == workTree {
                tree.append(".")
            }
        }
        return (git, tree)
    }

    static func matters(gitPath p: String) -> Bool {
        if p.isEmpty { return true }  // the directory itself: renamed, deleted
        if p.hasSuffix(".lock") { return false }
        let first = p.split(separator: "/", maxSplits: 1).first.map(String.init) ?? p
        switch first {
        case "objects", "logs", "hooks", "info", "lfs", "fsmonitor--daemon", "worktrees", "modules":
            return false
        case "FETCH_HEAD", "ORIG_HEAD", "COMMIT_EDITMSG", "config", "description", "gc.pid", "gc.log":
            return false
        default:
            // index, HEAD, refs/…, packed-refs, MERGE_HEAD, CHERRY_PICK_HEAD,
            // REVERT_HEAD, rebase-merge/…, rebase-apply/…, sequencer/…
            return true
        }
    }
}
