import Foundation

public struct LyricWord: Hashable, Codable, Sendable {
    public var time: TimeInterval
    public var end: TimeInterval?
    /// Includes the whitespace that follows it, so joining words rebuilds the line.
    public var text: String

    public init(time: TimeInterval, end: TimeInterval? = nil, text: String) {
        self.time = time
        self.end = end
        self.text = text
    }
}

public struct LyricLine: Hashable, Codable, Sendable {
    public var time: TimeInterval?
    public var text: String
    public var end: TimeInterval? = nil
    /// Word-level timing when the source has it.
    public var words: [LyricWord]? = nil

    /// How far each word has been sung at `t` (already offset-corrected), 0...1.
    public func wordFill(at t: TimeInterval) -> [Double] {
        guard let words, !words.isEmpty else { return [] }
        return words.indices.map { i in
            let w = words[i]
            let end = w.end ?? (i + 1 < words.count ? words[i + 1].time : (self.end ?? w.time + 0.6))
            guard t > w.time else { return 0 }
            return min(1, (t - w.time) / max(0.05, end - w.time))
        }
    }
}

public struct Lyrics: Hashable, Codable, Sendable {
    public var source: String
    public var lines: [LyricLine]
    /// Positive shows lines later, negative earlier.
    public var offset: TimeInterval = 0

    public init(source: String, lines: [LyricLine], offset: TimeInterval = 0) {
        self.source = source
        self.lines = lines
        self.offset = offset
    }

    public var synced: Bool { lines.contains { $0.time != nil } }
    public var wordSynced: Bool { lines.contains { $0.words?.isEmpty == false } }
    /// 2 word-synced, 1 line-synced, 0 plain.
    public var rank: Int { wordSynced ? 2 : (synced ? 1 : 0) }
    public var syncLabel: String { wordSynced ? "word-synced" : (synced ? "synced" : "plain") }

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

/// Picks the parser from the text itself: Lyricsfile YAML, NetEase YRC, or (enhanced) LRC / plain text.
public enum LyricsFormat {
    public static func parse(_ raw: String, source: String) -> Lyrics {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("version:") || text.hasPrefix("---\nversion:"), let l = LyricsfileParser.parse(text, source: source) {
            return l
        }
        // NetEase prefixes credits as JSON lines.
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("{") }.joined(separator: "\n")
        if body.range(of: #"^\[\d+,\d+\]"#, options: .regularExpression) != nil { return YRCParser.parse(body, source: source) }
        return LRCParser.parse(body, source: source)
    }
}

public enum LRCParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordStamp = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    private static func seconds(_ ns: NSString, _ m: NSTextCheckingResult) -> TimeInterval {
        let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
        var frac = 0.0
        if m.range(at: 3).location != NSNotFound {
            let f = ns.substring(with: m.range(at: 3))
            frac = (Double(f) ?? 0) / pow(10, Double(f.count))
        }
        return min * 60 + sec + frac
    }

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
                times.append(seconds(ns, m))
                consumed = m.range.location + m.range.length
            }
            if times.isEmpty {
                // Skip ID tags such as [ar:...] but keep plain text lines.
                if line.hasPrefix("["), line.hasSuffix("]"), line.contains(":") { continue }
                lines.append(LyricLine(time: nil, text: line))
            } else {
                anyStamp = true
                let (body, words) = parseWords(ns.substring(from: consumed), lineTime: times[0])
                for t in times {
                    // A repeated line ([00:10][01:20]) shifts its word times along with it.
                    let shifted = words.map { $0.map { LyricWord(time: $0.time - times[0] + t, end: $0.end.map { $0 - times[0] + t }, text: $0.text) } }
                    lines.append(LyricLine(time: t, text: body, words: shifted))
                }
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

    /// Enhanced LRC: "<00:12.30>Some <00:12.80>words<00:13.40>". A trailing stamp ends the last word.
    static func parseWords(_ body: String, lineTime: TimeInterval) -> (String, [LyricWord]?) {
        let ns = body as NSString
        let matches = wordStamp.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (body.trimmingCharacters(in: .whitespaces), nil) }
        var words: [LyricWord] = []
        let lead = ns.substring(to: matches[0].range.location)
        if !lead.trimmingCharacters(in: .whitespaces).isEmpty { words.append(LyricWord(time: lineTime, text: lead)) }
        for (i, m) in matches.enumerated() {
            let t = seconds(ns, m)
            let start = m.range.location + m.range.length
            let stop = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: start, length: stop - start))
            if let last = words.indices.last, words[last].end == nil { words[last].end = t }
            if !text.isEmpty { words.append(LyricWord(time: t, text: text)) }
        }
        if let first = words.indices.first { words[first].text = String(words[first].text.drop { $0 == " " }) }
        if let last = words.indices.last { words[last].text = String(words[last].text.reversed().drop { $0 == " " }.reversed()) }
        return (words.map(\.text).joined(), words.isEmpty ? nil : words)
    }

    private static func stampString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return String(format: "%02d:%05.2f", m, t - Double(m * 60))
    }

    /// `words: false` writes plain line-synced LRC for other players.
    public static func serialize(_ lyrics: Lyrics, words: Bool = true) -> String {
        var out: [String] = []
        if lyrics.offset != 0 { out.append("[offset:\(Int(lyrics.offset * 1000))]") }
        for l in lyrics.lines {
            guard let t = l.time else { out.append(l.text); continue }
            var line = "[\(stampString(t))]"
            if words, let ws = l.words, !ws.isEmpty {
                for w in ws { line += "<\(stampString(w.time))>\(w.text)" }
                if let end = ws.last?.end ?? l.end { line += "<\(stampString(end))>" }
            } else {
                line += l.text
            }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// NetEase YRC: "[16240,3600](16240,270,0)We (16510,210,0)were …", times in milliseconds.
public enum YRCParser {
    private static let lineRE = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let wordRE = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)

    public static func parse(_ text: String, source: String) -> Lyrics {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = lineRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let start = Double(ns.substring(with: m.range(at: 1)))! / 1000
            let dur = Double(ns.substring(with: m.range(at: 2)))! / 1000
            let body = ns.substring(with: m.range(at: 3))
            let bns = body as NSString
            let words = wordRE.matches(in: body, range: NSRange(location: 0, length: bns.length)).map { w in
                let t = Double(bns.substring(with: w.range(at: 1)))! / 1000
                let d = Double(bns.substring(with: w.range(at: 2)))! / 1000
                return LyricWord(time: t, end: t + d, text: bns.substring(with: w.range(at: 3)))
            }
            let text = words.isEmpty ? body : words.map(\.text).joined()
            lines.append(LyricLine(time: start, text: text.trimmingCharacters(in: .whitespaces), end: start + dur,
                                   words: words.isEmpty ? nil : words))
        }
        return Lyrics(source: source, lines: lines.sorted { $0.time! < $1.time! })
    }
}

