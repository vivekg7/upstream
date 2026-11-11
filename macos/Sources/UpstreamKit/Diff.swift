import Foundation

/// A unified diff (`git diff` without colour), split into lines with their
/// old and new line numbers, as the diff view draws them. It keeps git's
/// bytes as well: a partial commit is cut from them (`patch(selecting:)`),
/// and cutting it from decoded text would corrupt a file in any encoding
/// but UTF-8.
public struct FileDiff: Sendable, Equatable {
    public var lines: [DiffLine]
    public var isBinary: Bool
    /// Whether single lines can be chosen to commit: the diff of one text
    /// file that `git apply` can take in part. A binary, a deletion, a
    /// submodule, or a diff of two files (a type change, a rename too
    /// changed to be found) is committed whole.
    public var canSelectLines: Bool
    /// Read with `-w`: what is shown is not what would be committed, so no
    /// line can be chosen in it, as in GitHub Desktop. The file's checkbox
    /// still commits it whole.
    public private(set) var ignoresWhitespace = false
    /// git printed more than `byteCeiling`, so it was stopped and nothing
    /// was parsed. The file can still be committed whole.
    public private(set) var exceedsCeiling = false

    let source: Data
    /// The bytes before the first hunk: `diff --git`, `---`, `+++` and the rest.
    let header: Range<Int>
    /// Where each of `lines` sits in `source`, without its newline.
    let ranges: [Range<Int>]

    /// Options on every diff we parse or cut a patch from: whatever the
    /// user's config says, no colour, no external diff tool, and the `a/`
    /// and `b/` prefixes `git apply` expects (`diff.noprefix` drops them).
    /// Paths are never patterns: a file named `*.txt` is that file.
    static let base = [
        "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
    ]

    /// The diff of one file against HEAD, staged and unstaged together, as
    /// the checkbox model commits it. A file git does not track yet, or any
    /// file before the first commit, is compared with nothing.
    /// `ignoringWhitespace` adds `-w`, for viewing only (`ignoresWhitespace`).
    public static func arguments(for change: FileChange, hasHead: Bool, ignoringWhitespace: Bool = false)
        -> (args: [String], allowed: Set<Int32>)
    {
        let base = base + (ignoringWhitespace ? ["-w"] : [])
        if change.kind == .untracked || !hasHead {
            return (base + ["--no-index", "--", "/dev/null", change.path], [0, 1])
        }
        return (base + ["--find-renames", "HEAD", "--"] + change.paths, [0])
    }

    /// The most a diff read for the screen may be (`Git.run`'s `limit`). A
    /// generated file of hundreds of megabytes would otherwise be read and
    /// parsed whole, and the parse holds about three times the bytes. 16 MB
    /// is some 200,000 lines of code, far past anything worth reading.
    public static let byteCeiling = 16 << 20

    /// A diff git stopped printing at `byteCeiling`.
    public static let tooLarge: FileDiff = {
        var diff = FileDiff(parsing: Data())
        diff.exceedsCeiling = true
        return diff
    }()

    /// Past this, the view asks before drawing, as GitHub Desktop does. The
    /// renderer copes with far more; the point is that a diff this size is
    /// nearly always generated (a lockfile, a bundle) and drawing it is
    /// rarely what the user wanted. Lines catch a long diff, bytes a few
    /// very long lines.
    public static let largeLines = 20_000
    public static let largeBytes = 4 << 20

    public var isLarge: Bool { lines.count > Self.largeLines || source.count > Self.largeBytes }

    /// The two halves of that diff: HEAD to the index (what is staged) and
    /// the index to the working tree (what is not). Read only to find which
    /// lines a terminal already staged (`selection(staged:unstaged:)`).
    public static func indexArguments(for change: FileChange) -> (staged: [String], unstaged: [String]) {
        (base + ["--cached", "--find-renames", "--"] + change.paths, base + ["--", change.path])
    }

