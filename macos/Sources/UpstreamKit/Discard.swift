import Foundation

// Discarding changes, whole files or chosen lines, with the discarded
// content kept in the Trash (docs/plans/008_discard_ignore_and_conflicts.md).

/// Moves a file or folder to the Trash. Passed in, so the tests do not fill
/// the user's own Trash.
public typealias Trash = @Sendable (URL) throws -> Void

public let moveToTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

public enum DiscardError: Error, LocalizedError, Equatable {
    /// The file changed after its diff was shown, so the chosen lines would
    /// point at other lines.
    case changedSinceShown(path: String)

    public var errorDescription: String? {
        switch self {
        case .changedSinceShown(let path):
            "“\(path)” changed after its diff was shown. Choose the lines again, then discard."
        }
    }
}

/// Copies the files at `paths` (relative to `repo`; the missing ones are
/// skipped) into one folder, keeping their subfolders, and moves the folder
/// to the Trash. Its name, "Upstream discarded changes <repo> <date>", is
/// what the user finds there, as with GitHub Desktop. Throws, and so stops
/// whatever was about to overwrite the files, if either step fails.
func keepInTrash(_ paths: [String], of repo: URL, trash: Trash) throws {
    let fm = FileManager.default
    // attributesOfItem does not follow a symlink, so a dangling one is kept too.
    let existing = paths.filter { (try? fm.attributesOfItem(atPath: repo.appending(path: $0).path)) != nil }
    guard !existing.isEmpty else { return }
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"  // a colon shows as a slash in the Finder
    let parent = fm.temporaryDirectory.appending(path: "upstream-discard-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: parent) }
    let folder = parent.appending(
        path: "Upstream discarded changes \(repo.lastPathComponent) \(stamp.string(from: .now))")
    for path in existing {
        let target = folder.appending(path: path)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appending(path: path), to: target)
    }
    try trash(folder)
}