/// Lyricsfile 1.0 (LRCGET / LRCLIB): YAML with line and word timings in milliseconds.
public enum LyricsfileParser {
    public static func parse(_ text: String, source: String) -> Lyrics? {
        guard case .map(let root)? = MiniYAML.parse(text) else { return nil }
        let meta = root["metadata"]?.map ?? [:]
        if meta["instrumental"]?.string == "true" { return nil }
        func ms(_ v: MiniYAML.Node?) -> TimeInterval? { v?.string.flatMap(Double.init).map { $0 / 1000 } }
        let lines: [LyricLine] = (root["lines"]?.list ?? []).compactMap { n in
            guard let m = n.map, let start = ms(m["start_ms"]) else { return nil }
            let words: [LyricWord] = (m["words"]?.list ?? []).compactMap { w in
                guard let wm = w.map, let t = ms(wm["start_ms"]) else { return nil }
                return LyricWord(time: t, end: ms(wm["end_ms"]), text: wm["text"]?.string ?? "")
            }
            let text = m["text"]?.string ?? words.map(\.text).joined()
            return LyricLine(time: start, text: text, end: ms(m["end_ms"]), words: words.isEmpty ? nil : words)
        }
        if !lines.isEmpty {
            let offset = ms(meta["offset_ms"]) ?? 0
            return Lyrics(source: source, lines: lines.sorted { $0.time! < $1.time! }, offset: offset)
        }
        guard let plain = root["plain"]?.string, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LRCParser.parse(plain, source: source)
    }
}

/// The block-style YAML subset Lyricsfile uses: mappings, sequences (also at the parent key's indent),
/// plain / quoted scalars and literal blocks. No anchors, tags or flow collections beyond `[]` and `{}`.
enum MiniYAML {
    indirect enum Node {
        case scalar(String), list([Node]), map([String: Node])
        var string: String? { if case .scalar(let s) = self { return s }; return nil }
        var list: [Node]? { if case .list(let l) = self { return l }; return nil }
        var map: [String: Node]? { if case .map(let m) = self { return m }; return nil }
    }

    private struct Line { var indent: Int; var text: String; var raw: String }

    static func parse(_ text: String) -> Node? {
        var p = Parser(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { raw in
            let indent = raw.prefix { $0 == " " }.count
            return Line(indent: indent, text: String(raw.dropFirst(indent)), raw: raw)
        })
        p.skipBlank()
        if p.i < p.lines.count, p.lines[p.i].text == "---" { p.i += 1 }
        return p.node(minIndent: 0)
    }