    public init(parsing data: Data, ignoringWhitespace: Bool = false) {
        let source = Data(data)  // indices from zero, whatever `data` was sliced from
        var lines: [DiffLine] = []
        var ranges: [Range<Int>] = []
        var header: Range<Int>?
        var binary = false
        var sections = 0
        var wholeOnly = false
        var old = 0
        var new = 0
        var inHunk = false
        var start = 0
        // Split on "\n" alone: a diff of a file with CRLF endings keeps its
        // "\r", which is content.
        while start < source.count {
            let end = source[start...].firstIndex(of: UInt8(ascii: "\n")) ?? source.count
            let range = start..<end
            start = end + 1
            let line = String(decoding: source[range], as: UTF8.self)
            if line.hasPrefix("@@") {
                inHunk = true
                if header == nil { header = 0..<range.lowerBound }
                (old, new) = Self.hunkStarts(line)
                lines.append(DiffLine(kind: .hunk, text: line))
                ranges.append(range)
                continue
            }
            if inHunk {
                switch line.first {
                case "+":
                    lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), newLine: new))
                    new += 1
                case "-":
                    lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: old))
                    old += 1
                // An empty line is context too: `diff.suppressBlankEmpty`
                // drops the space before a blank one.
                case " ", nil:
                    lines.append(
                        DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: old, newLine: new))
                    old += 1
                    new += 1
                case "\\":
                    lines.append(DiffLine(kind: .noNewline, text: line))
                default:
                    inHunk = false  // the next file's header
                }
                if inHunk {
                    ranges.append(range)
                    continue
                }
            }
            // diff --git, index, mode, rename, ---, +++ and Binary lines.
            if line.hasPrefix("diff --git ") { sections += 1 }
            if line.hasPrefix("Binary files ") { binary = true }
            if line.hasPrefix("deleted file mode ") || line.hasSuffix(" 160000") { wholeOnly = true }
        }
        self.lines = lines
        self.isBinary = binary
        self.source = source
        self.header = header ?? 0..<0
        self.ranges = ranges
        self.canSelectLines =
            sections == 1 && !binary && !wholeOnly && !ignoringWhitespace
            && lines.contains { $0.kind == .added || $0.kind == .removed }
        self.ignoresWhitespace = ignoringWhitespace
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

    /// The widest line in columns, its marker included and a tab counting
    /// as four, for sizing a monospaced view. Bytes stand for characters,
    /// which overcounts a wide character rather than undercounts it. A line
    /// past `cap` counts as `cap`. Read from the bytes: counted over each
    /// line's `String` in the view, it took 200 ms for 100,000 lines.
    public func widestLine(cappedAt cap: Int) -> Int {
        source.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var widest = 0
            for (k, range) in ranges.enumerated() where lines[k].kind != .noNewline {
                guard range.count <= cap else { return cap }
                var tabs = 0
                for i in range where bytes[i] == UInt8(ascii: "\t") { tabs += 1 }
                widest = max(widest, range.count + 3 * tabs)
            }
            return min(widest, cap)
        }
    }

    /// The indices of the lines a user can check: the added and removed ones.
    public var changedLines: [Int] {
        lines.indices.filter { lines[$0].kind == .added || lines[$0].kind == .removed }
    }

    /// The lines under the hunk header at `index`, up to the next one.
    public func hunk(at index: Int) -> Range<Int> {
        let end = lines[(index + 1)...].firstIndex { $0.kind == .hunk } ?? lines.endIndex
        return (index + 1)..<end
    }

    /// A patch that applies to the old side and makes only the changes at
    /// `selected` (indices into `lines`): an unselected addition is left
    /// out, an unselected removal stays as context. `git apply --cached`
    /// stages it, which is how part of a file is committed. nil when it
    /// would change nothing.
    public func patch(selecting selected: Set<Int>) -> Data? {
        guard canSelectLines else { return nil }
        var out = Data(source[header])
        var delta = 0  // how far the new side has moved from the old so far
        var changed = false
        for h in lines.indices where lines[h].kind == .hunk {
            let body = hunkBody(hunk(at: h), selected)
            guard body.contains(where: { $0.first == plus || $0.first == minus }) else { continue }
            changed = true
            // Context counts on both sides (empty is context); a marker on neither.
            let oldCount = body.count { $0.first != plus && $0.first != marker }
            let newCount = body.count { $0.first != minus && $0.first != marker }
            let oldStart = Self.hunkStarts(lines[h].text).0
            // An empty side is numbered from the line before it.
            let newStart = oldStart + delta + (oldCount == 0 ? 1 : 0) - (newCount == 0 ? 1 : 0)
            delta += newCount - oldCount
            out.append(contentsOf: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8)
            for line in body {
                out.append(line)
                out.append(UInt8(ascii: "\n"))
            }
        }
        return changed ? out : nil
    }

    private var plus: UInt8 { UInt8(ascii: "+") }
    private var minus: UInt8 { UInt8(ascii: "-") }
    private var marker: UInt8 { UInt8(ascii: "\\") }

    /// One hunk's lines with only the selected changes. A "\ No newline"
    /// marker belongs to the line before it and goes wherever that line goes.
    private func hunkBody(_ hunk: Range<Int>, _ selected: Set<Int>) -> [Data] {
        var body: [Data] = []
        var keepMarker = true
        for k in hunk {
            let bytes = source[ranges[k]]
            switch lines[k].kind {
            case .context:
                body.append(bytes)
                keepMarker = true
            case .added:
                keepMarker = selected.contains(k)
                if keepMarker { body.append(bytes) }
            case .removed where selected.contains(k):
                body.append(bytes)
                keepMarker = true
            case .removed:
                let endsOldFile = k + 1 < hunk.upperBound && lines[k + 1].kind == .noNewline
                if endsOldFile,
                    hunk[(k + 1)...].contains(where: { lines[$0].kind == .added && selected.contains($0) })
                {
                    // The old file's last line, without a newline, is kept,
                    // but chosen lines follow it: in the new file it needs
                    // one. Remove it and add it back with a newline.
                    body.append(bytes)
                    body.append(source[ranges[k + 1]])
                    body.append(Data([plus]) + bytes.dropFirst())
                    keepMarker = false  // already written
                } else {
                    body.append(Data([UInt8(ascii: " ")]) + bytes.dropFirst())
                    keepMarker = true
                }
            case .noNewline:
                if keepMarker { body.append(bytes) }
            case .hunk:
                break
            }
        }
        return body
    }

    /// The lines of this diff (HEAD to the working tree) that a terminal
    /// already staged, from the staged diff (HEAD to the index) and the
    /// unstaged one (the index to the working tree): an addition is staged
    /// unless the unstaged diff adds it, a removal is staged if the staged
    /// diff removes it. nil when the index holds what this diff cannot
    /// show, such as a line staged and then edited again.
    public func selection(staged: FileDiff, unstaged: FileDiff) -> Set<Int>? {
        let unstagedAdds = Set(unstaged.lines.filter { $0.kind == .added }.compactMap(\.newLine))
        let stagedRemovals = Set(staged.lines.filter { $0.kind == .removed }.compactMap(\.oldLine))
        let picked = changedLines.filter { k in
            let line = lines[k]
            return line.kind == .added
                ? !unstagedAdds.contains(line.newLine ?? 0) : stagedRemovals.contains(line.oldLine ?? 0)
        }
        // Exact only when the picked lines are the staged diff's own changes.
        let pickedAdds = picked.filter { lines[$0].kind == .added }.map { lines[$0].text }
        let stagedAdds = staged.lines.filter { $0.kind == .added }.map(\.text)
        guard pickedAdds == stagedAdds, picked.count - pickedAdds.count == stagedRemovals.count else {
            return nil
        }
        return Set(picked)
    }
}

