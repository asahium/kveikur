import Foundation

/// fzf-style matcher: every space-separated term must appear as a subsequence;
/// consecutive runs and word or path boundaries score higher, gaps cost.
public struct FuzzyMatcher: Sendable {
    private let terms: [[UInt8]]

    public init(_ query: String) {
        terms = query.lowercased().split(separator: " ").map { Array($0.utf8) }
    }

    public var isEmpty: Bool { terms.isEmpty }

    public static func prepare(_ s: String) -> [UInt8] { Array(s.lowercased().utf8) }

    public func score(_ text: [UInt8]) -> Int? {
        var total = 0
        for t in terms {
            guard let s = Self.score(term: t, text: text) else { return nil }
            total += s
        }
        return total - text.count / 32
    }

    /// Match positions for highlighting; computed only for visible rows.
    public func positions(_ text: [UInt8]) -> [Int] {
        var out: [Int] = []
        for t in terms {
            if let r = Self.window(term: t, text: text) { out += Self.greedy(term: t, text: text, from: r.lowerBound) }
        }
        return out.sorted()
    }

    private static func isBoundary(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x2F || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x28 || c == 0x5B
    }

    /// Shortest window ending at the first full forward match.
    private static func window(term: [UInt8], text: [UInt8]) -> ClosedRange<Int>? {
        guard !term.isEmpty, term.count <= text.count else { return term.isEmpty ? 0...0 : nil }
        var ti = 0
        var end = -1
        for (i, c) in text.enumerated() where c == term[ti] {
            ti += 1
            if ti == term.count { end = i; break }
        }
        guard end >= 0 else { return nil }
        var pi = term.count - 1
        var start = end
        var i = end
        while i >= 0 {
            if text[i] == term[pi] {
                if pi == 0 { start = i; break }
                pi -= 1
            }
            i -= 1
        }
        return start...end
    }

    private static func greedy(term: [UInt8], text: [UInt8], from: Int) -> [Int] {
        var out: [Int] = []
        var ti = 0
        var i = from
        while i < text.count, ti < term.count {
            if text[i] == term[ti] { out.append(i); ti += 1 }
            i += 1
        }
        return out
    }

    static func score(term: [UInt8], text: [UInt8]) -> Int? {
        guard let w = window(term: term, text: text) else { return nil }
        let pos = greedy(term: term, text: text, from: w.lowerBound)
        var s = 0
        var prev = -2
        for p in pos {
            s += 16
            if p == 0 || isBoundary(text[p - 1]) { s += 10 }
            if p == prev + 1 { s += 8 } else if prev >= 0 { s -= min(p - prev - 1, 12) }
            prev = p
        }
        return s
    }
}

public struct FuzzyIndex<Item: Sendable>: Sendable {
    public let items: [Item]
    let haystacks: [[UInt8]]

    public init(items: [Item], key: (Item) -> String) {
        self.items = items
        haystacks = items.map { FuzzyMatcher.prepare(key($0)) }
    }

    public func search(_ query: String, limit: Int = 200) -> [(item: Item, score: Int)] {
        let m = FuzzyMatcher(query)
        if m.isEmpty { return items.prefix(limit).map { ($0, 0) } }
        var hits: [(Int, Int)] = []
        hits.reserveCapacity(256)
        for (i, h) in haystacks.enumerated() {
            if let s = m.score(h) { hits.append((i, s)) }
        }
        hits.sort { $0.1 != $1.1 ? $0.1 > $1.1 : haystacks[$0.0].count < haystacks[$1.0].count }
        return hits.prefix(limit).map { (items[$0.0], $0.1) }
    }
}
