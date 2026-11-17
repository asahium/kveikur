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
    /// Raw LRC or plain text, nil when nothing was found.
    func fetch(_ q: LyricsQuery) async throws -> String?
}

private let userAgent = "Kveikur/0.1 (macOS music player)"

/// lrclib.net: free, no key, returns synced LRC.
public struct LRCLibProvider: LyricsProvider {
    public let name = "LRCLIB"
    public init() {}

    private struct Item: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    public func fetch(_ q: LyricsQuery) async throws -> String? {
        if let text = try await lookup(q, title: q.title) { return text }
        let cleaned = q.cleanedTitle
        guard !cleaned.isEmpty, cleaned != q.title else { return nil }
        return try await lookup(q, title: cleaned)
    }

    private func lookup(_ q: LyricsQuery, title: String) async throws -> String? {
        var q = q
        q.title = title
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "track_name", value: q.title),
            URLQueryItem(name: "artist_name", value: q.artist),
            URLQueryItem(name: "album_name", value: q.album ?? ""),
            URLQueryItem(name: "duration", value: String(Int(q.duration.rounded()))),
        ]
        if let item: Item = try await request(get.url!), let text = item.syncedLyrics ?? item.plainLyrics, !text.isEmpty {
            return text
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist)]
        guard let items: [Item] = try await request(search.url!), !items.isEmpty else { return nil }
        let close = items.filter { abs(($0.duration ?? q.duration) - q.duration) < 4 }
        let pool = close.isEmpty ? items : close
        let best = pool.first { $0.syncedLyrics?.isEmpty == false } ?? pool.first
        return best?.syncedLyrics ?? best?.plainLyrics
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Genius: search through the API (token required), lyrics scraped from the song page. Plain text only.
public struct GeniusProvider: LyricsProvider {
    public let name = "Genius"
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
        for ext in ["lrc", "LRC", "txt"] {
            if let text = try? String(contentsOf: base.appendingPathExtension(ext), encoding: .utf8) {
                return LRCParser.parse(text, source: ".\(ext.lowercased()) file")
            }
        }
        if let embedded = await MetadataReader.embeddedLyrics(url), !embedded.isEmpty {
            return LRCParser.parse(embedded, source: "Embedded tags")
        }
        return nil
    }

    /// Asks providers in order, preferring synced lyrics. A clean miss (no network errors) is remembered for `missTTL`.
    public func fetchOnline(_ q: LyricsQuery, providers: [LyricsProvider]) async -> Lyrics? {
        var plainFallback: Lyrics?
        var failed = false
        for p in providers {
            let raw: String?
            do { raw = try await p.fetch(q) } catch { failed = true; continue }
            guard let raw, !raw.isEmpty else { continue }
            let lyrics = LRCParser.parse(raw, source: p.name)
            if lyrics.synced {
                store(lyrics, for: q.url)
                return lyrics
            }
            if plainFallback == nil { plainFallback = lyrics }
        }
        if let l = plainFallback {
            store(l, for: q.url)
        } else if !failed, !Task.isCancelled {
            FileManager.default.createFile(atPath: missFile(q.url).path, contents: Data())
        }
        return plainFallback
    }

    public func store(_ lyrics: Lyrics, for url: URL) {
        let text = LRCParser.serialize(lyrics)
        try? FileManager.default.removeItem(at: missFile(url))
        try? text.write(to: cacheFile(url), atomically: true, encoding: .utf8)
        try? lyrics.source.write(to: sourceFile(url), atomically: true, encoding: .utf8)
        if saveSidecar {
            try? text.write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        }
    }
}
