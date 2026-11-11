import Foundation

extension FileDiff {
    /// One multi-file `git diff` cut into each file's own diff, keyed by its
    /// path in the new side (the old one for a deletion). Running one diff
    /// for many files costs one process instead of one each. A section whose
    /// path cannot be read is left out, and its file falls back to the
    /// caller's safe default.
    static func sections(_ data: Data) -> [String: Data] {
        let source = Data(data)
        let marker = Data("diff --git ".utf8)
        var starts: [Int] = []
        var lineStart = 0
        while lineStart < source.count {
            if source[lineStart...].starts(with: marker) { starts.append(lineStart) }
            lineStart = (source[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? source.count) + 1
        }
        var out: [String: Data] = [:]
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : source.count
            let section = source[start..<end]
            if let path = path(ofSection: section) { out[path] = Data(section) }
        }
        return out
    }

    /// The new side's path from a section's header lines: `+++ b/…`, else
    /// `rename to …`, else `--- a/…` (a deletion), else the `diff --git`
    /// line itself when both halves are the same path (a mode change).
    private static func path(ofSection section: Data) -> String? {
        var header: [String] = []
        for line in section.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("@@") || text.hasPrefix("Binary files ") { break }
            header.append(text)
        }
        // git ends a `---`/`+++` path holding a space with a tab, for patch(1).
        func after(_ prefix: String) -> String? {
            header.first { $0.hasPrefix(prefix) }.map {
                var p = $0.dropFirst(prefix.count)
                if p.hasSuffix("\t") { p = p.dropLast() }
                return unquote(String(p))
            }
        }
        if let new = after("+++ "), new != "/dev/null" {
            return new.hasPrefix("b/") ? String(new.dropFirst(2)) : nil
        }
        if let renamed = after("rename to ") { return renamed }
        if let old = after("--- "), old != "/dev/null" {
            return old.hasPrefix("a/") ? String(old.dropFirst(2)) : nil
        }
        // "diff --git a/<p> b/<p>": unambiguous only when both halves match.
        guard let first = header.first else { return nil }
        let both = first.dropFirst("diff --git ".count)
        guard both.count % 2 == 1 else { return nil }
        let half = (both.count - 1) / 2
        let a = both.prefix(half)
        let b = both.suffix(half)
        guard a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) else { return nil }
        return String(b.dropFirst(2))
    }

    /// git C-quotes a path holding a quote, a backslash or a control
    /// character ("\"a\\tb\""); everything else is printed as it is
    /// (`core.quotepath=false`).
    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        var bytes: [UInt8] = []
        var it = Array(s.utf8.dropFirst().dropLast())[...]
        while let c = it.popFirst() {
            guard c == UInt8(ascii: "\\"), let e = it.popFirst() else {
                bytes.append(c)
                continue
            }
            switch e {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(e - 48)
                for _ in 0..<2 {
                    guard let d = it.first, (48...55).contains(d) else { break }
                    value = value * 8 + Int(d - 48)
                    it.removeFirst()
                }
                bytes.append(UInt8(value & 0xFF))
            default: bytes.append(e)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