extension Git {
    /// Discards every change to `changes`, once their current contents are
    /// in the Trash. Tracked paths go back to HEAD in the index and the
    /// working tree, both paths of a rename, so an added file leaves both and
    /// a deleted one comes back. Untracked files are removed: their copies
    /// are in the Trash already. Conflicted files are left alone; they are
    /// resolved, not discarded.
    public func discard(_ changes: [FileChange], hasHead: Bool, in repo: URL, trash: Trash) async throws {
        let changes = changes.filter { !$0.conflicted }
        try keepInTrash(changes.map(\.path), of: repo, trash: trash)
        let tracked = changes.filter { $0.kind != .untracked }.flatMap(\.paths)
        var remove = changes.filter { $0.kind == .untracked }.map(\.path)
        if !tracked.isEmpty {
            if hasHead {
                try await run(
                    ["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"]
                        + tracked,
                    in: repo)
            } else {
                // Before the first commit every tracked file is a new one.
                try await run(
                    ["--literal-pathspecs", "rm", "-q", "--cached", "--force", "--"] + tracked, in: repo)
                remove += tracked
            }
        }
        for path in remove {
            let url = repo.appending(path: path)
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Discards the changes at `selected` (indices into `diff.lines`) from
    /// the working tree and leaves the rest, after keeping the whole file in
    /// the Trash. `diff` must still be the file's diff: lines chosen in an
    /// older one would point at other lines.
    public func discardLines(
        _ selected: Set<Int>, of change: FileChange, in diff: FileDiff, hasHead: Bool, in repo: URL,
        trash: Trash
    ) async throws {
        let (args, allowed) = FileDiff.arguments(for: change, hasHead: hasHead)
        let now = FileDiff(parsing: try await run(args, in: repo, allowedExitCodes: allowed).stdout)
        guard now == diff else { throw DiscardError.changedSinceShown(path: change.path) }
        guard let patch = diff.discardPatch(selected) else { return }
        try keepInTrash([change.path], of: repo, trash: trash)
        try await run(["apply", "--reverse", "--whitespace=nowarn", "-"], in: repo, input: patch)
    }
}

extension FileDiff {
    /// A patch whose new side is the working tree and whose old side is the
    /// working tree without the changes at `selected`, so `git apply
    /// --reverse` undoes exactly those. It is the mirror of
    /// `patch(selecting:)`, which is cut against HEAD and so cannot be
    /// reversed onto a working tree that still has the unselected changes:
    /// here an unselected addition stays as context (it is in the working
    /// tree) and an unselected removal is left out (it is not). nil when it
    /// would change nothing.
    func discardPatch(_ selected: Set<Int>) -> Data? {
        guard canSelectLines, let name = newName else { return nil }
        // Only the one file's contents change: a rename, a new file's mode or
        // a mode change in git's header would be reversed too.
        var out = Data("diff --git ".utf8) + aName(name) + Data(" ".utf8) + name + Data("\n--- ".utf8)
        out += aName(name) + tab(name) + Data("\n+++ ".utf8) + name + tab(name) + Data("\n".utf8)
        var delta = 0  // how far the old side has moved from the new so far
        var changed = false
        for h in lines.indices where lines[h].kind == .hunk {
            let body = discardBody(hunk(at: h), selected)
            guard body.contains(where: { $0.first == UInt8(ascii: "+") || $0.first == UInt8(ascii: "-") })
            else {
                continue
            }
            changed = true
            let oldCount = body.count { $0.first != UInt8(ascii: "+") && $0.first != UInt8(ascii: "\\") }
            let newCount = body.count { $0.first != UInt8(ascii: "-") && $0.first != UInt8(ascii: "\\") }
            let newStart = Self.hunkStarts(lines[h].text).1
            // An empty side is numbered from the line before it.
            let oldStart = newStart + delta + (newCount == 0 ? 1 : 0) - (oldCount == 0 ? 1 : 0)
            delta += oldCount - newCount
            out.append(contentsOf: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8)
            for line in body { out += line + Data("\n".utf8) }
        }
        return changed ? out : nil
    }

    /// The new path as git wrote it on the `+++` line, `b/` and any quoting
    /// included, so a name in any encoding comes back byte for byte.
    private var newName: Data? {
        let head = source[header]
        guard
            let line = head.split(separator: UInt8(ascii: "\n")).first(where: {
                $0.starts(with: Data("+++ ".utf8))
            })
        else { return nil }
        var name = Data(line.dropFirst(4))
        // git ends a name that has a space with a tab, so apply knows where it ends.
        if name.last == UInt8(ascii: "\t") { name.removeLast() }
        return name == Data("/dev/null".utf8) ? nil : name
    }

    private func aName(_ name: Data) -> Data {
        let quoted = name.first == UInt8(ascii: "\"")
        return (quoted ? Data("\"a".utf8) : Data("a".utf8)) + name.dropFirst(quoted ? 2 : 1)
    }

    private func tab(_ name: Data) -> Data { name.contains(UInt8(ascii: " ")) ? Data("\t".utf8) : Data() }

    /// One hunk's lines for `discardPatch`. A "\ No newline" marker belongs
    /// to the line before it and goes wherever that line goes, with one
    /// exception: a restored removal that ended the old file is followed in
    /// the result by the additions kept after it, so there it needs its
    /// newline, and its marker is dropped.
    private func discardBody(_ hunk: Range<Int>, _ selected: Set<Int>) -> [Data] {
        var body: [Data] = []
        var keepMarker = true
        for k in hunk {
            let bytes = source[ranges[k]]
            switch lines[k].kind {
            case .context:
                body.append(bytes)
                keepMarker = true
            case .added where selected.contains(k):
                body.append(bytes)
                keepMarker = true
            case .added:
                body.append(Data(" ".utf8) + bytes.dropFirst())
                keepMarker = true
            case .removed where selected.contains(k):
                body.append(bytes)
                keepMarker = !hunk[(k + 1)...].contains { lines[$0].kind == .added && !selected.contains($0) }
            case .removed:
                keepMarker = false
            case .noNewline:
                if keepMarker { body.append(bytes) }
            case .hunk:
                break
            }
        }
        return body
    }
}
