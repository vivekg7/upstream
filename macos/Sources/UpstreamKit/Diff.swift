import Foundation

/// A unified diff (`git diff` without colour), split into lines with their
/// old and new line numbers, as the diff view draws them.
public struct FileDiff: Sendable, Equatable {
    public var lines: [DiffLine]
    public var isBinary: Bool

    public init(lines: [DiffLine], isBinary: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
    }

    /// The diff of one file against HEAD, staged and unstaged together, as
    /// the checkbox model commits it. A file git does not track yet, or any
    /// file before the first commit, is compared with nothing.
    public static func arguments(for change: FileChange, hasHead: Bool) -> (
        args: [String], allowed: Set<Int32>
    ) {
        if change.kind == .untracked || !hasHead {
            return (["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", change.path], [0, 1])
        }
        var paths = [change.path]
        if let original = change.originalPath { paths.insert(original, at: 0) }
        return (["diff", "--no-ext-diff", "--find-renames", "HEAD", "--"] + paths, [0])
    }

    public init(parsing text: String) {
        var lines: [DiffLine] = []
        var binary = false
        var old = 0
        var new = 0
        var inHunk = false
        // Split on "\n" alone: a diff of a file with CRLF endings keeps its
        // "\r", which is content.
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                (old, new) = Self.hunkStarts(line)
                lines.append(DiffLine(kind: .hunk, text: line))
                continue
            }
            guard inHunk else {
                if line.hasPrefix("Binary files ") { binary = true }
                continue  // diff --git, index, ---, +++ and mode lines
            }
            switch line.first {
            case "+":
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), newLine: new))
                new += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: old))
                old += 1
            case " ":
                lines.append(
                    DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: old, newLine: new))
                old += 1
                new += 1
            case "\\":
                lines.append(DiffLine(kind: .noNewline, text: line))
            default:
                inHunk = false  // the end, or the next file's header
            }
        }
        self.init(lines: lines, isBinary: binary)
    }

    /// "@@ -12,3 +12,4 @@ context" → (12, 12). A count may be left out
    /// ("-12 +12") when it is one.
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ s: Substring?) -> Int {
            guard let s else { return 0 }
            return Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable { case hunk, context, added, removed, noNewline }

    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}
