import Foundation

/// Ignoring an untracked file, or every file with its extension, by adding a
/// line to the top-level `.gitignore`
/// (docs/plans/008_discard_ignore_and_conflicts.md).
public enum Ignore {
    /// A pattern for exactly the file at `path`: anchored at the top level
    /// with a leading slash, so `/build.log` does not also ignore
    /// `docs/build.log`.
    public static func pattern(forFile path: String) -> String { "/" + escape(path) }

    /// A pattern for every file ending in `.<ext>`, anywhere.
    public static func pattern(forExtension ext: String) -> String { "*." + escape(ext) }

    /// The extension "Ignore All .<ext> Files" offers for `path`; nil when it
    /// has none.
    public static func fileExtension(of path: String) -> String? {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    /// `text` matched literally: `*`, `?`, `[` and `\` escaped, and trailing
    /// spaces, which git would drop, kept by escaping each. A leading `#` or
    /// `!` would also be special, but every pattern here starts with `/` or
    /// `*`, so neither can lead.
    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "*?[\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        let spaces = out.reversed().prefix { $0 == " " }.count
        return String(out.dropLast(spaces)) + String(repeating: "\\ ", count: spaces)
    }

    /// Appends `pattern` as its own line to `repo`'s top-level `.gitignore`,
    /// creating it if missing and ending an unterminated last line first. A
    /// line already there is not added again.
    public static func add(_ pattern: String, in repo: URL) throws {
        guard !pattern.contains("\n") else {
            throw GitError(arguments: [], status: 0, message: "A name with a line break cannot be ignored.")
        }
        let url = repo.appending(path: ".gitignore")
        let existing = (try? Data(contentsOf: url)) ?? Data()
        let lines = String(decoding: existing, as: UTF8.self).split(separator: "\n").map {
            $0.hasSuffix("\r") ? $0.dropLast() : $0
        }
        guard !lines.contains(Substring(pattern)) else { return }
        var add = existing.isEmpty || existing.last == UInt8(ascii: "\n") ? Data() : Data("\n".utf8)
        add += Data((pattern + "\n").utf8)
        guard FileManager.default.fileExists(atPath: url.path) else { return try add.write(to: url) }
        // Appended in place, not rewritten: a symlinked .gitignore stays one.
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: add)
    }
}
