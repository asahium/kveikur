import CryptoKit
import Foundation

public struct LyricsQuery: Sendable {
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval

    public init(url: URL, title: String, artist: String, album: String?, duration: TimeInterval) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// Title without track numbers, "feat." credits and edition tags like "(Remastered 2011)" or "[Live]".
    public var cleanedTitle: String {
        var t = title
        t = t.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.)_]?\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(feat|ft\.|with |remaster|live|version|edit|mix|mono|stereo|deluxe|bonus|explicit)[^\)\]]*[\)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+-\s+(\d{4}\s+)?remaster(ed)?.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }
}

public protocol LyricsProvider: Sendable {
    var name: String { get }
    /// Best `Lyrics.rank` this source can return; providers that can't beat what's already found are skipped.
    var maxRank: Int { get }
    /// Raw Lyricsfile, YRC, LRC or plain text; nil when nothing was found.
    func fetch(_ q: LyricsQuery) async throws -> String?
}

public extension LyricsProvider {
    var maxRank: Int { 2 }
}

/// Case, accents and punctuation folded away, for comparing titles and artist names across services.
func lyricsKey(_ s: String) -> String {
    let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

private let userAgent = "Kveikur/0.1 (macOS music player)"

/// lrclib.net: free, no key. Records carry a Lyricsfile, word-synced when `hasWordSync` is set.
public struct LRCLibProvider: LyricsProvider {
    public let name = "LRCLIB"
    public init() {}

    struct Item: Decodable {
        let artistName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
        let lyricsfile: String?
        let hasWordSync: Bool?
        let duration: Double?

        var best: String? {
            if hasWordSync == true, let f = lyricsfile, !f.isEmpty { return f }
            if let s = syncedLyrics, !s.isEmpty { return s }
            if let p = plainLyrics, !p.isEmpty { return p }
            return nil
        }
        var rank: Int { hasWordSync == true ? 2 : (syncedLyrics?.isEmpty == false ? 1 : 0) }
    }

    public func fetch(_ q: LyricsQuery) async throws -> String? {
        if let text = try await lookup(q, title: q.title) { return text }
        let cleaned = q.cleanedTitle
        guard !cleaned.isEmpty, cleaned != q.title else { return nil }
        return try await lookup(q, title: cleaned)
    }

    /// The exact match first; if it isn't word-synced, a search may still find a word-synced record of the same song.
    private func lookup(_ q: LyricsQuery, title: String) async throws -> String? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: q.artist),
            URLQueryItem(name: "album_name", value: q.album ?? ""),
            URLQueryItem(name: "duration", value: String(Int(q.duration.rounded()))),
        ]
        let exact: Item? = try await request(get.url!)
        if let exact, exact.rank == 2, let text = exact.best { return text }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: q.artist)]
        let items: [Item] = (try await request(search.url!)) ?? []
        let artist = lyricsKey(q.artist)
        let close = items.filter { abs(($0.duration ?? q.duration) - q.duration) < 4 }
        if let w = close.first(where: { $0.rank == 2 && lyricsKey($0.artistName ?? "").contains(artist) }), let text = w.best {
            return text
        }
        if let text = exact?.best { return text }
        let pool = close.isEmpty ? items : close
        return pool.max { $0.rank < $1.rank }?.best
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// NetEase Cloud Music's public web API: word-synced YRC for much of its catalogue, line LRC otherwise.
/// Only a song whose artist, title and length all match is used.
public struct NetEaseProvider: LyricsProvider {
    public let name = "NetEase"
    public init() {}

