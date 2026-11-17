import Foundation

public struct ListeningStats: Sendable {
    public struct Item: Sendable, Identifiable, Hashable {
        public var id: String { key }
        public var key: String
        public var title: String
        public var subtitle: String?
        public var plays: Int
        public var seconds: Double
    }

    public var plays = 0
    public var seconds: Double = 0
    public var tracks = 0
    public var artists = 0
    public var topArtists: [Item] = []
    public var topAlbums: [Item] = []
    public var topTracks: [Item] = []
    /// Listening time per local calendar day, oldest first, gaps filled with zero.
    public var days: [(day: Date, seconds: Double)] = []

    public init() {}
}

/// Plays are recorded once a track counts as listened (the scrobble rule), whether or not any service is connected.
extension LibraryStore {
    func createHistory() throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS plays(
                path TEXT NOT NULL, at REAL NOT NULL, artist TEXT, title TEXT, album TEXT, duration REAL
            );
            CREATE INDEX IF NOT EXISTS plays_at ON plays(at);
            CREATE INDEX IF NOT EXISTS plays_path ON plays(path);
            """)
    }

    public func recordPlay(_ m: TrackMetadata, at date: Date) {
        locked {
            try? db.prepare("INSERT INTO plays(path, at, artist, title, album, duration) VALUES(?, ?, ?, ?, ?, ?)")
                .bind([m.path.pathKey, date.timeIntervalSince1970, m.artist, m.displayTitle, m.album, m.duration]).run()
        }
    }

    public func stats(since: Date?, limit: Int = 25) -> ListeningStats {
        let from = since?.timeIntervalSince1970 ?? 0
        return locked {
            var s = ListeningStats()
            if let q = try? db.prepare("SELECT COUNT(*), TOTAL(duration), COUNT(DISTINCT path), COUNT(DISTINCT lower(artist)) FROM plays WHERE at >= ?"),
               q.bind([from]).step() {
                s.plays = q.int(0) ?? 0
                s.seconds = q.double(1)
                s.tracks = q.int(2) ?? 0
                s.artists = q.int(3) ?? 0
            }
            s.topArtists = items("""
                SELECT lower(artist), MAX(artist), NULL, COUNT(*), TOTAL(duration) FROM plays
                WHERE at >= ? AND artist IS NOT NULL GROUP BY lower(artist) ORDER BY 4 DESC, 5 DESC LIMIT ?
                """, from, limit)
            s.topAlbums = items("""
                SELECT lower(album) || '|' || lower(IFNULL(artist, '')), MAX(album), MAX(artist), COUNT(*), TOTAL(duration) FROM plays
                WHERE at >= ? AND album IS NOT NULL GROUP BY 1 ORDER BY 4 DESC, 5 DESC LIMIT ?
                """, from, limit)
            s.topTracks = items("""
                SELECT path, MAX(title), MAX(artist), COUNT(*), TOTAL(duration) FROM plays
                WHERE at >= ? GROUP BY path ORDER BY 4 DESC, MAX(at) DESC LIMIT ?
                """, from, limit)
            s.days = days(since: since)
            return s
        }
    }

    private func items(_ sql: String, _ from: Double, _ limit: Int) -> [ListeningStats.Item] {
        guard let q = try? db.prepare(sql) else { return [] }
        q.bind([from, limit])
        var out: [ListeningStats.Item] = []
        while q.step() {
            out.append(.init(key: q.string(0) ?? "", title: q.string(1) ?? "", subtitle: q.string(2), plays: q.int(3) ?? 0, seconds: q.double(4)))
        }
        return out
    }

    private func days(since: Date?) -> [(day: Date, seconds: Double)] {
        guard let q = try? db.prepare("SELECT at, duration FROM plays WHERE at >= ? ORDER BY at") else { return [] }
        q.bind([since?.timeIntervalSince1970 ?? 0])
        let cal = Calendar.current
        var byDay: [Date: Double] = [:]
        var first: Date?
        while q.step() {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: q.double(0)))
            first = first ?? d
            byDay[d, default: 0] += q.double(1)
        }
        guard var day = since.map(cal.startOfDay) ?? first else { return [] }
        let today = cal.startOfDay(for: Date())
        var out: [(Date, Double)] = []
        while day <= today {
            out.append((day, byDay[day] ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    // MARK: Smart playlists

    public enum SmartList: String, CaseIterable, Sendable {
        case mostPlayed, recentlyPlayed, recentlyAdded, neverPlayed

        public var title: String {
            switch self {
            case .mostPlayed: return "Most Played"
            case .recentlyPlayed: return "Recently Played"
            case .recentlyAdded: return "Recently Added"
            case .neverPlayed: return "Never Played"
            }
        }
    }

    public func smartList(_ kind: SmartList, limit: Int = 200) -> [String] {
        let sql: String
        switch kind {
        case .mostPlayed:
            sql = "SELECT path FROM plays GROUP BY path ORDER BY COUNT(*) DESC, MAX(at) DESC LIMIT ?"
        case .recentlyPlayed:
            sql = "SELECT path FROM plays GROUP BY path ORDER BY MAX(at) DESC LIMIT ?"
        case .recentlyAdded:
            sql = "SELECT path FROM tracks ORDER BY mtime DESC, path LIMIT ?"
        case .neverPlayed:
            sql = "SELECT path FROM tracks WHERE path NOT IN (SELECT path FROM plays) ORDER BY mtime DESC, path LIMIT ?"
        }
        return locked {
            guard let q = try? db.prepare(sql) else { return [] }
            q.bind([limit])
            var out: [String] = []
            while q.step() { if let p = q.string(0) { out.append(p) } }
            return out
        }
    }

    public func playCount(_ path: String) -> (plays: Int, last: Date?) {
        locked {
            guard let q = try? db.prepare("SELECT COUNT(*), MAX(at) FROM plays WHERE path = ?"), q.bind([path.pathKey]).step() else { return (0, nil) }
            let n = q.int(0) ?? 0
            return (n, n > 0 ? Date(timeIntervalSince1970: q.double(1)) : nil)
        }
    }
}