/// One row of the split view: an old line on the left, a new one on the
/// right, as indices into `FileDiff.lines`. Context and hunk headers are the
/// same line on both sides; nil is an empty side.
public struct SplitRow: Sendable, Equatable {
    public var old: Int?
    public var new: Int?

    public init(old: Int?, new: Int?) {
        self.old = old
        self.new = new
    }
}

extension FileDiff {
    /// The rows of the split view. Within a run of changes the removed lines
    /// and the added ones sit side by side in order, the shorter side padded
    /// with empty rows. A "\ No newline" marker goes on the side of the line
    /// it belongs to.
    public var splitRows: [SplitRow] {
        var rows: [SplitRow] = []
        var old: [Int] = []
        var new: [Int] = []
        func flush() {
            for i in 0..<max(old.count, new.count) {
                rows.append(SplitRow(old: i < old.count ? old[i] : nil, new: i < new.count ? new[i] : nil))
            }
            old = []
            new = []
        }
        for (k, line) in lines.enumerated() {
            switch line.kind {
            case .removed:
                if !new.isEmpty { flush() }  // git puts removals first; anything else starts a new run
                old.append(k)
            case .added:
                new.append(k)
            case .noNewline where k > 0 && lines[k - 1].kind == .removed:
                old.append(k)
            case .noNewline where k > 0 && lines[k - 1].kind == .added:
                new.append(k)
            case .context, .hunk, .noNewline:
                flush()
                rows.append(SplitRow(old: k, new: k))
            }
        }
        flush()
        return rows
    }

    /// Each removed line and the added line beside it in the split view,
    /// both ways round: the pairs whose words are compared (`WordDiff`).
    public var partners: [Int: Int] {
        var pairs: [Int: Int] = [:]
        for row in splitRows {
            guard let old = row.old, let new = row.new, lines[old].kind == .removed, lines[new].kind == .added
            else { continue }
            pairs[old] = new
            pairs[new] = old
        }
        return pairs
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
