import Foundation

/// A studio album as MusicBrainz lists it: primary type Album, no secondary type (live, compilation, soundtrack…).
public struct StudioAlbum: Codable, Sendable, Hashable, Identifiable {
    /// MusicBrainz release-group id.
    public var id: String
    public var title: String
    public var year: String?

    public init(id: String, title: String, year: String?) {
        self.id = id
        self.title = title
        self.year = year
    }

    public var url: URL { URL(string: "https://musicbrainz.org/release-group/\(id)")! }
}

public struct ArtistDiscography: Codable, Sendable {
    /// nil when MusicBrainz has no confident match for the name.
    public var mbid: String?
    public var name: String
    public var albums: [StudioAlbum]
    public var fetched: Date

    public var url: URL? { mbid.map { URL(string: "https://musicbrainz.org/artist/\($0)")! } }
}

/// One artist folder of the library and the album titles it holds.
public struct LocalArtist: Sendable {
    public var folder: String
    public var name: String
    /// Normalized titles from album tags and folder names.
    public var albums: Set<String>

    public func owns(_ album: StudioAlbum) -> Bool {
        let n = Discography.normalize(album.title)
        if albums.contains(n) { return true }
        // "Born to Die – The Paradise Edition" holds "Born to Die".
        return n.count >= 5 && albums.contains { $0.count >= 5 && ($0.hasPrefix(n) || n.hasPrefix($0)) }
    }
}