    private struct Search: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable { let id: Int; let name: String; let duration: Double?; let artists: [Artist] }
        struct Artist: Decodable { let name: String }
        let result: Result?
    }

    private struct LyricResponse: Decodable {
        struct Body: Decodable { let lyric: String? }
        let lrc: Body?
        let yrc: Body?
    }

    public func fetch(_ q: LyricsQuery) async throws -> String? {
        let title = q.cleanedTitle.isEmpty ? q.title : q.cleanedTitle
        var c = URLComponents(string: "https://music.163.com/api/search/get")!
        c.queryItems = [URLQueryItem(name: "s", value: "\(q.artist) \(title)"), URLQueryItem(name: "type", value: "1"),
                        URLQueryItem(name: "limit", value: "10")]
        guard let found: Search = try await request(c.url!) else { return nil }
        // The same song is often uploaded several times, and only some copies carry YRC.
        var lineSynced: String?
        for song in (found.result?.songs ?? []).filter({ matches($0, q, title: title) }).prefix(3) {
            var l = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
            l.queryItems = ["lv", "yv"].map { URLQueryItem(name: $0, value: "1") } + [URLQueryItem(name: "id", value: String(song.id))]
            guard let r: LyricResponse = try await request(l.url!) else { continue }
            if let yrc = Self.body(r.yrc?.lyric) { return yrc }
            lineSynced = lineSynced ?? Self.body(r.lrc?.lyric)
        }
        return lineSynced
    }

    /// Drops the JSON credit lines NetEase puts in front.
    private static func body(_ raw: String?) -> String? {
        let lines = (raw ?? "").components(separatedBy: .newlines).filter { !$0.hasPrefix("{") && !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func matches(_ s: Search.Song, _ q: LyricsQuery, title: String) -> Bool {
        if let d = s.duration, q.duration > 0, abs(d / 1000 - q.duration) > 3 { return false }
        let a = lyricsKey(q.artist), t = lyricsKey(title), st = lyricsKey(s.name)
        guard !t.isEmpty, st == t || st.hasPrefix(t) || t.hasPrefix(st) && !st.isEmpty else { return false }
        return s.artists.contains { x in
            let k = lyricsKey(x.name)
            return !k.isEmpty && (a.contains(k) || k.contains(a))
        }
    }

    /// Once NetEase has set its cookies, search ignores the query and returns trending songs.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()

    private func request<T: Decodable>(_ url: URL) async throws -> T? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        let (data, resp) = try await Self.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Genius: search through the API (token required), lyrics scraped from the song page. Plain text only.
public struct GeniusProvider: LyricsProvider {
    public let name = "Genius"
    public let maxRank = 0
    let token: String

    public init(token: String) { self.token = token }

    private struct SearchResponse: Decodable {
        struct Response: Decodable { let hits: [Hit] }
        struct Hit: Decodable { let type: String; let result: Song }
        struct Song: Decodable { let url: String; let title: String; let primary_artist: Artist }
        struct Artist: Decodable { let name: String }
        let response: Response
    }

    public func fetch(_ q: LyricsQuery) async throws -> String? {
        guard !token.isEmpty else { return nil }
        var c = URLComponents(string: "https://api.genius.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(q.artist) \(q.title)")]
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let songs = decoded.response.hits.filter { $0.type == "song" }.map(\.result)
        let artist = q.artist.lowercased()
        guard let song = songs.first(where: { $0.primary_artist.name.lowercased().contains(artist) || artist.contains($0.primary_artist.name.lowercased()) }) ?? songs.first,
              let pageURL = URL(string: song.url) else { return nil }
        var page = URLRequest(url: pageURL, timeoutInterval: 15)
        page.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (html, _) = try await URLSession.shared.data(for: page)
        guard let s = String(data: html, encoding: .utf8) else { return nil }
        let text = Self.extractLyrics(s)
        return text.isEmpty ? nil : text
    }

    static func extractLyrics(_ html: String) -> String {
        var parts: [String] = []
        var search = html.startIndex
        while let r = html.range(of: "data-lyrics-container=\"true\"", range: search..<html.endIndex),
              let open = html[r.upperBound...].firstIndex(of: ">") {
            let inner = html.index(after: open)
            let end = elementEnd(html, from: inner)
            parts.append(String(html[inner..<end]))
            search = end
        }
        var text = parts.joined(separator: "\n")
        text = removeElements(text, marker: "data-exclude-from-selection=\"true\"")
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index of the `</div>` closing the element whose content starts at `from`.
    private static func elementEnd(_ s: String, from: String.Index) -> String.Index {
        var depth = 1
        var i = from
        while i < s.endIndex {
            if s[i...].hasPrefix("<div") { depth += 1 }
            else if s[i...].hasPrefix("</div") {
                depth -= 1
                if depth == 0 { return i }
            }
            i = s.index(after: i)
        }
        return s.endIndex
    }

    private static func removeElements(_ s: String, marker: String) -> String {
        var out = s
        while let r = out.range(of: marker),
              let tagStart = out[..<r.lowerBound].range(of: "<div", options: .backwards),
              let open = out[r.upperBound...].firstIndex(of: ">") {
            let end = elementEnd(out, from: out.index(after: open))
            let close = out[end...].firstIndex(of: ">").map { out.index(after: $0) } ?? out.endIndex
            out.removeSubrange(tagStart.lowerBound..<close)
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) {
                result.unicodeScalars.append(u)
            }
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }
}

/// Resolution order: app cache, sidecar .lrc/.txt, embedded tags, then online providers.
public final class LyricsService: @unchecked Sendable {
    private let cacheDir: URL
    public var saveSidecar = false

    public init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDir = support.appendingPathComponent("Kveikur/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func cacheFile(_ url: URL) -> URL {
        let d = SHA256.hash(data: Data(url.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(d + ".lrc")
    }

    private func sourceFile(_ url: URL) -> URL { cacheFile(url).appendingPathExtension("source") }
    private func missFile(_ url: URL) -> URL { cacheFile(url).deletingPathExtension().appendingPathExtension("miss") }

    /// How long a "nothing found online" answer is trusted before automatic lookups try again.
    public var missTTL: TimeInterval = 3 * 86400

    public func recentlyMissed(_ url: URL) -> Bool {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: missFile(url).path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(d) < missTTL
    }

    public func local(for url: URL) async -> Lyrics? {
        let cache = cacheFile(url)
        if let text = try? String(contentsOf: cache, encoding: .utf8) {
            let source = (try? String(contentsOf: sourceFile(url), encoding: .utf8)) ?? "Cache"
            return LRCParser.parse(text, source: source)
        }
        let base = url.deletingPathExtension()
        for ext in ["lyricsfile.yaml", "lyricsfile", "lrc", "LRC", "txt"] {
            if let text = try? String(contentsOf: base.appendingPathExtension(ext), encoding: .utf8) {
                let name = ext.hasPrefix("lyricsfile") ? "Lyricsfile" : ".\(ext.lowercased()) file"
                return LyricsFormat.parse(text, source: name)
            }
        }
        if let embedded = await MetadataReader.embeddedLyrics(url), !embedded.isEmpty {
            return LyricsFormat.parse(embedded, source: "Embedded tags")
        }
        return nil
    }

    /// Asks providers in order and keeps the best: word-synced, then line-synced, then plain.
    /// A clean miss (no network errors) is remembered for `missTTL`.
    public func fetchOnline(_ q: LyricsQuery, providers: [LyricsProvider]) async -> Lyrics? {
        var best: Lyrics?
        var failed = false
        for p in providers {
            if let b = best, b.rank >= p.maxRank { continue }
            let raw: String?
            do { raw = try await p.fetch(q) } catch { failed = true; continue }
            guard let raw, !raw.isEmpty else { continue }
            var lyrics = LyricsFormat.parse(raw, source: p.name)
            // "Love Letters - Metronomy" header lines.
            let credits = Set([q.title + q.artist, q.artist + q.title, q.cleanedTitle + q.artist, q.artist + q.cleanedTitle].map(lyricsKey))
            lyrics.lines.removeAll { credits.contains(lyricsKey($0.text)) }
            guard !lyrics.lines.isEmpty else { continue }
            // Better timing doesn't make up for a mangled text (NetEase spells Icelandic "Þú" as "Pú").
            if let b = best, b.synced, Self.similarity(b, lyrics) < 0.9 { continue }
            if best == nil || lyrics.rank > best!.rank { best = lyrics }
            if lyrics.rank == 2 { break }
        }
        if let best {
            store(best, for: q.url)
        } else if !failed, !Task.isCancelled {
            FileManager.default.createFile(atPath: missFile(q.url).path, contents: Data())
        }
        return best
    }

    /// Dice coefficient over character bigrams of the whole text, case and punctuation ignored.
    static func similarity(_ a: Lyrics, _ b: Lyrics) -> Double {
        func bigrams(_ l: Lyrics) -> [String: Int] {
            let s = Array(l.lines.map { $0.text.lowercased() }.joined().filter { $0.isLetter || $0.isNumber })
            var out: [String: Int] = [:]
            for i in s.indices.dropLast() { out[String(s[i...i + 1]), default: 0] += 1 }
            return out
        }
        let x = bigrams(a), y = bigrams(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 1 }
        let shared = x.reduce(0) { $0 + min($1.value, y[$1.key] ?? 0) }
        return 2 * Double(shared) / Double(total)
    }

    public func store(_ lyrics: Lyrics, for url: URL) {
        let text = LRCParser.serialize(lyrics)
        try? FileManager.default.removeItem(at: missFile(url))
        try? text.write(to: cacheFile(url), atomically: true, encoding: .utf8)
        try? lyrics.source.write(to: sourceFile(url), atomically: true, encoding: .utf8)
        if saveSidecar {
            // Word stamps confuse players that only know line LRC.
            try? LRCParser.serialize(lyrics, words: false)
                .write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        }
    }
}
