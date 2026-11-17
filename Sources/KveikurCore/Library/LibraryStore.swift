import Foundation

public struct SearchRow: Sendable {
    public let path: String
    public let title: String?
    public let artist: String?
    public let album: String?
}

extension String {
    /// File system APIs hand out the same name as NFC or NFD; byte-keyed stores (SQLite, NSCache) need one form.
    public var pathKey: String { precomposedStringWithCanonicalMapping }

    var isPathKey: Bool { utf8.elementsEqual(pathKey.utf8) }
}

/// Persistent index of tag data and music folders. Thread-safe.
public final class LibraryStore: @unchecked Sendable {
    let db: SQLiteDB
    private let lock = NSRecursiveLock()

    private static let columns = """
        path, folder, mtime, size, title, artist, album, album_artist, genre, composer, year,
        track_no, track_total, disc_no, disc_total, duration, codec, sample_rate, bit_depth, channels, lossless, bitrate
        """

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Kveikur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite")
    }

    public init(url: URL = LibraryStore.defaultURL()) throws {
        db = try SQLiteDB(path: url.path)
        try db.exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS tracks(
                path TEXT PRIMARY KEY, folder TEXT NOT NULL, mtime REAL, size INTEGER,
                title TEXT, artist TEXT, album TEXT, album_artist TEXT, genre TEXT, composer TEXT, year TEXT,
                track_no INTEGER, track_total INTEGER, disc_no INTEGER, disc_total INTEGER, duration REAL,
                codec TEXT, sample_rate REAL, bit_depth INTEGER, channels INTEGER, lossless INTEGER, bitrate INTEGER
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS tracks_folder ON tracks(folder);
            CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, root TEXT NOT NULL) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS folders_root ON folders(root);
            """)
        try createHistory()
        dropDecomposedPaths()
    }

    private func dropDecomposedPaths() {
        for (table, column) in [("tracks", "path"), ("folders", "path")] {
            guard let s = try? db.prepare("SELECT \(column) FROM \(table)") else { continue }
            var bad: [String] = []
            while s.step() { if let p = s.string(0), !p.isPathKey { bad.append(p) } }
            guard !bad.isEmpty else { continue }
            try? db.transaction {
                let d = try db.prepare("DELETE FROM \(table) WHERE \(column) = ?")
                for p in bad { d.bind([p]).run() }
            }
        }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func upsert(_ tracks: [TrackMetadata]) {
        guard !tracks.isEmpty else { return }
        locked {
            try? db.transaction {
                let stmt = try db.prepare("INSERT OR REPLACE INTO tracks(\(Self.columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                for t in tracks {
                    let path = t.path.pathKey
                    stmt.bind([
                        path, (path as NSString).deletingLastPathComponent, t.mtime, t.size,
                        t.title, t.artist, t.album, t.albumArtist, t.genre, t.composer, t.year,
                        t.trackNumber, t.trackTotal, t.discNumber, t.discTotal, t.duration,
                        t.format?.codec, t.format?.sampleRate, t.format?.bitDepth, t.format?.channels,
                        t.format?.lossless, t.bitrate,
                    ]).run()
                }
            }
        }
    }

    private func row(_ s: Statement) -> TrackMetadata {
        var t = TrackMetadata(path: s.string(0) ?? "", mtime: s.double(2), size: Int64(s.int(3) ?? 0))
        t.title = s.string(4)
        t.artist = s.string(5)
        t.album = s.string(6)
        t.albumArtist = s.string(7)
        t.genre = s.string(8)
        t.composer = s.string(9)
        t.year = s.string(10)
        t.trackNumber = s.int(11)
        t.trackTotal = s.int(12)
        t.discNumber = s.int(13)
        t.discTotal = s.int(14)
        t.duration = s.double(15)
        if let codec = s.string(16) {
            t.format = SourceFormat(codec: codec, sampleRate: s.double(17), bitDepth: s.int(18) ?? 0,
                                    channels: s.int(19) ?? 0, lossless: (s.int(20) ?? 0) != 0)
        }
        t.bitrate = s.int(21) ?? 0
        return t
    }

    public func tracks(inFolder folder: String) -> [String: TrackMetadata] {
        locked {
            guard let s = try? db.prepare("SELECT \(Self.columns) FROM tracks WHERE folder = ?") else { return [:] }
            s.bind([folder.pathKey])
            var out: [String: TrackMetadata] = [:]
            while s.step() {
                let t = row(s)
                out[t.path] = t
            }
            return out
        }
    }

    public func track(path: String) -> TrackMetadata? {
        locked {
            guard let s = try? db.prepare("SELECT \(Self.columns) FROM tracks WHERE path = ?") else { return nil }
            s.bind([path.pathKey])
            return s.step() ? row(s) : nil
        }
    }

    /// Paths under `root` sort between "root/" and "root0" because '0' follows '/'.
    func stamps(underRoot root: String) -> [String: (Double, Int64)] {
        locked {
            guard let s = try? db.prepare("SELECT path, mtime, size FROM tracks WHERE path >= ? AND path < ?") else { return [:] }
            s.bind([root.pathKey + "/", root.pathKey + "0"])
            var out: [String: (Double, Int64)] = [:]
            while s.step() { out[s.string(0) ?? ""] = (s.double(1), Int64(s.int(2) ?? 0)) }
            return out
        }
    }

    func delete(paths: [String]) {
        guard !paths.isEmpty else { return }
        locked {
            try? db.transaction {
                let s = try db.prepare("DELETE FROM tracks WHERE path = ?")
                for p in paths { s.bind([p.pathKey]).run() }
            }
        }
    }

    func replaceFolders(root: String, folders: [String]) {
        locked {
            try? db.transaction {
                try db.prepare("DELETE FROM folders WHERE root = ?").bind([root.pathKey]).run()
                let s = try db.prepare("INSERT OR IGNORE INTO folders(path, root) VALUES(?, ?)")
                for f in folders { s.bind([f.pathKey, root.pathKey]).run() }
            }
        }
    }

    public func removeRoot(_ root: String) {
        locked {
            try? db.prepare("DELETE FROM tracks WHERE path >= ? AND path < ?").bind([root.pathKey + "/", root.pathKey + "0"]).run()
            try? db.prepare("DELETE FROM folders WHERE root = ?").bind([root.pathKey]).run()
        }
    }

    public func allFolders() -> [String] {
        locked {
            guard let s = try? db.prepare("SELECT path FROM folders ORDER BY path") else { return [] }
            var out: [String] = []
            while s.step() { if let p = s.string(0) { out.append(p) } }
            return out
        }
    }

    public func allTracks() -> [TrackMetadata] {
        locked {
            guard let s = try? db.prepare("SELECT \(Self.columns) FROM tracks") else { return [] }
            var out: [TrackMetadata] = []
            while s.step() { out.append(row(s)) }
            return out
        }
    }

    public func searchRows() -> [SearchRow] {
        locked {
            guard let s = try? db.prepare("SELECT path, title, artist, album FROM tracks") else { return [] }
            var out: [SearchRow] = []
            while s.step() {
                out.append(SearchRow(path: s.string(0) ?? "", title: s.string(1), artist: s.string(2), album: s.string(3)))
            }
            return out
        }
    }

    public func trackCount() -> Int {
        locked {
            guard let s = try? db.prepare("SELECT COUNT(*) FROM tracks"), s.step() else { return 0 }
            return s.int(0) ?? 0
        }
    }
}
