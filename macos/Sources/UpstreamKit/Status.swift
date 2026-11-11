import Foundation

/// The working tree as `git status --porcelain=v2 --branch -z
/// --untracked-files=all` describes it. The v2 format is documented, stable
/// and locale-independent, which is why it is parsed rather than the human
/// output (docs/plans/001_native_clients_on_system_git.md).
public struct RepoStatus: Sendable, Equatable {
    public var branch: BranchInfo
    public var files: [FileChange]

    public static let arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]

    public init(branch: BranchInfo, files: [FileChange]) {
        self.branch = branch
        self.files = files
    }

    public init(parsing data: Data) {
        var branch = BranchInfo()
        var files: [FileChange] = []
        // Each record ends in NUL. A rename or copy is followed by one more
        // NUL-terminated field: the path it came from.
        var fields = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = fields.popFirst() {
            if record.hasPrefix("# ") {
                branch.read(header: record.dropFirst(2))
                continue
            }
            switch record.first {
            case "1":  // 1 XY sub mH mI mW hH hI path
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                files.append(FileChange(path: String(parts[8]), xy: parts[1]))
            case "2":  // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                files.append(
                    FileChange(path: String(parts[9]), xy: parts[1], originalPath: fields.popFirst()))
            case "u":  // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                var change = FileChange(path: String(parts[10]), xy: parts[1])
                change.conflicted = true
                files.append(change)
            case "?":
                files.append(FileChange(path: String(record.dropFirst(2)), index: nil, worktree: .untracked))
            default:
                continue  // "!" ignored files are never asked for
            }
        }
        self.init(branch: branch, files: files)
    }
}

public struct BranchInfo: Sendable, Equatable {
    /// nil before the first commit.
    public var oid: String?
    /// nil when HEAD is detached.
    public var head: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0

    public init(
        oid: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0
    ) {
        self.oid = oid
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    mutating func read(header: Substring) {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid": oid = value == "(initial)" ? nil : value
        case "branch.head": head = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            let ab = value.split(separator: " ")
            if ab.count == 2 {
                ahead = Int(ab[0].dropFirst()) ?? 0
                behind = Int(ab[1].dropFirst()) ?? 0
            }
        default: break
        }
    }
}

public enum ChangeKind: Character, Sendable {
    case modified = "M"
    case typeChanged = "T"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
}

public struct FileChange: Sendable, Equatable, Identifiable {
    public var path: String
    public var originalPath: String?
    /// The staged side of the change; nil when the index matches HEAD.
    public var index: ChangeKind?
    /// The unstaged side; nil when the working tree matches the index.
    public var worktree: ChangeKind?
    public var conflicted = false

    public var id: String { path }

    /// Its path, after the one it was renamed from: what a command about
    /// this change names, so a rename is committed as one.
    public var paths: [String] { [originalPath, path].compactMap { $0 } }

    public init(path: String, index: ChangeKind?, worktree: ChangeKind?, originalPath: String? = nil) {
        self.path = path
        self.index = index
        self.worktree = worktree
        self.originalPath = originalPath
    }

    init(path: String, xy: Substring, originalPath: String? = nil) {
        let xy = Array(xy)
        self.init(
            path: path, index: xy.first.flatMap(ChangeKind.init), worktree: xy.last.flatMap(ChangeKind.init),
            originalPath: originalPath)
    }

    /// One status for the whole file, as the Changes list shows it: what
    /// committing every part of it would record. The checkbox model hides
    /// the index (docs/REQUIREMENTS.md#changes).
    public var kind: ChangeKind {
        if worktree == .untracked { return .untracked }
        if index == .renamed || index == .copied { return index! }
        if index == .added { return worktree == .deleted ? .deleted : .added }
        if index == .deleted || worktree == .deleted { return .deleted }
        return index ?? worktree ?? .modified
    }
}