    private struct Parser {
        var lines: [Line]
        var i = 0

        mutating func skipBlank() {
            while i < lines.count, lines[i].text.isEmpty || lines[i].text.hasPrefix("#") { i += 1 }
        }

        mutating func node(minIndent: Int) -> Node? {
            skipBlank()
            guard i < lines.count, lines[i].indent >= minIndent else { return nil }
            let l = lines[i]
            if l.text == "-" || l.text.hasPrefix("- ") { return .list(sequence(indent: l.indent)) }
            if Parser.splitKey(l.text) != nil { return .map(mapping(indent: l.indent)) }
            i += 1
            return .scalar(Parser.scalar(l.text))
        }

        mutating func sequence(indent: Int) -> [Node] {
            var items: [Node] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, lines[i].text == "-" || lines[i].text.hasPrefix("- ") else { break }
                let rest = lines[i].text == "-" ? "" : String(lines[i].text.dropFirst(2))
                if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                    items.append(node(minIndent: indent + 1) ?? .scalar(""))
                } else if Parser.splitKey(rest) != nil {
                    // "- key: v" opens a mapping at the column after the dash.
                    lines[i] = Line(indent: indent + 2, text: rest, raw: lines[i].raw)
                    items.append(.map(mapping(indent: indent + 2)))
                } else {
                    i += 1
                    items.append(.scalar(Parser.scalar(rest)))
                }
            }
            return items
        }

        mutating func mapping(indent: Int) -> [String: Node] {
            var out: [String: Node] = [:]
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, let (key, rest) = Parser.splitKey(lines[i].text) else { break }
                i += 1
                if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    out[key] = .scalar(block(parent: indent, folded: rest.hasPrefix(">"), keep: rest.contains("+"), strip: rest.contains("-")))
                } else if rest.isEmpty {
                    skipBlank()
                    if i < lines.count, lines[i].indent > indent {
                        out[key] = node(minIndent: indent + 1) ?? .scalar("")
                    } else if i < lines.count, lines[i].indent == indent, lines[i].text == "-" || lines[i].text.hasPrefix("- ") {
                        out[key] = .list(sequence(indent: indent))
                    } else {
                        out[key] = .scalar("")
                    }
                } else if rest == "[]" {
                    out[key] = .list([])
                } else if rest == "{}" {
                    out[key] = .map([:])
                } else {
                    out[key] = .scalar(Parser.scalar(rest))
                }
            }
            return out
        }

        mutating func block(parent: Int, folded: Bool, keep: Bool, strip: Bool) -> String {
            var body: [String] = []
            var indent: Int?
            while i < lines.count {
                let l = lines[i]
                if l.text.isEmpty { body.append(""); i += 1; continue }
                guard l.indent > parent else { break }
                indent = indent ?? l.indent
                body.append(String(l.raw.dropFirst(min(indent!, l.indent))))
                i += 1
            }
            var trailing = 0
            while body.last == "" { body.removeLast(); trailing += 1 }
            var s = folded ? body.joined(separator: " ") : body.joined(separator: "\n")
            if keep { s += String(repeating: "\n", count: trailing + 1) } else if !strip { s += "\n" }
            return s
        }

        /// "key: value" or "key:" with the key optionally quoted.
        static func splitKey(_ s: String) -> (String, String)? {
            var key: String
            var rest: Substring
            if let q = s.first, q == "'" || q == "\"" {
                guard let close = s.dropFirst().firstIndex(of: q) else { return nil }
                key = String(s[s.index(after: s.startIndex)..<close])
                rest = s[s.index(after: close)...]
                guard rest.hasPrefix(":") else { return nil }
            } else {
                guard let r = s.range(of: ": ") ?? (s.hasSuffix(":") ? s.range(of: ":", options: .backwards) : nil) else { return nil }
                key = String(s[..<r.lowerBound])
                if key.contains(" #") { return nil }
                rest = s[r.lowerBound...]
            }
            return (key, rest.dropFirst().trimmingCharacters(in: .whitespaces))
        }

        static func scalar(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("'"), t.hasSuffix("'"), t.count >= 2 {
                return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
                var out = ""
                var it = t.dropFirst().dropLast().makeIterator()
                while let c = it.next() {
                    guard c == "\\", let e = it.next() else { out.append(c); continue }
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "u", "U", "x":
                        let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                        var hex = ""
                        for _ in 0..<n { if let h = it.next() { hex.append(h) } }
                        if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    default: out.append(e)
                    }
                }
                return out
            }
            if let r = t.range(of: " #") { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return t == "~" || t == "null" ? "" : t
        }
    }
}
