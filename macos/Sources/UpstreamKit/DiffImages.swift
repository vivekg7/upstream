import Foundation

/// The two sides of an image's diff, drawn side by side instead of git's
/// "Binary files differ". nil is a side that does not exist (an added or a
/// deleted image), or one past `byteCeiling`.
public struct DiffImages: Sendable, Equatable {
    public var old: Data?
    public var new: Data?

    public init(old: Data?, new: Data?) {
        self.old = old
        self.new = new
    }

    /// The image types macOS decodes on its own, by extension.
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "ico",
    ]

    public static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// No side is read past this: a photograph is a few megabytes, and a
    /// file far larger is not one to look at in a diff.
    public static let byteCeiling = 64 << 20

    /// The Changes tab's sides: HEAD's blob (under the original path of a
    /// rename) and the file in the working tree.
    public static func workingTree(_ change: FileChange, hasHead: Bool, in repo: URL, git: Git) async
        -> DiffImages
    {
        let isNew = !hasHead || change.kind == .untracked || change.kind == .added
        let old = isNew ? nil : await git.blob("HEAD", change.originalPath ?? change.path, in: repo)
        var new: Data?
        if change.kind != .deleted {
            let file = repo.appending(path: change.path)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if size <= byteCeiling { new = try? Data(contentsOf: file) }
        }
        return DiffImages(old: old, new: new)
    }
}

extension Git {
    /// The bytes of `path` in `revision` (`git cat-file blob <rev>:<path>`),
    /// or nil when it is not there or is past `DiffImages.byteCeiling`.
    /// History reads both sides of a commit's image with it: the parent's
    /// and the commit's own.
    public func blob(_ revision: String, _ path: String, in repo: URL) async -> Data? {
        // `rev:path` takes the path as written, never as a pattern.
        guard
            let result = try? await run(
                ["cat-file", "blob", "\(revision):\(path)"], in: repo, limit: DiffImages.byteCeiling),
            !result.truncated
        else { return nil }
        return result.stdout
    }
}
