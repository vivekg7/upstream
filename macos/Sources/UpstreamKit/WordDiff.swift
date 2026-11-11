import Foundation

/// Which words changed between a removed line and the added line beside it
/// (`FileDiff.partners`), for the highlights within changed lines. Each line
/// is split into words, runs of whitespace and single punctuation marks, and
/// the two lists are compared with Myers' O(ND) diff, which stops early once
/// the lines are too different to be worth highlighting.
public enum WordDiff {
    /// Longer lines are not compared: past this a line is generated, not
    /// written, and highlights in it would cost more than they tell.
    public static let maxLength = 1_000
    /// The most edits (tokens removed plus tokens added) worth showing.
    /// Bounds the work at O((n + m) · maxEdits) and the memory at
    /// O(maxEdits²), whatever the lines are.
    public static let maxEdits = 200

    /// The changed parts of `old` and `new`, as UTF-16 offsets. nil when a
    /// line is too long, or the two have less than half their tokens in
    /// common: highlighting most of both lines says nothing the red and
    /// green do not.
    public static func changes(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.utf16.count <= maxLength, new.utf16.count <= maxLength else { return nil }
        let a = tokens(old)
        let b = tokens(new)
        guard
            let (deleted, inserted) = diff(
                a.map(\.text), b.map(\.text), maxEdits: min(maxEdits, (a.count + b.count) / 2))
        else { return nil }
        return (merge(a, deleted), merge(b, inserted))
    }

    typealias Token = (text: Substring, range: Range<Int>)

    /// Words (letters, digits, `_`), runs of whitespace, and every other
    /// character alone, with their UTF-16 offsets.
    static func tokens(_ s: String) -> [Token] {
        enum Class { case word, space, other }
        func kind(_ c: Unicode.Scalar) -> Class {
            if c == "_" || CharacterSet.alphanumerics.contains(c) { return .word }
            return CharacterSet.whitespaces.contains(c) ? .space : .other
        }
        var out: [Token] = []
        var start = s.startIndex
        var startOffset = 0
        var offset = 0
        var current: Class?
        for i in s.unicodeScalars.indices {
            let c = s.unicodeScalars[i]
            let k = kind(c)
            if let current, current != k || k == .other {
                out.append((s[start..<i], startOffset..<offset))
                start = i
                startOffset = offset
            }
            current = k
            offset += c.utf16.count
        }
        if current != nil { out.append((s[start...], startOffset..<offset)) }
        return out
    }

    /// Myers' diff of `a` and `b`: which of `a` are deleted and which of `b`
    /// inserted. nil past `maxEdits`.
    static func diff<T: Equatable>(_ a: [T], _ b: [T], maxEdits: Int) -> (deleted: [Bool], inserted: [Bool])?
    {
        let n = a.count
        let m = b.count
        let offset = maxEdits + 1
        // v[offset + k]: the furthest x reached on diagonal k (k = x - y).
        var v = [Int](repeating: 0, count: 2 * offset + 1)
        var trace: [[Int]] = []
        for d in 0...maxEdits {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                let down = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                var x = down ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                guard x >= n, y >= m else { continue }
                // Reached the end: walk the trace back to find each edit.
                var deleted = [Bool](repeating: false, count: n)
                var inserted = [Bool](repeating: false, count: m)
                var (px, py) = (n, m)
                for e in stride(from: d, to: 0, by: -1) {
                    let v = trace[e]
                    let k = px - py
                    let down = k == -e || (k != e && v[offset + k - 1] < v[offset + k + 1])
                    let prevK = down ? k + 1 : k - 1
                    let prevX = v[offset + prevK]
                    let prevY = prevX - prevK
                    if down { inserted[prevY] = true } else { deleted[prevX] = true }
                    (px, py) = (prevX, prevY)
                }
                return (deleted, inserted)
            }
        }
        return nil
    }

    /// The changed tokens as ranges, neighbours joined into one.
    private static func merge(_ tokens: [Token], _ changed: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where changed[i] {
            if let last = out.last, last.upperBound == token.range.lowerBound {
                out[out.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                out.append(token.range)
            }
        }
        return out
    }
}
