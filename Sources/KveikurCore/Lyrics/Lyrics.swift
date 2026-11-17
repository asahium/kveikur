import Foundation

public struct LyricLine: Hashable, Codable, Sendable {
    public var time: TimeInterval?
    public var text: String
}

public struct Lyrics: Hashable, Codable, Sendable {
    public var source: String
    public var lines: [LyricLine]
    /// Positive shows lines later, negative earlier.
    public var offset: TimeInterval = 0

    public var synced: Bool { lines.contains { $0.time != nil } }

    /// Index of the line being sung at `time`.
    public func activeIndex(at time: TimeInterval) -> Int? {
        guard synced else { return nil }
        let t = time - offset
        var lo = 0
        var hi = lines.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let lt = lines[mid].time, lt <= t {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }
}

public enum LRCParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    public static func parse(_ text: String, source: String) -> Lyrics {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0
        var anyStamp = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {
                let v = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                offset = (Double(v) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            var consumed = 0
            var times: [TimeInterval] = []
            for m in matches where m.range.location == consumed {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                times.append(min * 60 + sec + frac)
                consumed = m.range.location + m.range.length
            }
            if times.isEmpty {
                // Skip ID tags such as [ar:...] but keep plain text lines.
                if line.hasPrefix("["), line.hasSuffix("]"), line.contains(":") { continue }
                lines.append(LyricLine(time: nil, text: line))
            } else {
                anyStamp = true
                let body = ns.substring(from: consumed).trimmingCharacters(in: .whitespaces)
                for t in times { lines.append(LyricLine(time: t, text: body)) }
            }
        }
        if anyStamp {
            lines = lines.filter { $0.time != nil }.sorted { $0.time! < $1.time! }
        } else {
            while lines.first?.text.isEmpty == true { lines.removeFirst() }
            while lines.last?.text.isEmpty == true { lines.removeLast() }
        }
        return Lyrics(source: source, lines: lines, offset: offset)
    }

    public static func serialize(_ lyrics: Lyrics) -> String {
        var out: [String] = []
        if lyrics.offset != 0 { out.append("[offset:\(Int(lyrics.offset * 1000))]") }
        for l in lyrics.lines {
            if let t = l.time {
                let m = Int(t) / 60
                let s = t - Double(m * 60)
                out.append(String(format: "[%02d:%05.2f]%@", m, s, l.text))
            } else {
                out.append(l.text)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