public enum Discography {
    /// Top-level folders of each root, one per artist. Folders named in `excluded` (lowercased) are skipped.
    public static func localArtists(_ tracks: [TrackMetadata], roots: [URL], excluded: Set<String> = ["ost"]) -> [LocalArtist] {
        var byFolder: [String: [(TrackMetadata, [Substring])]] = [:]
        for t in tracks {
            let path = t.path.precomposedStringWithCanonicalMapping
            guard let root = roots.map({ $0.path.precomposedStringWithCanonicalMapping }).first(where: { path.hasPrefix($0 + "/") })
            else { continue }
            let parts = path.dropFirst(root.count + 1).split(separator: "/")
            guard parts.count > 1, !excluded.contains(parts[0].lowercased()) else { continue }
            byFolder[root + "/" + parts[0], default: []].append((t, Array(parts.dropFirst().dropLast())))
        }
        return byFolder.map { folder, items in
            // Tags may be mojibake or name a featured artist, so the folder name wins
            // unless it merely extends the tag ("Kanye West ALAC").
            let base = (folder as NSString).lastPathComponent
            let tagged = DuplicateFinder.mostCommon(items.compactMap { $0.0.albumArtist ?? $0.0.artist })
            let name = tagged.flatMap { t in normalize(base).hasPrefix(normalize(t)) && !normalize(t).isEmpty ? t : nil } ?? base
            let prefixes = Set([base, tagged ?? base].map(normalize))
            var albums = Set<String>()
            for (t, dirs) in items {
                if let a = t.album { albums.insert(normalize(a)) }
                // Folders below the artist folder only: a self-titled album must not match the artist folder itself.
                for d in dirs.suffix(2) {
                    let n = normalize(folderTitle(String(d)))
                    albums.insert(n)
                    // "Childish Gambino - Atavista (2024)"
                    for p in prefixes where n.count > p.count && n.hasPrefix(p) { albums.insert(String(n.dropFirst(p.count))) }
                }
            }
            albums.remove("")
            return LocalArtist(folder: folder, name: name, albums: albums)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "2013 - Kveikur [FLAC]" → "Kveikur".
    static func folderTitle(_ name: String) -> String {
        let t = name.replacingOccurrences(of: #"^\s*[\(\[]?(19|20)\d\d[\)\]]?\s*[-–.]?\s*"#, with: "", options: .regularExpression)
        return t.isEmpty ? name : t
    }

    /// Case, accents, punctuation, "&" vs "and" and any bracketed suffix don't tell albums apart.
    /// Symbol-only titles ("+", "×", "÷") keep their symbols, with the usual spellings folded together.
    static func normalize(_ s: String) -> String {
        let bare = s.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
        var folded = (bare.isEmpty ? s : bare).replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (a, b) in [("×", "x"), ("÷", "divide"), ("–", "-"), ("—", "-"), ("−", "-")] {
            folded = folded.replacingOccurrences(of: a, with: b)
        }
        let alnum = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        return alnum.isEmpty ? folded.filter { !$0.isWhitespace } : alnum
    }
}

/// MusicBrainz lookups, cached on disk and paced to the service's one request per second.
public actor MusicBrainz {
    public static let ttl: TimeInterval = 30 * 86400
    private let cacheURL: URL
    private var cache: [String: ArtistDiscography]
    private var lastRequest = Date.distantPast

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kveikur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("musicbrainz.json")
        cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: ArtistDiscography].self, from: $0) } ?? [:]
    }

    public func cached(_ name: String) -> ArtistDiscography? {
        guard let d = cache[Discography.normalize(name)], Date().timeIntervalSince(d.fetched) < Self.ttl else { return nil }
        return d
    }

    /// Namesakes are told apart by how many of `local`'s albums each one has.
    public func discography(for local: LocalArtist, refresh: Bool = false) async throws -> ArtistDiscography {
        let name = local.name
        if !refresh, let d = cached(name) { return d }
        var d = ArtistDiscography(mbid: nil, name: name, albums: [], fetched: Date())
        var best = (-1, -1)
        for artist in try await findArtists(name).prefix(5) {
            let albums = try await studioAlbums(artist.id)
            let score = (albums.filter(local.owns).count, albums.count)
            if score > best {
                best = score
                d.mbid = artist.id
                d.name = artist.name
                d.albums = albums
            }
        }
        cache[Discography.normalize(name)] = d
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        return d
    }

    // MARK: API

    struct ArtistHit: Decodable {
        struct Alias: Decodable { let name: String }
        let id: String
        let name: String
        let score: Int?
        let aliases: [Alias]?
    }

    func findArtists(_ name: String) async throws -> [ArtistHit] {
        struct Response: Decodable { let artists: [ArtistHit] }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        c.queryItems = [URLQueryItem(name: "query", value: "artist:\"\(escaped)\""), URLQueryItem(name: "limit", value: "5"),
                        URLQueryItem(name: "fmt", value: "json")]
        let hits = try JSONDecoder().decode(Response.self, from: try await get(c.url!)).artists
        return Self.pick(hits, for: name)
    }

    /// Hits whose name or alias matches, best score first; failing that a lone 100 (transliterated names).
    static func pick(_ hits: [ArtistHit], for name: String) -> [ArtistHit] {
        let n = Discography.normalize(name)
        let named = hits.filter { h in
            (h.score ?? 0) >= 80 && ([h.name] + (h.aliases ?? []).map(\.name)).contains { Discography.normalize($0) == n }
        }
        if !named.isEmpty { return named }
        return hits.first.flatMap { ($0.score ?? 0) == 100 ? [$0] : nil } ?? []
    }

    func studioAlbums(_ artist: String) async throws -> [StudioAlbum] {
        struct Group: Decodable {
            let id: String
            let title: String
            let primaryType: String?
            let secondaryTypes: [String]?
            let firstReleaseDate: String?
            enum CodingKeys: String, CodingKey {
                case id, title
                case primaryType = "primary-type", secondaryTypes = "secondary-types", firstReleaseDate = "first-release-date"
            }
        }
        struct Response: Decodable {
            let groups: [Group]
            let count: Int
            enum CodingKeys: String, CodingKey { case groups = "release-groups", count = "release-group-count" }
        }
        var all: [Group] = []
        repeat {
            var c = URLComponents(string: "https://musicbrainz.org/ws/2/release-group")!
            c.queryItems = [URLQueryItem(name: "artist", value: artist), URLQueryItem(name: "type", value: "album"),
                            URLQueryItem(name: "release-group-status", value: "website-default"),
                            URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(all.count)),
                            URLQueryItem(name: "fmt", value: "json")]
            let r = try JSONDecoder().decode(Response.self, from: try await get(c.url!))
            all += r.groups
            if r.groups.isEmpty || all.count >= r.count { break }
        } while true
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return all
            .filter { $0.primaryType == "Album" && ($0.secondaryTypes ?? []).isEmpty }
            .compactMap { g in
                guard let date = g.firstReleaseDate, !date.isEmpty, date <= today else { return nil }
                return StudioAlbum(id: g.id, title: g.title, year: String(date.prefix(4)))
            }
            .sorted { ($0.year ?? "", $0.title) < ($1.year ?? "", $1.title) }
    }

    private func get(_ url: URL) async throws -> Data {
        // 503 means "slow down"; back off 2, 4, 8, 16 s.
        for attempt in 0..<5 {
            let wait = 1.1 - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastRequest = Date()
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Kveikur/0.2 ( https://github.com/asahium/kveikur )", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            if status != 503 || attempt == 4 { throw URLError(.badServerResponse, userInfo: ["status": status, "url": url.absoluteString]) }
            try await Task.sleep(for: .seconds(pow(2, Double(attempt + 1))))
        }
        throw URLError(.badServerResponse)
    }
}
